package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auditlog"
	"watchtower/internal/db"
)

// captureAudit replaces the unified-log sink for the test and returns the
// lines written, decoded.
func captureAudit(t *testing.T) func() []map[string]any {
	t.Helper()
	var mu sync.Mutex
	var lines []string
	restore := auditlog.SetSinkForTest(func(s string) {
		mu.Lock()
		lines = append(lines, s)
		mu.Unlock()
	})
	t.Cleanup(restore)
	return func() []map[string]any {
		mu.Lock()
		defer mu.Unlock()
		out := make([]map[string]any, 0, len(lines))
		for _, l := range lines {
			var m map[string]any
			require.NoError(t, json.Unmarshal([]byte(l), &m), l)
			out = append(out, m)
		}
		return out
	}
}

// rawAudit returns the raw lines written during the test.
func rawAudit(t *testing.T) func() []string {
	t.Helper()
	var mu sync.Mutex
	var lines []string
	restore := auditlog.SetSinkForTest(func(s string) {
		mu.Lock()
		lines = append(lines, s)
		mu.Unlock()
	})
	t.Cleanup(restore)
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), lines...)
	}
}

type companyArgs struct {
	Query  string `json:"query,omitempty"`
	Person string `json:"person,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

type plainArgs struct {
	Query string `json:"query,omitempty"`
}

// newCompanyTool is a CompanyData read tool returning result (or err), with
// a `limit` schema property when withLimit; calls counts its Executes.
func newCompanyTool(t *testing.T, name string, withLimit bool, calls *atomic.Int64, result func() (any, error)) *Tool {
	t.Helper()
	var schema *jsonschema.Schema
	var err error
	if withLimit {
		schema, err = jsonschema.For[companyArgs](nil)
	} else {
		schema, err = jsonschema.For[plainArgs](nil)
	}
	require.NoError(t, err)
	return &Tool{
		Name: name, Description: "test company read", InputSchema: schema,
		Access: AccessRead, CompanyData: true,
		Execute: func(context.Context, *db.DB, Call) (any, error) {
			calls.Add(1)
			return result()
		},
	}
}

func rowsOf(n int) []map[string]any {
	out := make([]map[string]any, n)
	for i := range out {
		out[i] = map[string]any{"i": i}
	}
	return out
}

func testLimits(calls, rows int) ReadLimits {
	return ReadLimits{Calls: calls, Rows: rows, ResponseRows: MaxListLimit, ResponseBytes: MaxReadResultBytes}
}

func newBudgetRegistry(t *testing.T, l ReadLimits, ts ...*Tool) *Registry {
	t.Helper()
	reg := New(openDB(t))
	reg.SetReadLimits(l)
	for _, tool := range ts {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func TestRead01_RefusesPastCallCap(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", true, &n, func() (any, error) { return rowsOf(1), nil })
	reg := newBudgetRegistry(t, testLimits(2, 1000), tool)
	b := Binding{Surface: "main", ConversationID: 1}
	for range 2 {
		_, err := reg.CallRead(context.Background(), "co", nil, b)
		require.NoError(t, err)
	}
	_, err := reg.CallRead(context.Background(), "co", nil, b)
	require.ErrorIs(t, err, ErrReadLimit)
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "this session's read limit is reached (2 calls / 1000 rows); the owner can start a new session", ve.Msg)
	assert.EqualValues(t, 2, n.Load(), "no Execute past the cap")
}

func TestRead01_RefusesPastRowCap(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(60), nil })
	reg := newBudgetRegistry(t, testLimits(100, 100), tool)
	b := Binding{Surface: "main", ConversationID: 1}
	for range 2 {
		_, err := reg.CallRead(context.Background(), "co", nil, b)
		require.NoError(t, err)
	}
	_, err := reg.CallRead(context.Background(), "co", nil, b)
	require.ErrorIs(t, err, ErrReadLimit)
	assert.EqualValues(t, 2, n.Load())
}

func TestRead01_NewSessionNewBudget(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(1), nil })
	reg := newBudgetRegistry(t, testLimits(1, 1000), tool)
	_, err := reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.NoError(t, err)
	_, err = reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, ErrReadLimit)
	_, err = reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 2})
	require.NoError(t, err, "a new session starts a fresh budget")
}

func TestRead01_SessionKeys(t *testing.T) {
	reg := New(nil)
	assert.Equal(t, "run:5", reg.ReadSessionKey(Binding{AutomationRunID: 5, ConversationID: 9}))
	assert.Equal(t, "conversation:9", reg.ReadSessionKey(Binding{ConversationID: 9}))
	assert.Equal(t, fmt.Sprintf("pid:%d", os.Getpid()), reg.ReadSessionKey(Binding{}))
	reg.SetProcessSession("terminal:42")
	assert.Equal(t, "terminal:42", reg.ReadSessionKey(Binding{WorkbenchID: 3}))
	assert.Equal(t, "conversation:9", reg.ReadSessionKey(Binding{ConversationID: 9}))
}

func TestRead01_TooLargeRefused(t *testing.T) {
	lines := captureAudit(t)
	var n atomic.Int64
	big := strings.Repeat("x", 300*1024)
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return map[string]any{"text": big}, nil })
	reg := newBudgetRegistry(t, testLimits(10, 1000), tool)
	_, err := reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, ErrResultTooLarge)
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "; the limit is 262144 — narrow the request")
	assert.True(t, strings.HasPrefix(ve.Msg, "the result is "), ve.Msg)
	got := lines()
	require.Len(t, got, 1)
	assert.Equal(t, "too_large", got[0]["result"])
	assert.EqualValues(t, 1, got[0]["calls"], "the call is debited")
	assert.EqualValues(t, 1, got[0]["rows"], "the rows read are debited though refused")
	assert.EqualValues(t, 1, got[0]["rows_total"])
}

func TestRead01_ListRowsBackstop(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	withLimit := newCompanyTool(t, "list_co", true, &n, func() (any, error) { return rowsOf(201), nil })
	without := newCompanyTool(t, "get_co", false, &n, func() (any, error) { return rowsOf(201), nil })
	reg := newBudgetRegistry(t, testLimits(10, 10000), withLimit, without)
	_, err := reg.CallRead(context.Background(), "list_co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, ErrResultTooLarge)
	_, err = reg.CallRead(context.Background(), "get_co", nil, Binding{ConversationID: 1})
	require.NoError(t, err)
}

func TestRead01_RowCounting(t *testing.T) {
	cases := []struct {
		raw           string
		rows, largest int
	}{
		{`[1,2,3]`, 3, 3},
		{`{"a":[1,2],"b":[3],"c":"x"}`, 3, 2},
		{`{"x":1}`, 1, 0},
		{`{"items":[]}`, 0, 0},
		{`null`, 0, 0},
		{`"text"`, 1, 0},
	}
	for _, c := range cases {
		rows, largest := countRows([]byte(c.raw))
		assert.Equal(t, c.rows, rows, c.raw)
		assert.Equal(t, c.largest, largest, c.raw)
	}
}

// A result with two lists each under the per-response row cap is served even
// when together they pass it (find_experts: experts and evidence); the sum
// is still debited.
func TestRead01_ListRowsBackstopUsesThePrimaryList(t *testing.T) {
	lines := captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "find_co", true, &n, func() (any, error) {
		return map[string]any{"experts": rowsOf(150), "evidence": rowsOf(150)}, nil
	})
	reg := newBudgetRegistry(t, testLimits(10, 10000), tool)
	_, err := reg.CallRead(context.Background(), "find_co", nil, Binding{ConversationID: 1})
	require.NoError(t, err)
	got := lines()
	require.Len(t, got, 1)
	assert.EqualValues(t, 300, got[0]["rows"])
}

func TestReadGate_PanicIsRecorded(t *testing.T) {
	lines := captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { panic("boom") })
	reg := newBudgetRegistry(t, testLimits(1, 1000), tool)
	assert.PanicsWithValue(t, "boom", func() {
		_, _ = reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	}, "the panic is re-raised")
	got := lines()
	require.Len(t, got, 1)
	assert.Equal(t, "error", got[0]["result"])
	_, err := reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, ErrReadLimit, "the panicked call stays counted")
}

func TestReadGate_ErrorCountsAsCall(t *testing.T) {
	lines := captureAudit(t)
	var n atomic.Int64
	boom := errors.New("boom")
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return nil, boom })
	reg := newBudgetRegistry(t, testLimits(1, 1000), tool)
	_, err := reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, boom, "the tool's error is returned unchanged")
	got := lines()
	require.Len(t, got, 1)
	assert.Equal(t, "error", got[0]["result"])
	assert.EqualValues(t, 0, got[0]["rows"])
	_, err = reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
	require.ErrorIs(t, err, ErrReadLimit)
	assert.EqualValues(t, 1, n.Load())
}

func TestReadGate_ConcurrentCallsNeverExceedCap(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(1), nil })
	reg := newBudgetRegistry(t, testLimits(10, 100000), tool)
	var wg sync.WaitGroup
	for range 50 {
		wg.Go(func() {
			_, _ = reg.CallRead(context.Background(), "co", nil, Binding{ConversationID: 1})
		})
	}
	wg.Wait()
	assert.EqualValues(t, 10, n.Load())
}

func TestReadGate_UnmarkedToolIgnoresBudget(t *testing.T) {
	raw := rawAudit(t)
	var n atomic.Int64
	co := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(1), nil })
	var peeked []Call
	reg := newBudgetRegistry(t, testLimits(1, 1000), co, newPeekTool(t, &peeked))
	b := Binding{ConversationID: 1}
	_, err := reg.CallRead(context.Background(), "co", nil, b)
	require.NoError(t, err)
	_, err = reg.CallRead(context.Background(), "co", nil, b)
	require.ErrorIs(t, err, ErrReadLimit)
	before := len(raw())
	_, err = reg.CallRead(context.Background(), "peek", json.RawMessage(`{"query":"q"}`), b)
	require.NoError(t, err, "an unmarked read runs on a spent session")
	assert.Len(t, peeked, 1)
	assert.Len(t, raw(), before, "an unmarked read writes no line")
}

func TestRead02_OneLinePerCall(t *testing.T) {
	lines := captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(2), nil })
	reg := newBudgetRegistry(t, testLimits(3, 1000), tool)
	wb := seedWorkbench(t, reg.db, "audit")
	b := Binding{Surface: WorkbenchSurface, WorkbenchID: wb, Agent: "codex", DirectApply: true}
	reg.SetProcessSession("terminal:42")
	for range 3 {
		_, err := reg.CallRead(context.Background(), "co", nil, b)
		require.NoError(t, err)
	}
	_, err := reg.CallRead(context.Background(), "co", nil, b)
	require.ErrorIs(t, err, ErrReadLimit)
	got := lines()
	require.Len(t, got, 4)
	for i, l := range got[:3] {
		assert.Equal(t, "ok", l["result"])
		assert.EqualValues(t, i+1, l["calls"])
		assert.EqualValues(t, 2*(i+1), l["rows_total"])
		assert.EqualValues(t, 2, l["rows"])
	}
	last := got[3]
	assert.EqualValues(t, 3, last["calls"])
	assert.Equal(t, "limit_reached", last["result"])
	for _, l := range got {
		assert.Equal(t, WorkbenchSurface, l["surface"])
		assert.Equal(t, "terminal:42", l["session"])
		assert.EqualValues(t, wb, l["workbench"])
		assert.Equal(t, "codex", l["agent"])
		assert.Equal(t, "co", l["tool"])
		assert.EqualValues(t, 1, l["v"])
	}
}

func TestRead02_LineCarriesNoContent(t *testing.T) {
	raw := rawAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", true, &n, func() (any, error) {
		return []map[string]any{{"text": "MARKER-r", "from": "MARKER-r"}}, nil
	})
	reg := newBudgetRegistry(t, testLimits(10, 1000), tool)
	_, err := reg.CallRead(context.Background(), "co",
		json.RawMessage(`{"query":"MARKER-q","person":"MARKER-p","limit":5}`), Binding{ConversationID: 1})
	require.NoError(t, err)
	got := raw()
	require.Len(t, got, 1)
	assert.NotContains(t, got[0], "MARKER")
	var m struct {
		Filters []string `json:"filters"`
	}
	require.NoError(t, json.Unmarshal([]byte(got[0]), &m))
	assert.Equal(t, []string{"limit", "person", "query"}, m.Filters)
}

func TestRead02_FiltersSkipNull(t *testing.T) {
	schema := &jsonschema.Schema{Type: "object", Properties: map[string]*jsonschema.Schema{
		"a": {Type: "string"}, "b": {Type: "string"}, "c": {Type: "integer"},
	}}
	assert.Equal(t, []string{"a", "c"}, argNames(json.RawMessage(`{"c":0,"b":null,"a":"x"}`), schema))
	assert.Empty(t, argNames(json.RawMessage(`{}`), schema))
}

// A key the schema does not declare may itself be content: it never reaches
// the line, only one placeholder does.
func TestRead02_UnknownArgNamesNeverReachTheLine(t *testing.T) {
	raw := rawAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", true, &n, func() (any, error) { return rowsOf(1), nil })
	reg := newBudgetRegistry(t, testLimits(10, 1000), tool)
	_, _ = reg.CallRead(context.Background(), "co",
		json.RawMessage(`{"query":"q","colleague.a@example.com":"x","other_key":1}`), Binding{ConversationID: 1})
	got := raw()
	require.Len(t, got, 1)
	assert.NotContains(t, got[0], "example")
	assert.NotContains(t, got[0], "colleague")
	assert.NotContains(t, got[0], "other_key")
	assert.Contains(t, got[0], `"filters":["_other","query"]`)
}

func TestRead02_WritesNoRow(t *testing.T) {
	captureAudit(t)
	var n atomic.Int64
	tool := newCompanyTool(t, "co", false, &n, func() (any, error) { return rowsOf(1), nil })
	reg := newBudgetRegistry(t, testLimits(10, 1000), tool)
	require.NoError(t, reg.db.SetReadOnly())
	_, err := reg.CallRead(context.Background(), "co", nil, Binding{})
	require.NoError(t, err, "the gate writes nothing, so a query_only handle serves it (DEV-01, AGENT-02)")
	assert.EqualValues(t, 1, n.Load())
}

func TestReadExternal_RecordsEveryOutcome(t *testing.T) {
	lines := captureAudit(t)
	reg := New(nil)
	reg.SetReadLimits(testLimits(3, 1000))
	b := Binding{AutomationRunID: 7}

	require.NoError(t, reg.ReadExternal(b, "mcp:acme/list", func() (int, error) { return 10, nil }))
	boom := errors.New("boom")
	require.ErrorIs(t, reg.ReadExternal(b, "mcp:acme/list", func() (int, error) { return 0, boom }), boom)
	assert.PanicsWithValue(t, "p", func() {
		_ = reg.ReadExternal(b, "mcp:acme/list", func() (int, error) { panic("p") })
	})
	ran := false
	err := reg.ReadExternal(b, "mcp:acme/list", func() (int, error) { ran = true; return 0, nil })
	require.ErrorIs(t, err, ErrReadLimit)
	assert.False(t, ran, "a spent budget never runs fn")

	got := lines()
	require.Len(t, got, 4)
	for i, want := range []string{"ok", "error", "error", "limit_reached"} {
		assert.Equal(t, want, got[i]["result"], i)
		assert.Equal(t, "run:7", got[i]["session"])
		assert.Equal(t, "mcp:acme/list", got[i]["tool"])
	}
	assert.EqualValues(t, 10, got[0]["bytes"])
}

func TestReadExternal_RefusesOverTheByteCap(t *testing.T) {
	lines := captureAudit(t)
	reg := New(nil)
	reg.SetReadLimits(ReadLimits{Calls: 10, Rows: 1000, ResponseRows: MaxListLimit, ResponseBytes: 100})
	err := reg.ReadExternal(Binding{AutomationRunID: 7}, "mcp:acme/list", func() (int, error) { return 101, nil })
	require.ErrorIs(t, err, ErrResultTooLarge)
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "the result is 101 bytes; the limit is 100 — narrow the request", ve.Msg)
	require.NoError(t, reg.ReadExternal(Binding{AutomationRunID: 7}, "mcp:acme/list", func() (int, error) { return 100, nil }))
	got := lines()
	require.Len(t, got, 2)
	assert.Equal(t, "too_large", got[0]["result"])
	assert.Equal(t, "ok", got[1]["result"])
}
