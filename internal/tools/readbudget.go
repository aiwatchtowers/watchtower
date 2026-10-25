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
// Rows per session, ResponseRows and ResponseBytes per response.
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

// AdmitRead counts a company-data call against b's session now — reserving
// its slot before the read runs, so parallel calls never pass the cap — or
// refuses it with a ValidationError wrapping ErrReadLimit and logs the
// refusal. A caller that reads outside CallRead (automations' mcp()) pairs it
// with RecordRead.
func (r *Registry) AdmitRead(b Binding, tool string) error {
	return r.admitRead(b, tool, nil)
}

func (r *Registry) admitRead(b Binding, tool string, filters []string) error {
	key := r.ReadSessionKey(b)
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

// RecordRead adds an admitted call's rows to b's session and writes its
// audit line. result is one of the auditlog.Result* values.
func (r *Registry) RecordRead(b Binding, tool string, filters []string, rows, size int, result string) {
	key := r.ReadSessionKey(b)
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
	filters := argNames(args)
	if err := r.admitRead(b, t.Name, filters); err != nil {
		return nil, err
	}
	if err := t.validateSchema(args); err != nil {
		r.RecordRead(b, t.Name, filters, 0, 0, auditlog.ResultError)
		return nil, err
	}
	res, err := t.Execute(ctx, r.db, Call{Args: args, Binding: b})
	if err != nil {
		r.RecordRead(b, t.Name, filters, 0, 0, auditlog.ResultError)
		return nil, err
	}
	raw, err := json.Marshal(res)
	if err != nil {
		r.RecordRead(b, t.Name, filters, 0, 0, auditlog.ResultError)
		return nil, fmt.Errorf("%s: encoding the result: %w", t.Name, err)
	}
	r.reads.mu.Lock()
	l := r.reads.limits
	r.reads.mu.Unlock()
	rows := countRows(raw)
	switch {
	case len(raw) > l.ResponseBytes:
		r.RecordRead(b, t.Name, filters, 0, len(raw), auditlog.ResultTooLarge)
		return nil, &ValidationError{
			Msg: fmt.Sprintf("the result is %d bytes; the limit is %d — narrow the request", len(raw), l.ResponseBytes),
			Err: ErrResultTooLarge,
		}
	case hasLimitArg(t) && rows > l.ResponseRows:
		// The backstop behind the tool's own listLimit clamp.
		r.RecordRead(b, t.Name, filters, 0, len(raw), auditlog.ResultTooLarge)
		return nil, &ValidationError{
			Msg: fmt.Sprintf("the result has %d rows; the limit is %d — narrow the request", rows, l.ResponseRows),
			Err: ErrResultTooLarge,
		}
	}
	r.RecordRead(b, t.Name, filters, rows, len(raw), auditlog.ResultOK)
	return res, nil
}

// hasLimitArg reports whether t's schema takes a `limit` (a list tool).
func hasLimitArg(t *Tool) bool {
	if t.InputSchema == nil {
		return false
	}
	_, ok := t.InputSchema.Properties["limit"]
	return ok
}

// countRows is a marshalled result's row count: a top-level array's length;
// for an object, the sum of its top-level arrays' lengths, or 1 when it has
// none; 0 for null; 1 for any other value.
func countRows(raw []byte) int {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return 0
	}
	switch raw[0] {
	case '[':
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil {
			return 1
		}
		return len(items)
	case '{':
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil {
			return 1
		}
		sum, arrays := 0, 0
		for _, v := range fields {
			v = bytes.TrimSpace(v)
			if len(v) == 0 || v[0] != '[' {
				continue
			}
			var items []json.RawMessage
			if json.Unmarshal(v, &items) == nil {
				sum += len(items)
				arrays++
			}
		}
		if arrays == 0 {
			return 1
		}
		return sum
	}
	return 1
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
