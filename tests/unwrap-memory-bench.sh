#!/usr/bin/env bash
#
# unwrap-memory-bench.sh
#
# Benchmark peak memory of `thanos-kit unwrap` (Mimir -> Thanos block split):
# baseline (master, unbounded heads) vs the per-tenant --max-open-blocks change,
# on one real local TSDB block.
#
# What it does:
#   1. builds two binaries: BASELINE_REF (default: master) and the current
#      working tree (your changes);
#   2. detects which ext-labels to split on via `analyze` (override with SPLIT);
#   3. runs `unwrap --dry-run` for the baseline (unbounded) and for the new
#      binary across a sweep of --max-open-blocks, each under a cgroup memory
#      cap so an OOM kills only the test, not your shell session;
#   4. prints a table: status, peak RSS, peak cgroup memory, and peak ANON
#      memory, wall time, output blocks, head-open churn; plus per-tenant block
#      fragmentation for the new runs.
#
# peakAnon is the figure that actually drives OOM. peakRSS (/usr/bin/time) and
# cgPeak (cgroup memory.peak) both include reclaimable file cache - the source
# block mmap and the head's on-disk chunk files - so they are inflated and not
# reliably comparable between configs; rank by peakAnon (and by which configs
# survive a tight MEM cap).
#
# The block must already be on local disk. To fetch one you need read access to
# the object-store bucket, e.g.:
#   gcloud storage cp -r gs://<bucket>/<prefix>/<tenant>/<ULID> /tmp/tk-real/<ULID>
#
# Usage:
#   tests/unwrap-memory-bench.sh <fs-bucket-root>
# where <fs-bucket-root> is the directory that CONTAINS the <ULID>/ block dir
# (NOT the <ULID>/ dir itself). Defaults to /tmp/tk-real.
#
# Env overrides:
#   ULID=<id>            block id (auto-detected if the root has exactly one block)
#   SPLIT='a;b'          ext-label names for __meta_ext_labels (default: auto)
#   MEM=8G               MemoryMax per run
#   KS='1 4 0'           --max-open-blocks values to sweep for the new binary
#   STREAM=1             also run a --stream (no-Head) pass; ignores --max-open-blocks
#   TIMEOUT=900          per-run wall-clock safety limit (seconds)
#   BASELINE_REF=master  git ref to build the baseline binary from
#   WORK=/tmp/tk-bench   scratch dir for binaries, data-dirs, outputs
#   SKIP_RUNS=1          build + detect + print plan, but do not run the benches

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCK_DIR="${1:-/tmp/tk-real}"
MEM="${MEM:-8G}"
KS="${KS:-1 4 0}"
TIMEOUT="${TIMEOUT:-900}"
BASELINE_REF="${BASELINE_REF:-master}"
WORK="${WORK:-/tmp/tk-bench}"
SPLIT="${SPLIT:-auto}"

die() { echo "ERROR: $*" >&2; exit 1; }
# bytes -> GiB string (n/a for 0/empty)
b2g() { awk -v b="${1:-0}" 'BEGIN{ if (b+0>0) printf "%.2fGiB", b/1073741824; else printf "n/a" }'; }

command -v go >/dev/null            || die "go not found"
command -v /usr/bin/time >/dev/null || die "/usr/bin/time not found (install the 'time' package)"
command -v python3 >/dev/null       || die "python3 not found"

# --- resolve the block -------------------------------------------------------
[ -d "$BLOCK_DIR" ] || die "block dir not found: $BLOCK_DIR (download a block first, see header)"
ULID="${ULID:-}"
if [ -z "$ULID" ]; then
  mapfile -t found < <(find "$BLOCK_DIR" -maxdepth 1 -mindepth 1 -type d \
      -regextype posix-extended -regex '.*/[0-9A-HJKMNP-TV-Z]{26}$' -printf '%f\n')
  [ "${#found[@]}" -eq 1 ] || die "expected exactly one block dir in $BLOCK_DIR, found ${#found[@]}; set ULID=..."
  ULID="${found[0]}"
fi
[ -f "$BLOCK_DIR/$ULID/meta.json" ] || \
  die "no $BLOCK_DIR/$ULID/meta.json (is $BLOCK_DIR the bucket root that CONTAINS the ULID dir?)"
SRC="{type: FILESYSTEM, config: {directory: $BLOCK_DIR}}"
mkdir -p "$WORK"
echo ">> block:  $ULID"
echo ">> root:   $BLOCK_DIR"

# --- build binaries ----------------------------------------------------------
echo ">> build:  new (current working tree)"
( cd "$REPO" && go build -o "$WORK/tk-new" . ) || die "build new failed"
echo ">> build:  old ($BASELINE_REF)"
( cd "$REPO" && git worktree remove --force "$WORK/baseline-src" 2>/dev/null; git worktree prune )
rm -rf "$WORK/baseline-src"
( cd "$REPO" && git worktree add -q "$WORK/baseline-src" "$BASELINE_REF" ) || die "git worktree add $BASELINE_REF failed"
( cd "$WORK/baseline-src" && go build -o "$WORK/tk-old" . ) || die "build old failed"
( cd "$REPO" && git worktree remove --force "$WORK/baseline-src" 2>/dev/null; git worktree prune )

