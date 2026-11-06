package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"watchtower/internal/providers"
)

// The turn cap (AUTO-08, decisions A and N4/N5 of the transport design):
// codex exec has no --max-turns, so Watchtower counts the run's model turns
// (model responses, the unit of claude's --max-turns and runtime B's
// MaxIterations) and kills the process group when turn N+1 starts. A run
// in a private CODEX_HOME (SetRunHome) counts the responses its rollout
// records, one token_count event each; any other run, or one whose rollout
// cannot be read, counts by the stream rule (turnCounter).

// SetMaxTurns caps the run at n model turns; 0 = no cap. The run that
// starts turn n+1 is stopped (its process group killed) and fails with a
// providers.Budget failure, as claude's error_max_turns does.
func (c *Client) SetMaxTurns(n int) { c.maxTurns = n }

// SetRunHome runs codex in dir, a private CODEX_HOME the caller created and
// removes after the run: the child's CODEX_HOME is dir, the run is not
// --ephemeral, so codex writes its rollout under dir/sessions, and the turn
// cap counts that rollout. Nothing of the run outlives dir.
func (c *Client) SetRunHome(dir string) { c.runHome = dir }

// rolloutPollInterval is how often a capped run re-reads its rollout between
// stream lines (a long tool call prints none).
const rolloutPollInterval = 250 * time.Millisecond

// errTurnCap is the budget failure of a run stopped at its cap.
func errTurnCap(n int) error {
	return providers.WithFailure("codex", providers.Budget, fmt.Errorf("stopped after %d model turns", n))
}

// turnCounter is the stream rule of the spec's §3.4 over codex exec's JSONL
// events: a model response's tool calls must all return before the next
// response starts, so a model-produced item after the previous response's
// tool results came back opens a new turn. Two tools started before either
// returned are one response; a text-only answer is one turn. codex 0.159
// runs one response's MCP calls one after another, which this rule counts
// as separate turns (it can only over-count): a run with a readable rollout
// counts that instead.
type turnCounter struct {
	turns, open int
	returned    bool
	// seen marks the item ids whose first event was counted.
	seen map[string]bool
}

// event updates the count with one stream event and returns it.
func (t *turnCounter) event(ev *CodexEvent) int {
	if ev.Type == "turn.started" {
		*t = turnCounter{turns: 1}
		return t.turns
	}
	item := ev.Item
	if item == nil || !strings.HasPrefix(ev.Type, "item.") {
		return t.turns
	}
	first := item.ID == "" || !t.seen[item.ID]
	if item.ID != "" {
		if t.seen == nil {
			t.seen = map[string]bool{}
		}
		t.seen[item.ID] = true
	}
	switch {
	case isToolItem(item.Type):
		if first {
			t.boundary()
			t.open++
		}
		if ev.Type == "item.completed" {
			t.open = max(t.open-1, 0)
			t.returned = true
		}
	case item.Type == "reasoning" || item.Type == "agent_message":
		if first {
			t.boundary()
		}
	}
	return t.turns
}

// boundary opens a new turn when the previous response's tools all came back.
func (t *turnCounter) boundary() {
	if t.turns == 0 {
		t.turns = 1
	}
	if t.returned && t.open == 0 {
		t.turns++
		t.returned = false
	}
}

// isToolItem: the item types that are a model's tool call.
func isToolItem(typ string) bool {
	switch typ {
	case "mcp_tool_call", "command_execution", "web_search", "file_change":
		return true
	}
	return false
}

// rolloutTurns reads the model responses a private CODEX_HOME's rollout has
// recorded so far, incrementally (each read continues where the last
// stopped). codex writes one event_msg token_count with usage info per
// response — after the response's tool results — and, on newer versions,
// one token_usage_record right after the response, before its tools run;
// the count is the larger of the two, so the earlier marker stops a run as
// soon as it is there.
type rolloutTurns struct {
	home string
	path string
	off  int64
	// partial is the unfinished last line of the previous read.
	partial            []byte
	tokenCount, record int
	// err makes the rollout unreadable for the rest of the run.
	err error
}

// read returns the responses counted so far; ok is false while there is no
// rollout to count (none yet, or unreadable: err set).
func (r *rolloutTurns) read() (n int, ok bool) {
	if r.err != nil {
		return 0, false
	}
	if r.path == "" {
		path, err := findRollout(r.home)
		if err != nil {
			r.err = err
			return 0, false
		}
		if path == "" {
			return 0, false
		}
		r.path = path
	}
	f, err := os.Open(r.path)
	if err != nil {
		r.err = err
		return 0, false
	}
	defer f.Close()
	if _, err := f.Seek(r.off, io.SeekStart); err != nil {
		r.err = err
		return 0, false
	}
	data, err := io.ReadAll(f)
	if err != nil {
		r.err = err
		return 0, false
	}
	r.off += int64(len(data))
	data = append(r.partial, data...)
	end := bytes.LastIndexByte(data, '\n')
	r.partial = append([]byte(nil), data[end+1:]...)
	for line := range bytes.SplitSeq(data[:end+1], []byte{'\n'}) {
		r.count(line)
	}
	return max(r.tokenCount, r.record), true
}

