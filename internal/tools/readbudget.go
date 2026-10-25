package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"sync"

	"watchtower/internal/auditlog"
)

// ReadLimits bound the company-data reads of one session (READ-01, spec
// docs/superpowers/specs/2026-10-25-bulk-read-limits-design.md §2): Calls and
// Rows per session, ResponseRows and ResponseBytes per response. Calls is
// exact; Rows is soft — rows are debited after each read, so reads admitted
// in parallel may together pass it (recordRead).
type ReadLimits struct{ Calls, Rows, ResponseRows, ResponseBytes int }

// DefaultReadLimits are the built-in limits (approved 2026-10-25, ask #567).
// No config key sets them, so an agent cannot raise its own budget; #608's
// managed policy is the one seam that may replace them (SetReadLimits).
var DefaultReadLimits = ReadLimits{Calls: 300, Rows: 5000, ResponseRows: MaxListLimit, ResponseBytes: MaxReadResultBytes}

var (
	// ErrReadLimit is behind the ValidationError of a call past the session's
	// read budget.
	ErrReadLimit = errors.New("read limit reached")
	// ErrResultTooLarge is behind the ValidationError of a result over the
	// per-response cap.
	ErrResultTooLarge = errors.New("result too large")
)

// readUsage is one session's spend.
type readUsage struct{ calls, rows int }

// readBudget is the registry's in-memory per-session counter. Nothing is
// written to the database, so a query_only handle serves it (DEV-01).
type readBudget struct {
	mu       sync.Mutex
	limits   ReadLimits
	process  string
	sessions map[string]*readUsage
}

func newReadBudget() *readBudget {
	return &readBudget{
		limits:   DefaultReadLimits,
		process:  "pid:" + strconv.Itoa(os.Getpid()),
		sessions: map[string]*readUsage{},
	}
}

// SetReadLimits replaces the limits (#608's policy seam; tests).
func (r *Registry) SetReadLimits(l ReadLimits) {
	r.reads.mu.Lock()
	r.reads.limits = l
	r.reads.mu.Unlock()
}

// SetProcessSession sets the session key of calls that carry neither an
// automation run nor a conversation: one per MCP server process
// ("terminal:<id>" in a workbench terminal; the default is "pid:<pid>").
func (r *Registry) SetProcessSession(key string) {
	r.reads.mu.Lock()
	r.reads.process = key
	r.reads.mu.Unlock()
}

// ReadSessionKey is the read-budget session b belongs to: its automation
// run, else its conversation, else this process.
func (r *Registry) ReadSessionKey(b Binding) string {
	switch {
	case b.AutomationRunID > 0:
		return "run:" + strconv.FormatInt(b.AutomationRunID, 10)
	case b.ConversationID > 0:
		return "conversation:" + strconv.FormatInt(b.ConversationID, 10)
	}
	r.reads.mu.Lock()
	defer r.reads.mu.Unlock()
	return r.reads.process
}

// ReadExternal runs fn — a read of company data outside the registry's
// tools, such as an automation's mcp() call named "mcp:<server>/<tool>" —
// inside b's read budget: it counts the call before fn runs (a spent budget
// is refused with a ValidationError wrapping ErrReadLimit and fn never
// runs), then writes the call's one audit line: error when fn fails or
// panics (the panic is re-raised), too_large when size passes the
// per-response byte cap — refused like a registry read, with a
// ValidationError wrapping ErrResultTooLarge, and the caller drops the
// result — else ok. No rows are counted: the result's shape is not the
// registry's. fn's error is returned unchanged.
func (r *Registry) ReadExternal(b Binding, name string, fn func() (size int, err error)) error {
	key := r.ReadSessionKey(b)
	if err := r.admitRead(b, key, name, nil); err != nil {
		return err
	}
	finished := false
	defer func() {
		if !finished {
			r.recordRead(b, key, name, nil, 0, 0, auditlog.ResultError)
		}
	}()
	size, err := fn()
	finished = true
	r.reads.mu.Lock()
	maxBytes := r.reads.limits.ResponseBytes
	r.reads.mu.Unlock()
	switch {
	case err != nil:
		r.recordRead(b, key, name, nil, 0, 0, auditlog.ResultError)
	case size > maxBytes:
		r.recordRead(b, key, name, nil, 0, size, auditlog.ResultTooLarge)
		return &ValidationError{
			Msg: fmt.Sprintf("the result is %d bytes; the limit is %d — narrow the request", size, maxBytes),
			Err: ErrResultTooLarge,
		}
	default:
		r.recordRead(b, key, name, nil, 0, size, auditlog.ResultOK)
	}
	return err
}

// admitRead counts a company-data call against the session key now —
// reserving its slot before the read runs, so parallel calls never pass the
// cap — or refuses it with a ValidationError wrapping ErrReadLimit and logs
// the refusal.
func (r *Registry) admitRead(b Binding, key, tool string, filters []string) error {
	r.reads.mu.Lock()
	l := r.reads.limits
	u := r.reads.usage(key)
	if u.calls >= l.Calls || u.rows >= l.Rows {
		calls, rows := u.calls, u.rows
		r.reads.mu.Unlock()
		auditlog.Read(readEvent(b, key, tool, filters, 0, 0, calls, rows, auditlog.ResultLimitReached))
		return &ValidationError{
			Msg: fmt.Sprintf("this session's read limit is reached (%d calls / %d rows); the owner can start a new session", l.Calls, l.Rows),
			Err: ErrReadLimit,
		}
	}
	u.calls++
	r.reads.mu.Unlock()
	return nil
}