# --- cgroup memory cap -------------------------------------------------------
if systemd-run --user --scope -q true >/dev/null 2>&1; then
  HAVE_SYSTEMD=1
  cap() { systemd-run --user --scope -q -p MemoryMax="$MEM" -p MemorySwapMax=0 "$@"; }
  echo ">> cap:    systemd-run --user --scope MemoryMax=$MEM, swap off (+ cgroup anon/peak sampling)"
else
  HAVE_SYSTEMD=0
  cap() { "$@"; }
  echo ">> cap:    WARNING - 'systemd-run --user --scope' unavailable; running WITHOUT a memory cap (an OOM may hit your session); no cgroup memory stats"
fi

# sample_cgroup <unit> <outfile>: while the transient scope <unit>.scope lives,
# track its peak total memory (kernel-tracked memory.peak, or memory.current as
# fallback) and its peak anonymous memory (sampled from memory.stat). Anonymous
# memory is the non-reclaimable working set the OOM killer acts on. Writes
# "<anonBytes> <peakBytes>" to outfile.
sample_cgroup() {
  local unit="$1" outfile="$2" cg="" i
  echo "0 0" > "$outfile"
  for i in $(seq 1 200); do
    cg="$(systemctl --user show "${unit}.scope" -p ControlGroup --value 2>/dev/null)"
    [ -n "$cg" ] && [ -r "/sys/fs/cgroup${cg}/memory.current" ] && break
    cg=""; sleep 0.05
  done
  [ -n "$cg" ] || return 0
  local base="/sys/fs/cgroup${cg}" pa=0 pk=0 an mp
  local guard=$(( (TIMEOUT + 120) * 5 ))   # 0.2s steps, bounded so we never hang
  while [ -r "$base/memory.current" ] && [ "$guard" -gt 0 ]; do
    mp="$(cat "$base/memory.peak" 2>/dev/null || cat "$base/memory.current" 2>/dev/null)"
    an="$(awk '/^anon /{print $2; exit}' "$base/memory.stat" 2>/dev/null)"
    [ -n "$mp" ] && [ "$mp" -gt "$pk" ] 2>/dev/null && pk="$mp"
    [ -n "$an" ] && [ "$an" -gt "$pa" ] 2>/dev/null && pa="$an"
    guard=$((guard - 1))
    sleep 0.2
  done
  echo "$pa $pk" > "$outfile"
}

# --- split labels ------------------------------------------------------------
if [ "$SPLIT" = "auto" ]; then
  echo ">> split:  auto-detecting via analyze ..."
  SPLIT="$(cap timeout 180 "$WORK/tk-new" analyze --objstore.config="$SRC" "$ULID" 2>/dev/null \
            | sed -n 's/^Label names appearing in all Series: \[\(.*\)\]$/\1/p' \
            | tr -d ' ' | tr ',' ';')"
  [ -n "$SPLIT" ] || die "could not auto-detect split labels; set SPLIT='a;b'"
fi
echo ">> split:  __meta_ext_labels = $SPLIT"
REL="$WORK/relabel.yml"
printf -- '- target_label: __meta_ext_labels\n  replacement: %s\n' "$SPLIT" > "$REL"

# --- run plan ----------------------------------------------------------------
echo ">> plan:   (each: --dry-run, cap $MEM, timeout ${TIMEOUT}s)"
echo "             old-unbounded   tk-old unwrap (no --max-open-blocks)"
for k in $KS; do echo "             new-k$k          tk-new unwrap --max-open-blocks=$k"; done
[ -n "${STREAM:-}" ] && echo "             new-stream       tk-new unwrap --stream (no Head; ignores --max-open-blocks)"
if [ -n "${SKIP_RUNS:-}" ]; then echo ">> SKIP_RUNS set; not running benches"; exit 0; fi

