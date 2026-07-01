// symdump inspects the on-disk symbol table of one or more TSDB block dirs and
// reports how many symbols are actually referenced by series labels vs. how many
// are dead weight ("bloat") - i.e. strings in the table no series points at.
// This is the only way to see the --stream symbol-table bloat: `dump`/`analyze`
// only ever show referenced labels, never the raw symbol table.
//
//	go run ./tools/symdump <blockdir> [<blockdir> ...]
//
// Throwaway dev tooling - do NOT commit to the PR branch (keep it on mem-profiling).
package main

import (
	"fmt"
	"os"
	"sort"

	"github.com/go-kit/log"
	"github.com/prometheus/prometheus/model/labels"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunks"
	"github.com/prometheus/prometheus/tsdb/index"
)

func main() {
	for _, dir := range os.Args[1:] {
		b, err := tsdb.OpenBlock(log.NewNopLogger(), dir, nil)
		must(err)
		ir, err := b.Index()
		must(err)

		// Every string in the block's symbol table (value = referenced?).
		seen := map[string]bool{}
		it := ir.Symbols()
		for it.Next() {
			seen[it.At()] = false
		}
		must(it.Err())

		// Mark the ones any series actually references.
		k, v := index.AllPostingsKey()
		p, err := ir.Postings(k, v)
		must(err)
		var builder labels.ScratchBuilder
		var chks []chunks.Meta
		nSeries := 0
		for p.Next() {
			must(ir.Series(p.At(), &builder, &chks))
			for _, l := range builder.Labels() {
				seen[l.Name] = true
				seen[l.Value] = true
			}
			nSeries++
		}
		must(p.Err())

		var bloat []string
		for s, ref := range seen {
			if !ref {
				bloat = append(bloat, s)
			}
		}
		sort.Strings(bloat)
		fmt.Printf("%s\n  series=%d symbols=%d referenced=%d unreferenced_bloat=%d\n",
			dir, nSeries, len(seen), len(seen)-len(bloat), len(bloat))
		if len(bloat) > 0 {
			fmt.Printf("  bloat: %v\n", bloat)
		}
		must(ir.Close())
		must(b.Close())
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
