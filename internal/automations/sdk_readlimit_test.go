package automations_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"watchtower/internal/auditlog"
	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// budgetCase is an SDK case over a real *tools.Registry holding one
// company-data read tool ("co_read", returning one row) with limits.
func budgetCase(t *testing.T, l tools.ReadLimits, m *automationstest.FakeMCP, perms ...string) sdkCase {
	t.Helper()
	reg := tools.New(nil)
	reg.SetReadLimits(l)
	if err := reg.Register(&tools.Tool{
		Name: "co_read", Description: "test company read", Access: tools.AccessRead, CompanyData: true,
		InputSchema: listSchema(),
		Execute: func(context.Context, *db.DB, tools.Call) (any, error) {
			return []map[string]any{{"id": 1}}, nil
		},
	}); err != nil {
		t.Fatal(err)
	}
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	b := automations.Backends{Generator: &automationstest.FakeGenerator{}, Registry: reg, Clock: clock}
	if m != nil {
		b.MCP = m
	}
	return sdkCase{perms: perms, outputs: []string{"inbox"}, backends: &b}
}

func captureLines(t *testing.T) func() []string {
	t.Helper()
	var lines []string
	t.Cleanup(auditlog.SetSinkForTest(func(s string) { lines = append(lines, s) }))
	return func() []string { return lines }
}

func readLimits(calls int) tools.ReadLimits {
	return tools.ReadLimits{Calls: calls, Rows: 1000, ResponseRows: tools.MaxListLimit, ResponseBytes: tools.MaxReadResultBytes}
}

// AUTO-08 amendment (#606, ask #567): reaching the read budget is a catchable
// ValidationError on that call; the run goes on.
func TestAuto08_ReadLimitIsCatchable(t *testing.T) {
	captureLines(t)
	r := mustReturn(t, `
		tool("co_read", {});
		let caught = "";
		try { tool("co_read", {}); } catch (e) { caught = e.name + "|" + e.message.includes("read limit is reached"); }
		output.inbox({title: "t", body: caught});
		return caught`,
		budgetCase(t, readLimits(1), nil, "tool:co_read"), "ValidationError|true")
	if r.err != nil {
		t.Fatalf("run failed: %v", r.err)
	}
}

func TestAuto08_ToolResultTooLargeName(t *testing.T) {
	err := automations.RegistryErrorForTest(&tools.Tool{Name: "co_read"},
		&tools.ValidationError{Msg: "the result is 300000 bytes; the limit is 262144 — narrow the request", Err: tools.ErrResultTooLarge})
	var se *automations.SDKError
	if !errors.As(err, &se) || se.Name != automations.ErrNameResultTooLarge {
		t.Fatalf("err = %#v; want a ResultTooLarge SDK error", err)
	}
	err = automations.RegistryErrorForTest(&tools.Tool{Name: "co_read"},
		&tools.ValidationError{Msg: "this session's read limit is reached (1 calls / 1000 rows); the owner can start a new session", Err: tools.ErrReadLimit})
	if !errors.As(err, &se) || se.Name != automations.ErrNameValidation {
		t.Fatalf("err = %#v; want a ValidationError SDK error", err)
	}
}

func TestAuto08_MCPCountsAgainstRunBudget(t *testing.T) {
	captureLines(t)
	m := &automationstest.FakeMCP{Result: json.RawMessage(`{"prs":[1]}`)}
	mustReturn(t, `
		tool("co_read", {});
		try { mcp("github", "list_prs", {}); return "called" } catch (e) { return e.name }`,
		budgetCase(t, readLimits(1), m, "tool:co_read", "mcp:github/*"), "ValidationError")
	if n := len(m.Calls()); n != 0 {
		t.Fatalf("external calls = %d; want none past the budget", n)
	}

	lines := captureLines(t)
	m = &automationstest.FakeMCP{Result: json.RawMessage(`{"prs":[1]}`)}
	mustReturn(t, `return mcp("github", "list_prs", {}).prs[0]`,
		budgetCase(t, readLimits(5), m, "mcp:github/*"), 1)
	got := lines()
	if len(got) != 1 || !strings.Contains(got[0], `"tool":"mcp:github/list_prs"`) ||
		!strings.Contains(got[0], `"session":"run:42"`) || !strings.Contains(got[0], `"result":"ok"`) ||
		!strings.Contains(got[0], `"bytes":11`) {
		t.Fatalf("lines = %v; want one ok line for mcp:github/list_prs in run:42", got)
	}
}

// Each mcp() outcome leaves exactly one line: the refusal limit_reached, a
// failed call error, a result over the SDK cap too_large.
func TestAuto08_MCPLineOutcomes(t *testing.T) {
	big, _ := json.Marshal(map[string]string{"text": strings.Repeat("x", automations.MaxSDKResultBytes)})
	cases := []struct {
		name   string
		limits tools.ReadLimits
		mcp    *automationstest.FakeMCP
		want   string
	}{
		{"refused", readLimits(0), &automationstest.FakeMCP{Result: json.RawMessage(`{}`)}, `"result":"limit_reached"`},
		{"error", readLimits(5), &automationstest.FakeMCP{Err: errors.New("boom")}, `"result":"error"`},
		{"too large", readLimits(5), &automationstest.FakeMCP{Result: big}, `"result":"too_large"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			lines := captureLines(t)
			runSDK(t, `try { mcp("github", "list_prs", {}); return "called" } catch (e) { return e.name }`,
				budgetCase(t, c.limits, c.mcp, "mcp:github/*"))
			got := lines()
			if len(got) != 1 || !strings.Contains(got[0], c.want) || !strings.Contains(got[0], `"tool":"mcp:github/list_prs"`) {
				t.Fatalf("lines = %v; want one line with %s", got, c.want)
			}
			if c.name == "refused" && len(c.mcp.Calls()) != 0 {
				t.Fatalf("a refused call reached the server")
			}
		})
	}
}
