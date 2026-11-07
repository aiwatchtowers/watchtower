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
	// seen marks the item ids whose first event was counted; anonOpen
	// counts the id-less tools started and not yet completed (codex runs
	// and reports tools in order: queryStream.anonTool).
	seen     map[string]bool
	anonOpen int
}

// event updates the count with one stream event.
func (t *turnCounter) event(ev *CodexEvent) {
	if ev.Type == "turn.started" {
		*t = turnCounter{turns: 1}
		return
	}
	item := ev.Item
	if item == nil || !strings.HasPrefix(ev.Type, "item.") {
		return
	}
	first := t.firstEvent(ev.Type, item)
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
}

// firstEvent says whether ev is the item's first event. An id-less tool's
// update or completion belongs to the oldest open id-less tool, if any.
func (t *turnCounter) firstEvent(eventType string, item *CodexItem) bool {
	if item.ID != "" {
		if t.seen[item.ID] {
			return false
		}
		if t.seen == nil {
			t.seen = map[string]bool{}
		}
		t.seen[item.ID] = true
		return true
	}
	if !isToolItem(item.Type) {
		return true
	}
	switch {
	case eventType == "item.started":
		t.anonOpen++
		return true
	case t.anonOpen == 0:
		return true // seen first at its update or completion
	case eventType == "item.completed":
		t.anonOpen--
	}
	return false
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

// isToolItem: the item types that are a model's tool call. Wider than the
// ones queryStream shows as tool steps (mcp_tool_call, command_execution):
// a web search or a file change is a call of the model's turn all the same.
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
// once codex writes records they decide the count (the earlier marker
// stops a run as soon as it is there), else the token counts do
// (responses).
type rolloutTurns struct {
	home string
	path string
	off  int64
	// partial is the unfinished last line of the previous read.
	partial            []byte
	tokenCount, record int
	// lastInfo is the usage of the last token_count counted: a refresh that
	// repeats it (a rate-limit update) is no new response.
	lastInfo []byte
	// afterOutput: a tool result was recorded; drift: a model item came
	// after one while the rollout holds no response marker at all — codex
	// records a response's marker before its next response, so the markers
	// changed shape.
	afterOutput, drift bool
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
	return r.responses(), true
}

// responses is the count so far: the token_usage_records when codex writes
// them (one per response, never repeated), else the token_counts with
// usage info.
func (r *rolloutTurns) responses() int {
	if r.record > 0 {
		return r.record
	}
	return r.tokenCount
}

// count adds line's response marker, if it is one.
func (r *rolloutTurns) count(line []byte) {
	if !bytes.Contains(line, []byte("token_count")) && !bytes.Contains(line, []byte("token_usage_record")) &&
		!bytes.Contains(line, []byte(`"response_item"`)) {
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
		// A token_count without usage info, or repeating the last one's
		// cumulative usage, only carries rate limits.
		info := bytes.TrimSpace(ev.Payload.Info)
		if len(info) > 0 && !bytes.Equal(info, []byte("null")) && !bytes.Equal(info, r.lastInfo) {
			r.tokenCount++
			r.lastInfo = append(r.lastInfo[:0], info...)
		}
	case ev.Type == "response_item":
		r.item(ev.Payload.Type)
	}
}

// item notes one response item for the drift check: a tool result, then any
// later item of the model's while no marker was ever recorded.
func (r *rolloutTurns) item(typ string) {
	switch {
	case strings.HasSuffix(typ, "_call_output"):
		r.afterOutput = true
	case r.afterOutput && r.responses() == 0:
		r.drift = true
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
	limit int
	stop  context.CancelFunc

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
	g := &turnCap{limit: n, stop: stop}
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
	g.checkLocked()
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
				g.checkLocked()
			}
			g.mu.Unlock()
		}
	}
}

// done is the run's last check, once codex exited: nil for a run that
// reported its own turn failure (reported: a failed turn in its output,
// which a stop by the cap never writes), so that failure is never
// relabelled a budget one; else the budget failure of a run the cap
// stopped, or of a run that did not fail otherwise (failed: a failed exit
// or no turn.completed) whose finished rollout records more responses than
// the cap (a last, text-only response is recorded as codex ends).
func (g *turnCap) done(reported, failed bool) error {
	if g == nil || reported {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.stopped || !failed && g.overLocked(true) {
		return errTurnCap(g.limit)
	}
	return nil
}

// turnFailed says whether a run's JSONL output ends its turn with a
// failure codex reported (a turn.failed or error event carrying an error,
// queryStream's terminal), not a bare retry notice.
func turnFailed(output []byte) bool {
	failed := false
	for line := range bytes.SplitSeq(output, []byte("\n")) {
		var event CodexEvent
		if json.Unmarshal(bytes.TrimSpace(line), &event) != nil {
			continue
		}
		switch {
		case (event.Type == "turn.failed" || event.Type == "error") && event.Error != nil:
			failed = true
		case event.Type == "turn.started" || event.Type == "turn.completed":
			failed = false
		}
	}
	return failed
}

// checkLocked stops the run once its turns pass the cap.
func (g *turnCap) checkLocked() {
	if g.overLocked(false) {
		g.stopped = true
		g.stop()
	}
}

// overLocked says whether the run's turns pass the cap: the rollout's count
// when it can be read, else the stream rule's — which during the run
// decides only the past-the-cap case, so a rollout that is merely not
// written yet costs nothing. A rollout that counts no response is not
// trusted (its markers changed shape) once it shows drift (a model item
// after a tool result, no marker in between), or at the end once the
// stream saw any turn. A long first response of serial calls is no drift:
// its calls are all recorded before their results.
func (g *turnCap) overLocked(final bool) bool {
	n := g.stream.turns
	if g.rollout != nil {
		r, ok := g.rollout.read()
		noRecords := ok && r == 0 && (g.rollout.drift || final && n > 0)
		switch {
		case ok && !noRecords:
			n = r
		case n > g.limit || final && n > 0:
			g.logFallbackLocked(noRecords)
		}
	}
	return n > g.limit
}

// logFallbackLocked logs once that the stream rule counted in place of the
// rollout (a class, never a path: FILES-01).
func (g *turnCap) logFallbackLocked(noRecords bool) {
	if g.logged {
		return
	}
	g.logged = true
	reason := "missing"
	switch err := g.rollout.err; {
	case noRecords:
		reason = "without response records"
	case errors.Is(err, fs.ErrPermission):
		reason = "unreadable (permission)"
	case err != nil:
		reason = "unreadable (i/o)"
	}
	log.Printf("codex: the run's rollout is %s; its turn cap counts the stream instead (%d turns so far)", reason, g.stream.turns)
}

// lineSink is QuerySync's stdout: it keeps everything (the parse after
// exit) and hands each complete line to the turn cap as it arrives.
type lineSink struct {
	buf     bytes.Buffer
	pending []byte
	turns   *turnCap
}

func (w *lineSink) Write(p []byte) (int, error) {
	w.buf.Write(p)
	if w.turns == nil {
		return len(p), nil
	}
	w.pending = append(w.pending, p...)
	for {
		i := bytes.IndexByte(w.pending, '\n')
		if i < 0 {
			break
		}
		w.hand(w.pending[:i])
		w.pending = w.pending[i+1:]
	}
	return len(p), nil
}

// flush hands the last, unterminated line over once the output ended.
func (w *lineSink) flush() {
	w.hand(w.pending)
	w.pending = nil
}

func (w *lineSink) hand(line []byte) {
	if line = bytes.TrimSpace(line); len(line) > 0 && w.turns != nil {
		w.turns.line(line)
	}
}
