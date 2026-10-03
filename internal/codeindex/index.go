// Package codeindex builds a workbench folder's symbol index for
// `watchtower code index` (spec 2026-10-02-code-navigation-design §6):
// tree-sitter grammars with our own tags queries, signatures and doc
// comments cut out of the tree in Go, Markdown headings and config files'
// top-level keys from a scan, Vue and Svelte by their <script> blocks.
//
// Grammars are cgo. Untagged cgo builds carry Go, Swift and Python
// (grammars_min.go); `-tags codegrammars` the full set (grammar_<id>.go, one per language);
// a CGO_ENABLED=0 build none (grammars_nocgo.go), so every file except a
// scanned one (Markdown, YAML, TOML, JSON, HTML…) then reports lang "".
package codeindex

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	"watchtower/internal/codewalk"
)

// parser turns one file's source into symbols. Each worker owns one; it is
// not safe for concurrent use.
type parser interface {
	// parse returns the symbols of src (Path and Lang still unset), or
	// ok=false when this build has no grammar for l.
	parse(l *langSpec, src []byte) (syms []Symbol, ok bool, err error)
	close()
}

// DefaultWorkers is the worker count for a full run: half the cores, at
// least two, leaving the rest to the editor and the app.
func DefaultWorkers() int {
	return max(2, runtime.GOMAXPROCS(0)/2)
}

// Run indexes the folder at root and calls emit once per file, from one
// goroutine, in completion order. paths nil indexes every file the walk
// lists (skipping those over codewalk.MaxIndexBytes); otherwise exactly
// those paths (relative to root): a path that is gone yields a Deleted
// result, one the walk would skip (.gitignore'd included) or this build
// cannot parse an empty result with lang "". A file whose parse fails or
// panics, or whose language's query does not compile, yields lang "" too,
// with a note on stderr; the run goes on. An emit error stops the run
// and is returned. A
// cancelled ctx stops it between files with ctx's error.
func Run(ctx context.Context, root string, paths []string, workers int, emit func(FileResult) error) (Summary, error) {
	return run(ctx, root, paths, workers, newParser, emit)
}

type job struct {
	rel      string
	size     int64
	explicit bool
	// ignored: a path asked for by name that the repository ignores.
	ignored bool
}

type outcome struct {
	res FileResult
	// warn is a one-line note for stderr: a file indexed without symbols
	// because its parse failed.
	warn string
}

// warnings receives the run's notes; the command's stderr.
var warnings io.Writer = os.Stderr

