package main

import (
	"context"
	"fmt"
	"math"
	"os"

	"github.com/go-kit/log"
	"github.com/go-kit/log/level"
	"github.com/oklog/ulid"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

// noIsoWriter is a drop-in replacement for tsdb.BlockWriter that builds the Head
// with isolation DISABLED. tsdb.NewBlockWriter hardcodes DefaultHeadOptions (with
// isolation on) and does not expose HeadOptions, so we replicate its tiny
// initHead/Flush/Close here, changing only opts.IsolationDisabled = true.
//
// The Head's isolation is a per-series txRing for MVCC read isolation - pure
// overhead for our write-then-flush use, since splitBlock never queries the Head
// before Flush. On a real 1.18M-series block it accounts for ~60% of the retained
// heap (~1.3 GiB) and ~2.5 GiB of allocation churn. Disabling it is safe and does
// not change block contents: every memSeries.txs access is guarded for the
// isolation-disabled case, so a nil txRing is never dereferenced.
type noIsoWriter struct {
	logger    log.Logger
	dstDir    string
	chunkDir  string
	blockSize int64
	head      *tsdb.Head
}

func newNoIsoWriter(logger log.Logger, dstDir string, blockSize int64) (*noIsoWriter, error) {
	chunkDir, err := os.MkdirTemp(os.TempDir(), "head") // honors the TMPDIR pinned in unwrapBlock
	if err != nil {
		return nil, fmt.Errorf("create temp dir: %w", err)
	}
	opts := tsdb.DefaultHeadOptions()
	opts.ChunkRange = blockSize
	opts.ChunkDirRoot = chunkDir
	opts.EnableNativeHistograms.Store(true)
	opts.IsolationDisabled = true // the whole point: no per-series txRing
	h, err := tsdb.NewHead(nil, logger, nil, nil, opts, tsdb.NewHeadStats())
	if err != nil {
		_ = os.RemoveAll(chunkDir)
		return nil, fmt.Errorf("tsdb.NewHead: %w", err)
	}
	if err := h.Init(math.MinInt64); err != nil {
		_ = h.Close()
		_ = os.RemoveAll(chunkDir)
		return nil, fmt.Errorf("head init: %w", err)
	}
	return &noIsoWriter{logger: logger, dstDir: dstDir, chunkDir: chunkDir, blockSize: blockSize, head: h}, nil
}

func (w *noIsoWriter) Appender(ctx context.Context) storage.Appender {
	return w.head.Appender(ctx)
}

// Flush compacts the Head into a block in dstDir and returns its ULID. An empty
// Head yields a zero ULID (matching tsdb.BlockWriter -> LeveledCompactor.Write,
// which writes no block when NumSamples == 0).
func (w *noIsoWriter) Flush(ctx context.Context) (ulid.ULID, error) {
	mint := w.head.MinTime()
	maxt := w.head.MaxTime() + 1 // block intervals are half-open [mint, maxt)
	level.Info(w.logger).Log("msg", "flushing", "series_count", w.head.NumSeries())
	compactor, err := tsdb.NewLeveledCompactor(ctx, nil, w.logger, []int64{w.blockSize}, chunkenc.NewPool(), nil)
	if err != nil {
		return ulid.ULID{}, fmt.Errorf("create leveled compactor: %w", err)
	}
	id, err := compactor.Write(w.dstDir, w.head, mint, maxt, nil)
	if err != nil {
		return ulid.ULID{}, fmt.Errorf("compactor write: %w", err)
	}
	return id, nil
}

func (w *noIsoWriter) Close() error {
	defer func() {
		if err := os.RemoveAll(w.chunkDir); err != nil {
			level.Error(w.logger).Log("msg", "error deleting head temp dir", "err", err)
		}
	}()
	return w.head.Close()
}
