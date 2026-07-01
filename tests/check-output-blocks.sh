#!/usr/bin/env bash
# check-output-blocks.sh - one-shot inspection of `unwrap` output blocks.
#
# Usage:
#   tests/check-output-blocks.sh <blocks-dir> [--dump 'MATCHER']
#
# <blocks-dir> holds the per-tenant <ULID>/ block dirs, e.g. `<data-dir>/out`
# left behind by `unwrap --dry-run` (upload/delete skipped). Prints in one go:
#   1. inspect - per-block ULID, time range, #samples/#chunks, ext-labels, source
#   2. symbols - symdump per block: referenced vs unreferenced (bloat)
#   3. totals  - block count and summed #series / #samples (compare to the source)
# With `--dump 'MATCHER'` it also dumps matching series from the first block.
#
# Reuses a prebuilt binary if TK is set (e.g. TK=/tmp/tk-prof); otherwise builds
# thanos-kit once into a temp dir. Throwaway dev tooling - do NOT ship in the PR.
set -euo pipefail

DIR=${1:?usage: $0 <blocks-dir> [--dump MATCHER]}; shift || true
DUMP=""
if [ "${1:-}" = "--dump" ]; then DUMP=${2:?--dump needs a matcher}; fi

REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(cd "$DIR" && pwd)
shopt -s nullglob
blocks=("$DIR"/*/)
[ ${#blocks[@]} -gt 0 ] || { echo "no <ULID>/ block dirs under $DIR" >&2; exit 1; }

# a thanos-kit binary for inspect/dump (symdump runs via `go run`)
TK=${TK:-}
if [ -z "$TK" ]; then
  TK=$(mktemp -d)/thanos-kit
  (cd "$REPO" && go build -o "$TK" .)
fi

CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
printf 'type: FILESYSTEM\nconfig:\n  directory: %s\n' "$DIR" > "$CFG"

echo "== blocks in $DIR (inspect) =="
"$TK" inspect -r --objstore.config-file="$CFG"

echo
echo "== symbols (referenced vs unreferenced bloat) =="
(cd "$REPO" && go run ./tools/symdump "${blocks[@]}")

echo
echo "== totals =="
sum_field() { grep -rhoE "\"$1\": *[0-9]+" "$DIR"/*/meta.json | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}'; }
printf 'blocks=%d  series=%d  samples=%d\n' "${#blocks[@]}" "$(sum_field numSeries)" "$(sum_field numSamples)"

if [ -n "$DUMP" ]; then
  u=$(basename "${blocks[0]}")
  echo
  echo "== dump '$DUMP' from $u (first lines) =="
  "$TK" dump "$u" --objstore.config-file="$CFG" --data-dir="$(mktemp -d)" --match="$DUMP" | head
fi
