package automations_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/externalmcp"
)

func mcpCase(m *automationstest.FakeMCP, perms ...string) sdkCase {
	clock := automationstest.NewFakeClock(time.Date(2026, 10, 14, 9, 0, 0, 0, time.UTC))
	b := automations.Backends{Generator: &automationstest.FakeGenerator{}, Registry: fakeTools(), Clock: clock}
	if m != nil {
		b.MCP = m
	}
	return sdkCase{perms: perms, backends: &b}
}

func TestMCPModule_ManifestFirst(t *testing.T) {
	m := &automationstest.FakeMCP{Result: json.RawMessage(`{"prs":[1]}`)}
	r := mustReturn(t, `
		const ok = mcp("github", "list_prs", {state: "open"}).prs[0];
		try { mcp("github", "create_pr", {}); return "called" } catch (e) { return ok + "|" + e.name + "|" + e.needed }`,
		mcpCase(m, "mcp:github/list_*"), "1|PermissionDenied|mcp:github/create_pr")
	calls := m.Calls()
	if len(calls) != 1 || calls[0].Tool != "list_prs" || string(calls[0].Args) != `{"state":"open"}` {
		t.Fatalf("calls = %+v; want only list_prs", calls)
	}
	steps := r.env.Journal.Steps()
	if len(steps) != 2 || steps[1].Status != automations.StepDenied || steps[1].Name != "github/create_pr" {
		t.Fatalf("steps = %+v; want ok then denied", steps)
	}
}

func TestMCPModule_QC02RefusalIsPermissionDenied(t *testing.T) {
	m := &automationstest.FakeMCP{Err: fmt.Errorf("github/delete_repo: %w", automations.ErrMCPToolNotAllowed)}
	r := mustReturn(t, `try { mcp("github", "delete_repo"); return "called" } catch (e) {
		return e.name + "|" + e.needed + "|" + e.message.includes("QC-02") }`,
		mcpCase(m, "mcp:github/*"), "PermissionDenied|mcp:github/delete_repo|true")
	steps := r.env.Journal.Steps()
	if len(steps) != 1 || steps[0].Status != automations.StepDenied || steps[0].Permission != "mcp:github/delete_repo" {
		t.Fatalf("steps = %+v; want one denied step", steps)
	}
}

func TestMCPModule_NotAvailable(t *testing.T) {
	cases := map[string]*automationstest.FakeMCP{
		"no caller":   nil,
		"unavailable": {Err: automations.ErrMCPNotAvailable},
	}
	for name, m := range cases {
		t.Run(name, func(t *testing.T) {
			mustReturn(t, `try { mcp("github", "list_prs"); return "called" } catch (e) { return e.name }`,
				mcpCase(m, "mcp:github/*"), "NotAvailable")
		})
	}

	// The caller's cause reaches the script and the journal.
	m := &automationstest.FakeMCP{Err: fmt.Errorf("%w: %q's tools were never listed — `watchtower connections tools 3 --refresh`",
		automations.ErrMCPNotAvailable, "github")}
	want := "Quick Connection \"github\" is not available: \"github\"'s tools were never listed — `watchtower connections tools 3 --refresh`"
	r := mustReturn(t, `try { mcp("github", "list_prs"); return "called" } catch (e) { return e.name + "|" + e.message }`,
		mcpCase(m, "mcp:github/*"), "NotAvailable|"+want)
	if steps := r.env.Journal.Steps(); len(steps) != 1 || !strings.Contains(steps[0].Error, want) {
		t.Fatalf("steps = %+v; want the cause journalled", steps)
	}
}

// A malformed call journals a placeholder name, never "/"; any other caller
// failure (a database read) is a ToolError carrying its cause.
func TestMCPModule_MalformedCallAndOtherFailures(t *testing.T) {
	r := mustReturn(t, `try { mcp("", 1); return "called" } catch (e) { return e.name }`,
		mcpCase(&automationstest.FakeMCP{}, "mcp:github/*"), "ValidationError")
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Name != "invalid" {
		t.Fatalf("steps = %+v; want one step named invalid", steps)
	}
	m := &automationstest.FakeMCP{Err: fmt.Errorf("listing Quick Connections: %w", errors.New("database is locked"))}
	mustReturn(t, `try { mcp("github", "list_prs"); return "called" } catch (e) { return e.name + "|" + e.message }`,
		mcpCase(m, "mcp:github/*"), "ToolError|github/list_prs: listing Quick Connections: database is locked")
}

func TestMCPModule_ToolErrorAndValidation(t *testing.T) {
	m := &automationstest.FakeMCP{Err: &externalmcp.ToolError{Message: "rate limited"}}
	mustReturn(t, `try { mcp("github", "list_prs"); return "called" } catch (e) { return e.name + "|" + e.message }`,
		mcpCase(m, "mcp:github/*"), "ToolError|github/list_prs: rate limited")
	mustReturn(t, `try { mcp("github", "list_prs", [1]); return "called" } catch (e) { return e.name }`,
		mcpCase(&automationstest.FakeMCP{}, "mcp:github/*"), "ValidationError")
}

func TestMCPModule_ResultTooLarge(t *testing.T) {
	big, _ := json.Marshal(map[string]string{"text": strings.Repeat("x", automations.MaxSDKResultBytes)})
	m := &automationstest.FakeMCP{Result: big}
	mustReturn(t, `try { mcp("github", "list_prs"); return "called" } catch (e) { return e.name }`,
		mcpCase(m, "mcp:github/*"), "ResultTooLarge")
}

func TestMCPModule_DryRunCallsForReal(t *testing.T) {
	m := &automationstest.FakeMCP{Result: json.RawMessage(`{"n":2}`)}
	c := mcpCase(m, "mcp:github/*")
	c.dryRun = true
	r := mustReturn(t, `return mcp("github", "list_prs").n`, c, 2)
	if len(m.Calls()) != 1 {
		t.Fatalf("calls = %d; want 1", len(m.Calls()))
	}
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepOK {
		t.Fatalf("steps = %+v; want one ok step", steps)
	}
}

// AUTO-11: one journal step per call.
func TestMCPModule_OneStepPerCall(t *testing.T) {
	m := &automationstest.FakeMCP{} // empty result = null
	r := mustReturn(t, `mcp("github", "list_prs"); mcp("github", "list_issues", {}); return mcp("github", "list_prs") === null`,
		mcpCase(m, "mcp:github/*"), true)
	steps := r.env.Journal.Steps()
	if len(steps) != 3 {
		t.Fatalf("steps = %d; want 3", len(steps))
	}
	for _, s := range steps {
		if s.Kind != "mcp" || s.Status != automations.StepOK || s.Permission != "mcp:github/*" {
			t.Fatalf("step = %+v; want ok mcp step admitted by mcp:github/*", s)
		}
	}
	if steps[1].Name != "github/list_issues" {
		t.Fatalf("name = %q", steps[1].Name)
	}
}