func run(ctx context.Context, root string, paths []string, workers int, mkParser func() parser, emit func(FileResult) error) (Summary, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	workers = max(1, workers)

	jobs := make(chan job)
	results := make(chan outcome)
	walkErr := make(chan error, 1)
	go func() {
		defer close(jobs)
		walkErr <- feed(ctx, root, paths, jobs)
	}()

	var wg sync.WaitGroup
	for range workers {
		wg.Go(func() { work(ctx, root, mkParser, jobs, results) })
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	var sum Summary
	var firstErr error
	warned := map[string]bool{}
	for o := range results {
		if firstErr != nil {
			continue // drain until the workers stop
		}
		if o.warn != "" && !warned[o.warn] {
			warned[o.warn] = true // a language's query error once per run
			fmt.Fprintln(warnings, o.warn)
		}
		if o.res.File == "" {
			continue // a walked file that vanished or is skipped
		}
		if err := emit(o.res); err != nil {
			firstErr = err
			cancel()
			continue
		}
		sum.Files++
		sum.Symbols += len(o.res.Symbols)
	}
	if firstErr != nil {
		return sum, firstErr
	}
	if err := <-walkErr; err != nil {
		return sum, err
	}
	return sum, ctx.Err()
}

// work is one worker: it indexes jobs with a parser of its own until jobs
// closes or ctx is cancelled.
func work(ctx context.Context, root string, mkParser func() parser, jobs <-chan job, results chan<- outcome) {
	p := mkParser()
	defer func() { p.close() }()
	for j := range jobs {
		o, panicked := indexFile(p, root, j)
		if panicked { // its state is unknown: start afresh
			p.close()
			p = mkParser()
		}
		select {
		case results <- o:
		case <-ctx.Done():
			return
		}
	}
}

// feed sends the run's files to the workers.
func feed(ctx context.Context, root string, paths []string, jobs chan<- job) error {
	send := func(j job) bool {
		select {
		case jobs <- j:
			return true
		case <-ctx.Done():
			return false
		}
	}
	if paths != nil {
		ignored := codewalk.Ignored(ctx, root, paths)
		for _, p := range paths {
			if !send(job{rel: p, explicit: true, ignored: ignored[p]}) {
				return nil
			}
		}
		return nil
	}
	for f, err := range codewalk.Files(ctx, root) {
		if err != nil {
			if ctx.Err() != nil {
				return nil // reported as the run's ctx error
			}
			return fmt.Errorf("listing files: %w", err)
		}
		if f.Size > codewalk.MaxIndexBytes {
			continue
		}
		if !send(job{rel: f.Rel, size: f.Size}) {
			return nil
		}
	}
	return nil
}

// indexFile indexes one file. A walked file that cannot be read any more
// (gone or changed into something the walk skips) yields a zero result,
// which the run drops; a path asked for by name always yields a result.
// A parse that fails or panics stays local (spec §6.3): the file yields
// lang "" and a note, and panicked tells the worker to replace p.
func indexFile(p parser, root string, j job) (o outcome, panicked bool) {
	res, err := indexSource(p, root, j)
	var qe *queryError
	var pe *parsePanic
	switch {
	case errors.As(err, &qe):
		return outcome{res: res, warn: fmt.Sprintf("code index: %s files are indexed without symbols: %v", qe.lang, qe.err)}, false
	case err != nil:
		return outcome{res: res, warn: fmt.Sprintf("code index: %s: %v; indexed without symbols", res.File, err)}, errors.As(err, &pe)
	}
	return outcome{res: res}, false
}

// queryError is a language's query that does not compile against its
// grammar: every file of the language fails alike.
type queryError struct {
	lang string
	err  error
}

func (e *queryError) Error() string { return e.err.Error() }
func (e *queryError) Unwrap() error { return e.err }

// parsePanic is a panic recovered from one file's parse.
type parsePanic struct{ v any }

func (e *parsePanic) Error() string { return fmt.Sprintf("panic: %v", e.v) }

// indexSource reads and parses one file; on a parse error the result is
// the file with lang "" and no symbols.
//
// A path asked for by name is echoed as asked (`./a.go` stays `./a.go`),
// in the result and its symbols, deleted or not: the caller keys by what
// it sent (ruling R16).
func indexSource(p parser, root string, j job) (FileResult, error) {
	res := FileResult{File: j.rel}
	rel := j.rel
	if j.explicit {
		f, deleted, ok := lookupNamed(root, j.rel)
		if !ok || j.ignored {
			res.Deleted = deleted
			return res, nil
		}
		rel = f.Rel
	}
	src, deleted, ok := readSource(filepath.Join(root, filepath.FromSlash(rel)))
	switch {
	case !ok && !j.explicit:
		return FileResult{}, nil
	case !ok:
		res.Deleted = deleted
		return res, nil
	}
	l := langFor(rel, src[:min(len(src), 256)])
	if l == nil {
		return res, nil
	}
	syms, supported, err := symbolsOf(p, l, src)
	if err != nil {
		return res, err
	}
	if !supported {
		return res, nil
	}
	res.Lang = l.id
	for i := range syms {
		syms[i].Path, syms[i].Lang = res.File, l.id
	}
	res.Symbols = syms
	return res, nil
}

// utf8BOM is the byte order mark some editors write at a file's start.
var utf8BOM = []byte("\xef\xbb\xbf")

// symbolsOf indexes src as l: by its scan, or by its grammar (a Vue or
// Svelte file's `<script>` blocks by the JavaScript or TypeScript one);
// supported=false when this build has no grammar for it. A scan reads src
// past a leading BOM, as the editor shows it: names stay clean and line-1
// columns match.
func symbolsOf(p parser, l *langSpec, src []byte) (syms []Symbol, supported bool, err error) {
	defer func() {
		if v := recover(); v != nil {
			syms, supported, err = nil, false, &parsePanic{v}
		}
	}()
	switch {
	case l.scan != nil:
		return l.scan(bytes.TrimPrefix(src, utf8BOM)), true, nil
	case l.scripts:
		return p.parse(scriptHost(src), src)
	}
	return p.parse(l, src)
}

// lookupNamed checks a path asked for by name: deleted when nothing is
// there; ok=false also for one the walk would skip or the index would not
// parse (an empty result).
func lookupNamed(root, rel string) (f codewalk.File, deleted, ok bool) {
	f, err := codewalk.Lookup(root, rel)
	if errors.Is(err, fs.ErrNotExist) {
		return f, true, false
	}
	return f, false, err == nil && f.Size <= codewalk.MaxIndexBytes
}

// readSource reads a file the walk listed; ok=false when it is gone
// (deleted), unreadable, or has grown past codewalk.MaxIndexBytes since.
func readSource(path string) (src []byte, deleted, ok bool) {
	src, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, true, false
	}
	return src, false, err == nil && len(src) <= codewalk.MaxIndexBytes
}