func (r *rolloutTurns) count(line []byte) {
	if !bytes.Contains(line, []byte("token_count")) && !bytes.Contains(line, []byte("token_usage_record")) {
		return
	}
	var ev struct {
		Type    string `json:"type"`
		Payload struct {
			Type string          `json:"type"`
			Info json.RawMessage `json:"info"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &ev) != nil {
		return
	}
	switch {
	case ev.Type == "token_usage_record":
		r.record++
	case ev.Type == "event_msg" && ev.Payload.Type == "token_count":
		// A token_count without usage info only carries rate limits.
		if info := bytes.TrimSpace(ev.Payload.Info); len(info) > 0 && !bytes.Equal(info, []byte("null")) {
			r.tokenCount++
		}
	}
}

// findRollout is the rollout file under home/sessions, "" while there is
// none. The home is the run's own, so it holds this run's rollout only; the
// newest name wins should there be more. Symlinks are never followed.
func findRollout(home string) (string, error) {
	var found []string
	err := filepath.WalkDir(filepath.Join(home, "sessions"), func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() && strings.HasPrefix(d.Name(), "rollout-") && strings.HasSuffix(d.Name(), ".jsonl") {
			found = append(found, path)
		}
		return nil
	})
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if len(found) == 0 {
		return "", nil
	}
	sort.Strings(found)
	return found[len(found)-1], nil
}

// turnCap enforces SetMaxTurns on one run. Its methods are safe on a nil
// receiver (no cap) and from the read loop and the poller at once.
type turnCap struct {
	max  int
	stop context.CancelFunc

	mu      sync.Mutex
	stream  turnCounter
	rollout *rolloutTurns // nil: no run home, the stream rule counts
	stopped bool
	logged  bool
}

// newTurnCap is the cap of a run that stop ends; nil for no cap.
func newTurnCap(n int, runHome string, stop context.CancelFunc) *turnCap {
	if n <= 0 {
		return nil
	}
	g := &turnCap{max: n, stop: stop}
	if runHome != "" {
		g.rollout = &rolloutTurns{home: runHome}
	}
	return g
}

// line counts one stdout line; false once the cap stopped the run, so the
// line — the start of the turn past the cap — is not delivered.
func (g *turnCap) line(b []byte) bool {
	if g == nil {
		return true
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stopped {
		return false
	}
	var ev CodexEvent
	if json.Unmarshal(b, &ev) == nil {
		g.stream.event(&ev)
	}
	g.checkLocked(false)
	return !g.stopped
}

// watch re-reads the rollout until ctx ends; a no-op without one.
func (g *turnCap) watch(ctx context.Context) {
	if g == nil || g.rollout == nil {
		return
	}
	tick := time.NewTicker(rolloutPollInterval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			g.mu.Lock()
			if !g.stopped {
				g.checkLocked(false)
			}
			g.mu.Unlock()
		}
	}
}

// done is the run's last check, once codex exited: the budget failure of a
// run the cap stopped or whose finished rollout records more responses than
// the cap (a last, text-only response is recorded as codex ends), nil
// otherwise.
func (g *turnCap) done() error {
	if g == nil {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.stopped {
		g.checkLocked(true)
	}
	if g.stopped {
		return errTurnCap(g.max)
	}
	return nil
}

// checkLocked stops the run once its turns pass the cap: the rollout's
// count when it can be read, else the stream rule's — which during the run
// decides only the past-the-cap case, so a rollout that is merely not
// written yet costs nothing.
func (g *turnCap) checkLocked(final bool) {
	n := g.stream.turns
	if g.rollout != nil {
		if r, ok := g.rollout.read(); ok {
			n = r
		} else if n > g.max || final {
			g.logFallbackLocked()
		}
	}
	if n > g.max {
		g.stopped = true
		g.stop()
	}
}

// logFallbackLocked logs once that the stream rule counted in place of the
// rollout (a class, never a path: FILES-01).
func (g *turnCap) logFallbackLocked() {
	if g.logged {
		return
	}
	g.logged = true
	reason := "missing"
	if g.rollout.err != nil {
		reason = "unreadable"
	}
	log.Printf("codex: the run's rollout is %s; its turn cap counts the stream instead", reason)
}

// lineSink is QuerySync's stdout: it keeps everything (the parse after
// exit) and hands each complete line to the turn cap as it arrives.
type lineSink struct {
	buf     bytes.Buffer
	pending []byte
	cap     *turnCap
}

func (w *lineSink) Write(p []byte) (int, error) {
	w.buf.Write(p)
	if w.cap == nil {
		return len(p), nil
	}
	w.pending = append(w.pending, p...)
	for {
		i := bytes.IndexByte(w.pending, '\n')
		if i < 0 {
			break
		}
		if line := bytes.TrimSpace(w.pending[:i]); len(line) > 0 {
			w.cap.line(line)
		}
		w.pending = w.pending[i+1:]
	}
	return len(p), nil
}
