// Package streamline reads the JSONL output of an LLM CLI child (claude,
// codex) one line at a time, the same way on every transport: a line up to
// MaxLine bytes is returned, a longer one (a tool result carrying a huge
// output) is read to its end, skipped and counted, so the stream goes on and
// the child never blocks on a full pipe.
package streamline

import (
	"bufio"
	"bytes"
	"errors"
	"io"
)

// MaxLine is the longest line Next returns, its newline included (the
// claude warm reader's limit).
const MaxLine = 64 << 20

// Reader reads lines from a child's stdout. It is not safe for concurrent
// use.
type Reader struct {
	r     *bufio.Reader
	limit int
	// err is a read error held back while the text read before it is
	// returned; Next returns it from then on.
	err                  error
	skipped, undecodable int
}

// New reads r with the MaxLine limit.
func New(r io.Reader) *Reader { return NewWithLimit(r, MaxLine) }

// NewWithLimit reads r with a limit of its own (tests lower it).
func NewWithLimit(r io.Reader, limit int) *Reader {
	return &Reader{r: bufio.NewReaderSize(r, 64*1024), limit: limit}
}

// Next returns the next line without its newline, skipping (and counting)
// every line over the limit. A last line without a newline is returned, not
// left unread: the child has exited by then and nothing will complete it.
// err is io.EOF after the last line, or the read error that ended the
// stream; the text read before an error is returned first.
func (r *Reader) Next() ([]byte, error) {
	for r.err == nil {
		line, oversized, err := r.readLine()
		r.err = err
		if oversized {
			r.skipped++
			continue
		}
		if len(line) == 0 {
			continue
		}
		return bytes.TrimSuffix(line, []byte{'\n'}), nil
	}
	return nil, r.err
}

// readLine reads one line, its newline included if any. A line longer than
// the limit is consumed and reported as oversized with no content.
func (r *Reader) readLine() (line []byte, oversized bool, err error) {
	for {
		frag, err := r.r.ReadSlice('\n')
		if !oversized {
			if len(line)+len(frag) > r.limit {
				oversized, line = true, nil
			} else {
				line = append(line, frag...)
			}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return line, oversized, err
	}
}

// Skipped is the number of lines skipped as over the limit.
func (r *Reader) Skipped() int { return r.skipped }

// MarkUndecodable counts a line the caller could not decode.
func (r *Reader) MarkUndecodable() { r.undecodable++ }

// Undecodable is the number of lines the caller marked undecodable.
func (r *Reader) Undecodable() int { return r.undecodable }

// Drain reads the rest of the stream to its end and discards it, so a child
// still writing exits instead of blocking on a full pipe; call it before
// the caller's Wait whenever reading stopped early.
func (r *Reader) Drain() {
	if r.err != nil && !errors.Is(r.err, io.EOF) {
		// The pipe already failed; the caller ends the child instead.
		return
	}
	_, _ = io.Copy(io.Discard, r.r)
}
