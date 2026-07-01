# Memory profiling for thanos-kit

Tooling to analyse where `thanos-kit` (in particular `unwrap`) spends peak
memory. `unwrap` is a CLI with no pprof endpoint and its peak is transient (the
TSDB Heads are freed at Flush), so a built-in sampler captures a heap profile at
the moment of peak `HeapInuse`. Sections 1-2 profile the default Head path;
section 3 covers the much-lower-memory `--stream` path.

The hook lives in `memprofile_tkprof.go`, behind the `tkprof` build tag, so it is
absent from normal builds and only runs when `TKPROF` is set.

## 1. Quick peak number (no profiler)

Just the GC heap sizes over time:

```sh
GODEBUG=gctrace=1 ./thanos-kit unwrap ... --max-open-blocks=1
# stderr: per-GC heap before/after and the next-GC target
```

Or the peak anonymous memory (the figure that drives OOM) via the bench script,
which runs the baseline and a sweep under a cgroup cap and prints
`peakRSS / cgPeak / peakAnon`:

```sh
KS=1 MEM=16G tests/unwrap-memory-bench.sh /path/to/fs-bucket-root
```

## 2. Heap breakdown (what the memory is made of)

### Build with the profiler

```sh
go build -tags tkprof -o /tmp/tk-prof .
```

### Run with TKPROF

`TKPROF=<dir>` enables the sampler; it writes `heap-peak.pprof` and
`memstats-peak.txt` into `<dir>`. Run under a cgroup memory cap so a heavy run
cannot take down your session (an OOM then kills only the test). With
`systemd-run --scope`, pass the env via `--setenv` (a scope does not inherit it):

```sh
mkdir -p /tmp/tkprof
printf -- '- target_label: __meta_ext_labels\n  replacement: prometheus;location\n' > /tmp/relabel.yml

systemd-run --user --scope -q --setenv=TKPROF=/tmp/tkprof \
  -p MemoryMax=16G -p MemorySwapMax=0 \
  /tmp/tk-prof unwrap \
    --objstore.config='{type: FILESYSTEM, config: {directory: /path/to/fs-bucket-root}}' \
    --dst.config='{type: FILESYSTEM, config: {directory: /tmp/tkprof-dst}}' \
    --relabel-config-file=/tmp/relabel.yml \
    --data-dir=/tmp/tkproc --wait-interval=0 --dry-run --max-open-blocks=1
```

Without `systemd-run` you can run uncapped (riskier on large `--max-open-blocks`):

```sh
TKPROF=/tmp/tkprof /tmp/tk-prof unwrap ... --dry-run --max-open-blocks=1
```

`--dry-run` runs the full memory path (Heads built, samples appended, blocks
compacted) but skips upload/delete, so it is safe against the source bucket.

### Analyse

```sh
cat /tmp/tkprof/memstats-peak.txt                                       # heap vs anon, NextGC

go tool pprof -inuse_space -top  /tmp/tk-prof /tmp/tkprof/heap-peak.pprof   # live heap by function
go tool pprof -inuse_space -cum  /tmp/tk-prof /tmp/tkprof/heap-peak.pprof   # by call tree
go tool pprof -alloc_space -top  /tmp/tk-prof /tmp/tkprof/heap-peak.pprof   # total allocation churn
go tool pprof -list 'unwrap.go'  /tmp/tk-prof /tmp/tkprof/heap-peak.pprof   # line-level for a file/func
go tool pprof -http=:8080        /tmp/tk-prof /tmp/tkprof/heap-peak.pprof   # web UI (graph / flame)
```

## 3. The `--stream` path (no Head)

Sections 1-2 profile the **default Head path**, which buffers each tenant's
series and chunks in an in-memory `tsdb.Head`, so peak is O(largest tenant)
(GiB-scale on large blocks). The experimental `--stream` flag bypasses the Head:
it copies the source block's chunks by reference straight into each tenant's
output block, holding at most one series' chunks at a time, so peak is O(largest
single series) - typically tens of MiB - and it is faster (no decode/re-append).

The heap profile then looks completely different: no `memSeries` / head chunks /
isolation, just the compactor's symbol table and per-tenant postings refs.
Profile it the same way, adding `--stream`:

```sh
systemd-run --user --scope -q --setenv=TKPROF=/tmp/tkprof \
  -p MemoryMax=16G -p MemorySwapMax=0 \
  /tmp/tk-prof unwrap --stream \
    --objstore.config='{type: FILESYSTEM, config: {directory: /path/to/fs-bucket-root}}' \
    --dst.config='{type: FILESYSTEM, config: {directory: /tmp/tkprof-dst}}' \
    --relabel-config-file=/tmp/relabel.yml \
    --data-dir=/tmp/tkproc --wait-interval=0 --dry-run
```

`--max-open-blocks` is a no-op with `--stream` (tenants are written one at a
time). Most of the `--stream` cgroup/RSS peak is the **reclaimable** mmap of the
source block, not heap - check `HeapSys` in `memstats-peak.txt` (or the bench
`peakAnon`) for the real anonymous figure.

## Reading the numbers

- `inuse_space` (in the pprof profile) is the **live** heap after a GC -- the
  retained working set. `HeapInuse` / `HeapSys` in `memstats-peak.txt` are
  measured before that GC and include collectable garbage; the difference is GC
  headroom, which `GOMEMLIMIT` reduces.
- `WriteHeapProfile` forces a GC, so the profile reflects retained objects. The
  sampler re-profiles on each new `HeapInuse` peak to land near the true peak.
- m-mapped Head chunk files are file-backed (not in the heap profile and not in
  anonymous memory) as long as `os.TempDir()` (`$TMPDIR`, where the Head writes
  them) is real disk, not tmpfs. The tool no longer pins `TMPDIR`; export it
  yourself if `/tmp` is tmpfs.

## Clean up

The profiler is opt-in via the build tag and env, so nothing needs reverting in
the source. Remove the scratch outputs when done:

```sh
rm -rf /tmp/tkprof /tmp/tkproc /tmp/tkprof-dst /tmp/relabel.yml /tmp/tk-prof
```