// recordRead adds an admitted call's rows to the session and writes its
// audit line. result is one of the auditlog.Result* values.
//
// The row cap is soft: rows are debited here, after the read, so calls
// admitted in parallel while the session was under the cap may together pass
// it. The call cap is exact — admitRead reserves the slot before the read.
func (r *Registry) recordRead(b Binding, key, tool string, filters []string, rows, size int, result string) {
	r.reads.mu.Lock()
	u := r.reads.usage(key)
	u.rows += rows
	calls, total := u.calls, u.rows
	r.reads.mu.Unlock()
	auditlog.Read(readEvent(b, key, tool, filters, rows, size, calls, total, result))
}

// usage returns key's counter, creating it. Called with mu held.
func (rb *readBudget) usage(key string) *readUsage {
	u := rb.sessions[key]
	if u == nil {
		u = &readUsage{}
		rb.sessions[key] = u
	}
	return u
}

func readEvent(b Binding, key, tool string, filters []string, rows, size, calls, total int, result string) auditlog.Event {
	return auditlog.Event{
		Surface: b.Surface, Session: key, Workbench: b.WorkbenchID, Agent: string(b.Agent),
		Tool: tool, Filters: filters, Rows: rows, Bytes: size, Calls: calls, RowsTotal: total,
		Result: result,
	}
}

// callCompanyRead is CallRead's path for a CompanyData tool: admit (or
// refuse) before Execute, measure after it, refuse a result over the
// per-response cap, debit the rows and write the one audit line. args are
// already normalized to valid JSON.
func (r *Registry) callCompanyRead(ctx context.Context, t *Tool, args json.RawMessage, b Binding) (any, error) {
	key := r.ReadSessionKey(b)
	filters := argNames(args)
	record := func(rows, size int, result string) {
		r.recordRead(b, key, t.Name, filters, rows, size, result)
	}
	if err := r.admitRead(b, key, t.Name, filters); err != nil {
		return nil, err
	}
	// A call refused by its schema still counts: failed calls spend the
	// budget too, so a loop of bad calls also reaches the cap.
	if err := t.validateSchema(args); err != nil {
		record(0, 0, auditlog.ResultError)
		return nil, err
	}
	res, err := r.executeRecorded(ctx, t, args, b, func() { record(0, 0, auditlog.ResultError) })
	if err != nil {
		record(0, 0, auditlog.ResultError)
		return nil, err
	}
	raw, err := json.Marshal(res)
	if err != nil {
		record(0, 0, auditlog.ResultError)
		return nil, fmt.Errorf("%s: encoding the result: %w", t.Name, err)
	}
	r.reads.mu.Lock()
	l := r.reads.limits
	r.reads.mu.Unlock()
	rows, largest := countRows(raw)
	switch {
	case len(raw) > l.ResponseBytes:
		// The rows were read, so they are debited even though refused.
		record(rows, len(raw), auditlog.ResultTooLarge)
		return nil, &ValidationError{
			Msg: fmt.Sprintf("the result is %d bytes; the limit is %d — narrow the request", len(raw), l.ResponseBytes),
			Err: ErrResultTooLarge,
		}
	case hasLimitArg(t) && largest > l.ResponseRows:
		// The backstop behind the tool's own listLimit clamp, on the
		// primary (largest) list only.
		record(rows, len(raw), auditlog.ResultTooLarge)
		return nil, &ValidationError{
			Msg: fmt.Sprintf("the result has %d rows; the limit is %d — narrow the request", largest, l.ResponseRows),
			Err: ErrResultTooLarge,
		}
	}
	record(rows, len(raw), auditlog.ResultOK)
	return res, nil
}

// executeRecorded runs t's Execute; a panic inside it is recorded through
// onPanic (the admitted call keeps its line) and then re-raised.
func (r *Registry) executeRecorded(ctx context.Context, t *Tool, args json.RawMessage, b Binding, onPanic func()) (res any, err error) {
	finished := false
	defer func() {
		if !finished {
			onPanic()
		}
	}()
	res, err = t.Execute(ctx, r.db, Call{Args: args, Binding: b})
	finished = true
	return res, err
}

// hasLimitArg reports whether t's schema takes a `limit` (a list tool).
func hasLimitArg(t *Tool) bool {
	if t.InputSchema == nil {
		return false
	}
	_, ok := t.InputSchema.Properties["limit"]
	return ok
}

// countRows measures a marshalled result: rows is a top-level array's
// length; for an object, the sum of its top-level arrays' lengths, or 1 when
// it has none; 0 for null; 1 for any other value. largest is the longest
// single array (the primary list), 0 when there is none.
func countRows(raw []byte) (rows, largest int) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return 0, 0
	}
	switch raw[0] {
	case '[':
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil {
			return 1, 0
		}
		return len(items), len(items)
	case '{':
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil {
			return 1, 0
		}
		arrays := 0
		for _, v := range fields {
			v = bytes.TrimSpace(v)
			if len(v) == 0 || v[0] != '[' {
				continue
			}
			var items []json.RawMessage
			if json.Unmarshal(v, &items) == nil {
				rows += len(items)
				largest = max(largest, len(items))
				arrays++
			}
		}
		if arrays == 0 {
			return 1, 0
		}
		return rows, largest
	}
	return 1, 0
}

// argNames is the sorted names of the arguments that are set (not JSON
// null) — never their values, which may be content (READ-02).
func argNames(args json.RawMessage) []string {
	var fields map[string]json.RawMessage
	if json.Unmarshal(args, &fields) != nil {
		return nil
	}
	names := make([]string, 0, len(fields))
	for k, v := range fields {
		if string(bytes.TrimSpace(v)) != "null" {
			names = append(names, k)
		}
	}
	slices.Sort(names)
	return names
}
