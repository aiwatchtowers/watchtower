package automations_test

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// TestAutomationShell_PolicyRefusedAtStep: with AllowAutomationShell false
// the shell() step throws PolicyError before the manifest check, and no
// process starts, a dry run included.
func TestAutomationShell_PolicyRefusedAtStep(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowAutomationShell": false})
	for _, dry := range []bool{false, true} {
		sh := realShell()
		r := runShell(t, `try { shell("pwd"); return "ran" } catch (e) { return e.name + "|" + e.message }`,
			shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: folderWB(shellFolder(t)), dryRun: dry})
		out, _ := r.out.(string)
		if !strings.HasPrefix(out, "PolicyError|") || !strings.Contains(out, "shell() in automations is not allowed by your organization") {
			t.Fatalf("dry=%v: script returned %#v; want a PolicyError", dry, r.out)
		}
		if n := len(sh.Calls()); n != 0 {
			t.Fatalf("dry=%v: shell calls = %d; want 0", dry, n)
		}
	}

	policytest.Set(t, nil)
	sh := realShell()
	r := runShell(t, `return shell("pwd").exit_code`, shellCase{perms: []string{`shell:"pwd"`}, shell: sh, wb: folderWB(shellFolder(t))})
	if fmt.Sprint(r.out) != "0" {
		t.Fatalf("no profile: script returned %#v; want exit 0", r.out)
	}
}

func TestCheckManifestPolicy(t *testing.T) {
	wb := automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 7}
	m, err := automations.ParseManifest([]string{`shell:"make test"`, "mcp:acme/*", "mcp:gone/*"}, nil, wb)
	if err != nil {
		t.Fatal(err)
	}
	lookup := func(name string) (string, string, string, bool) {
		if name == "acme" {
			return "http", "https://other.example.com/mcp", "", true
		}
		return "", "", "", false
	}
	blockOf := func(err error) string {
		var b *automations.PolicyBlock
		if errors.As(err, &b) {
			if !errors.Is(err, policy.ErrNotAllowed) {
				t.Fatalf("%v does not wrap policy.ErrNotAllowed", err)
			}
			return b.Kind
		}
		if err != nil {
			t.Fatalf("unexpected error %v", err)
		}
		return ""
	}

	policytest.Set(t, nil)
	if got := blockOf(automations.CheckManifestPolicy(m, lookup)); got != "" {
		t.Fatalf("no profile: blocked %q", got)
	}
	policytest.Set(t, map[string]any{"AllowAutomationShell": false})
	if got := blockOf(automations.CheckManifestPolicy(m, nil)); got != automations.PolicyBlockShell {
		t.Fatalf("shell off: blocked %q", got)
	}
	policytest.Set(t, map[string]any{"AllowedQuickConnections": []any{"https://mcp.example.com"}})
	if got := blockOf(automations.CheckManifestPolicy(m, lookup)); got != automations.PolicyBlockMCP {
		t.Fatalf("acme outside the list: blocked %q", got)
	}
	if got := blockOf(automations.CheckManifestPolicy(m, nil)); got != "" {
		t.Fatalf("no lookup: blocked %q", got)
	}
}

// TestAutomation_PolicyErrorNeverAutoDisables: runs that fail on the policy
// — an mcp(), an agent() or a shell() refusal — end failed with its message
// and never disable the automation.
func TestAutomation_PolicyErrorNeverAutoDisables(t *testing.T) {
	refusal := fmt.Errorf("policy: Quick Connection acme is %w (allowed: none)", policy.ErrNotAllowed)
	addPerm := func(perm, script string) string {
		return strings.Replace(exRecipeText(script, ""), "  - tool:list_targets\n", "  - tool:list_targets\n  - "+perm+"\n", 1)
	}
	t.Run("mcp", func(t *testing.T) {
		f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
			b.MCP = &automationstest.FakeMCP{Err: refusal}
		}})
		assertPolicyFailsThrice(t, f, f.seedText(t, "policy-mcp", addPerm("mcp:acme/*", `mcp("acme", "get_item", {})`), false))
	})
	t.Run("agent", func(t *testing.T) {
		agentRefusal := fmt.Errorf("policy: AI provider codex is %w (allowed: claude)", policy.ErrNotAllowed)
		f := newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
			b.Agent = &automationstest.FakeAgent{Err: automations.PolicyError(agentRefusal)}
		}})
		assertPolicyFailsThrice(t, f, f.seedText(t, "policy-agent", addPerm("agent:run", `agent("summarize")`), false))
	})
	t.Run("shell", func(t *testing.T) {
		policytest.Set(t, map[string]any{"AllowAutomationShell": false})
		w := newWbE2E(t, automations.ShellResult{})
		text := "---\nname: Shell policy\ntrigger:\n  manual: true\npermissions:\n  - 'shell:\"pwd\"'\noutputs: [report]\n---\nRuns pwd.\n\n```js\nshell(\"pwd\")\n```\n"
		writeWorkbenchRecipe(t, w.folder, "policy-shell", text)
		rescanWorkbench(t, w.ix, w.wb, w.folder)
		a := workbenchRow(t, w.d, w.wb, "policy-shell")
		if a.ParseError != "" {
			t.Fatalf("does not parse: %s", a.ParseError)
		}
		if err := w.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
			t.Fatal(err)
		}
		if err := w.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
			t.Fatal(err)
		}
		assertPolicyFailsThrice(t, w.exFixture, workbenchRow(t, w.d, w.wb, "policy-shell"))
		if n := len(w.shell.Calls()); n != 0 {
			t.Fatalf("shell ran %d commands", n)
		}
	})
}

func assertPolicyFailsThrice(t *testing.T, f *exFixture, a db.Automation) {
	t.Helper()
	for range 3 {
		id := f.enqueue(t, a, "manual")
		f.step(t, 1)
		r := f.run(t, id)
		if r.Status != "failed" || !strings.Contains(r.Error, "PolicyError") {
			t.Fatalf("run = %s (%s); want failed with a PolicyError", r.Status, r.Error)
		}
	}
	got, err := f.d.GetAutomation(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Enabled || got.DisabledReason != "" {
		t.Fatalf("automation enabled=%v reason=%q; want still enabled", got.Enabled, got.DisabledReason)
	}
}
