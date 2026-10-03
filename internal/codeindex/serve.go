package codeindex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"
)

// maxServeLine caps one --serve request line (a batch of paths).
const maxServeLine = 16 << 20

// doneLine ends a run's stream (spec §6.2).
type doneLine struct {
	Done    bool  `json:"done"`
	Files   int   `json:"files"`
	Symbols int   `json:"symbols"`
	MS      int64 `json:"ms"`
}

// Stream runs one pass (paths nil = every file) and writes it to w as JSON
// lines: one FileResult per file, then a done line. A cancelled run writes
// no done line and returns ctx's error.
func Stream(ctx context.Context, root string, paths []string, workers int, w io.Writer) error {
	start := time.Now()
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	sum, err := Run(ctx, root, paths, workers, func(r FileResult) error {
		if err := enc.Encode(r); err != nil {
			return fmt.Errorf("writing %s: %w", r.File, err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if err := enc.Encode(doneLine{Done: true, Files: sum.Files, Symbols: sum.Symbols, MS: time.Since(start).Milliseconds()}); err != nil {
		return fmt.Errorf("writing the done line: %w", err)
	}
	return nil
}

// Serve is `code index --serve`: each line read from r is one run over
// its tab-separated paths (relative to root), streamed to w and ended by
// a done line; an empty line is ignored. The process stays up between
// runs, so a language's query is compiled once, not once per save. It
// returns nil when r reaches EOF.
func Serve(ctx context.Context, root string, workers int, r io.Reader, w io.Writer) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64<<10), maxServeLine)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			continue
		}
		if err := Stream(ctx, root, strings.Split(line, "\t"), workers, w); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("reading requests: %w", err)
	}
	return nil
}