# --- run one bench: run <tag> <old|new> [extra unwrap args...] ---------------
declare -A R_RSS R_WALL R_BLK R_HEAD R_STAT R_ANON R_CGPK
ORDER=()
run() {
  local tag="$1" bin="$2"; shift 2
  local proc="$WORK/proc-$tag" tf="$WORK/time-$tag.txt" log="$WORK/log-$tag.txt"
  local cgf="$WORK/cg-$tag" unit="tkbench-${tag}-$$"
  rm -rf "$proc" "$WORK/dst-$tag"; mkdir -p "$proc"; : > "$tf"; echo "0 0" > "$cgf"
  echo ">> run [$tag]: tk-$bin unwrap $*"
  local rc=0 spid=""
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    sample_cgroup "$unit" "$cgf" & spid=$!
    timeout "$TIMEOUT" systemd-run --user --scope -q --unit="$unit" \
      -p MemoryMax="$MEM" -p MemorySwapMax=0 \
      /usr/bin/time -v -o "$tf" \
      "$WORK/tk-$bin" unwrap \
        --objstore.config="$SRC" \
        --dst.config="{type: FILESYSTEM, config: {directory: $WORK/dst-$tag}}" \
        --relabel-config-file="$REL" --data-dir="$proc" \
        --wait-interval=0 --dry-run "$@" >"$log" 2>&1 || rc=$?
    wait "$spid" 2>/dev/null
  else
    timeout "$TIMEOUT" \
      /usr/bin/time -v -o "$tf" \
      "$WORK/tk-$bin" unwrap \
        --objstore.config="$SRC" \
        --dst.config="{type: FILESYSTEM, config: {directory: $WORK/dst-$tag}}" \
        --relabel-config-file="$REL" --data-dir="$proc" \
        --wait-interval=0 --dry-run "$@" >"$log" 2>&1 || rc=$?
  fi

  # dry-run writes produced blocks to data-dir/out (NOT to --dst.config)
  local rss wall done head blk stat anon cgpk
  rss="$(awk '/Maximum resident/{print $6}' "$tf")"
  wall="$(awk -F': ' '/Elapsed \(wall/{print $NF}' "$tf")"
  done="$(grep -c 'bucket iteration done' "$log" 2>/dev/null || true)"
  head="$(grep -c 'Replaying on-disk memory mappable' "$log" 2>/dev/null || true)"
  blk="$(find "$proc/out" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  read -r anon cgpk < "$cgf"; anon="${anon:-0}"; cgpk="${cgpk:-0}"
  if   [ "$rc" = "124" ];                              then stat="TIMEOUT"
  elif [ "${done:-0}" -ge 1 ] && [ -n "$rss" ];        then stat="OK"
  elif [ -z "$rss" ] || [ "$rc" = "137" ] || [ "$rc" = "143" ]; then stat="OOM/killed"
  else stat="rc=$rc"; fi
  R_RSS[$tag]="${rss:-}"; R_WALL[$tag]="${wall:-n/a}"; R_BLK[$tag]="$blk"
  R_HEAD[$tag]="${head:-0}"; R_STAT[$tag]="$stat"; R_ANON[$tag]="$anon"; R_CGPK[$tag]="$cgpk"
  ORDER+=("$tag:$bin")
  echo "   -> $stat | rss=${rss:-n/a}kB anon=$(b2g "$anon") cgpeak=$(b2g "$cgpk") wall=${R_WALL[$tag]} out_blocks=$blk head_opens=${head:-0}"
}

# per-tenant fragmentation for a finished run (single python pass over out/)
frag() {
  local tag="$1" out="$WORK/proc-$tag/out"
  [ -d "$out" ] || return 0
  python3 - "$out" "$SPLIT" "$tag" <<'PY'
import json, os, sys, collections
out, split, tag = sys.argv[1], sys.argv[2].split(';'), sys.argv[3]
c = collections.Counter()
for name in os.listdir(out):
    try:
        l = json.load(open(os.path.join(out, name, "meta.json")))["thanos"]["labels"]
    except Exception:
        continue
    c[";".join(l.get(k, "-") for k in split)] += 1
if not c:
    sys.exit(0)
print(f"-- [{tag}] blocks per split-key (top 8 of {len(c)} tenants, {sum(c.values())} blocks):")
for key, n in c.most_common(8):
    print(f"   {n:8d}  {key}")
PY
}

# --- drive -------------------------------------------------------------------
run "old-unbounded" old
for k in $KS; do run "new-k$k" new --max-open-blocks="$k"; done
[ -n "${STREAM:-}" ] && run "new-stream" new --stream

# --- summary -----------------------------------------------------------------
echo
echo "== summary (block $ULID, split '$SPLIT', cap $MEM) =="
printf '%-14s %-11s %9s %9s %9s %10s %8s %11s\n' tag status peakRSS cgPeak peakAnon wall blocks head_opens
for entry in "${ORDER[@]}"; do
  tag="${entry%%:*}"; rss="${R_RSS[$tag]}"; rg="n/a"
  [ -n "$rss" ] && rg="$(awk -v k="$rss" 'BEGIN{printf "%.2fGiB", k/1024/1024}')"
  printf '%-14s %-11s %9s %9s %9s %10s %8s %11s\n' \
    "$tag" "${R_STAT[$tag]}" "$rg" "$(b2g "${R_CGPK[$tag]}")" "$(b2g "${R_ANON[$tag]}")" \
    "${R_WALL[$tag]}" "${R_BLK[$tag]}" "${R_HEAD[$tag]}"
done
echo
for entry in "${ORDER[@]}"; do
  case "$entry" in new-*) frag "${entry%%:*}";; esac
done
echo
echo ">> pass: a good fix completes within the cap AND produces ~one block per"
echo "   tenant with no head-open churn. Many blocks + many head-opens = thrashing."
echo ">> rank configs by peakAnon (OOM-relevant); peakRSS/cgPeak include"
echo "   reclaimable file cache and are not reliable for ranking."
