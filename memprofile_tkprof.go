//go:build tkprof

// Opt-in heap-memory profiling hook for thanos-kit, compiled only with
//
//	go build -tags tkprof
//
// and activated at runtime with TKPROF=<dir>. It samples HeapInuse and, on each
// new peak, writes an inuse_space heap profile (heap-peak.pprof) plus a
// runtime.MemStats snapshot (memstats-peak.txt) into <dir>, so you can see what
// a command's peak memory is actually made of. See PROFILING.md.
//
// It is a no-op in normal builds (the tag excludes this file) and when TKPROF is
// unset, so it never affects production binaries.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"time"
)

func init() {
	dir := os.Getenv("TKPROF")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0777); err != nil {
		fmt.Fprintf(os.Stderr, "TKPROF: cannot create %s: %v\n", dir, err)
		return
	}
	go func() {
		var profiled uint64
		var ms runtime.MemStats
		for {
			runtime.ReadMemStats(&ms) // cheap, does not trigger a GC
			// Re-profile only on a meaningfully higher peak (>~14% or +64 MiB) to
			// bound the number of forced GCs from WriteHeapProfile.
			if ms.HeapInuse > profiled+profiled/7+64<<20 {
				profiled = ms.HeapInuse
				if f, err := os.Create(filepath.Join(dir, "heap-peak.pprof")); err == nil {
					_ = pprof.WriteHeapProfile(f) // forces a GC; writes inuse + alloc samples
					_ = f.Close()
				}
				writeMemstats(filepath.Join(dir, "memstats-peak.txt"), &ms)
				fmt.Fprintf(os.Stderr, "TKPROF: peak HeapInuse=%.2fGiB HeapSys=%.2fGiB\n",
					float64(ms.HeapInuse)/(1<<30), float64(ms.HeapSys)/(1<<30))
			}
			time.Sleep(150 * time.Millisecond)
		}
	}()
}

func writeMemstats(path string, ms *runtime.MemStats) {
	f, err := os.Create(path)
	if err != nil {
		return
	}
	defer f.Close()
	g := func(b uint64) string { return fmt.Sprintf("%7.2f GiB", float64(b)/(1<<30)) }
	fmt.Fprintf(f, "HeapAlloc    %s  live heap objects (== inuse_space after GC)\n", g(ms.HeapAlloc))
	fmt.Fprintf(f, "HeapInuse    %s  in-use heap spans\n", g(ms.HeapInuse))
	fmt.Fprintf(f, "HeapSys      %s  heap mapped from OS (anonymous)\n", g(ms.HeapSys))
	fmt.Fprintf(f, "HeapIdle     %s  idle spans\n", g(ms.HeapIdle))
	fmt.Fprintf(f, "HeapReleased %s  returned to OS\n", g(ms.HeapReleased))
	fmt.Fprintf(f, "StackInuse   %s\n", g(ms.StackInuse))
	fmt.Fprintf(f, "NextGC       %s  heap target for the next GC\n", g(ms.NextGC))
	fmt.Fprintf(f, "Sys          %s  total mapped from OS\n", g(ms.Sys))
	fmt.Fprintf(f, "NumGC        %d\n", ms.NumGC)
}
