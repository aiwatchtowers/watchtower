package transporttest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/agentkind"
	"watchtower/internal/policy"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/sessionagent"
)

// The harness completeness guards (LLMTRANSPORT-01, owner-approved scope
// extension 2026-11-08, board #1034): the executable form of
// docs/features/adding-a-harness.md. A harness is a registered session
// agent kind (agentkind's registry) or a registered LLM provider (the
// provider registry). Each guard names the harness and exactly what it
// lacks, in both directions: a registered harness with a missing piece,
// and a suite row or fixture row of no registered harness.

// harnessProblems collects "harness X: …" lines and reports them sorted.
type harnessProblems []string

func (p *harnessProblems) add(harness, format string, args ...any) {
	*p = append(*p, fmt.Sprintf("harness %s: ", harness)+fmt.Sprintf(format, args...))
}

func (p harnessProblems) report(t *testing.T) {
	t.Helper()
	slices.Sort(p)
	for _, line := range p {
		t.Error(line)
	}
}

// fixtureAgents reads a fixture's "agents" object.
func fixtureAgents(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Agents map[string]json.RawMessage `json:"agents"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return fx.Agents
}

var (
	capsFixture      = filepath.Join("..", "sessionagent", "agent_capabilities.json")
	kitCapsFixture   = filepath.Join("..", "..", "WatchtowerKit", "Sources", "WatchtowerKit", "Resources", "agent_capabilities.json")
	phoneCapsFixture = filepath.Join("..", "..", "WatchtowerKit", "Tests", "Fixtures", "workbench", "phone_caps.json")
	schemaFile       = filepath.Join("..", "db", "schema.sql")
)

var (
	terminalSessionsTable = regexp.MustCompile(`(?s)CREATE TABLE IF NOT EXISTS terminal_sessions \((.*?)\n\);`)
	kindCheck             = regexp.MustCompile(`\bkind\s+TEXT NOT NULL CHECK\s*\(\s*kind IN \(([^)]*)\)\s*\)`)
)

// schemaAgentKinds is the agent kinds terminal_sessions.kind's CHECK admits
// in schema.sql (every value but shell).
func schemaAgentKinds(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(schemaFile)
	if err != nil {
		t.Fatal(err)
	}
	table := terminalSessionsTable.FindSubmatch(raw)
	if table == nil {
		t.Fatalf("%s: no terminal_sessions table", schemaFile)
	}
	check := kindCheck.FindSubmatch(table[1])
	if check == nil {
		t.Fatalf("%s: terminal_sessions has no kind CHECK", schemaFile)
	}
	var out []string
	for v := range strings.SplitSeq(string(check[1]), ",") {
		if v = strings.Trim(strings.TrimSpace(v), "'"); v != "shell" {
			out = append(out, v)
		}
	}
	return out
}

// suiteSession is the suite row of agent kind k with a session level.
func suiteSession(k string) *Adapter {
	for _, a := range adapters {
		if a.Name == k && a.Session != nil {
			return a
		}
	}
	return nil
}

// TestLLMTRANSPORT01_SessionHarnessComplete: every registered session
// agent kind has every piece docs/features/adding-a-harness.md lists, and
// every suite session row, fixture row and schema CHECK value is a
// registered kind.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_SessionHarnessComplete(t *testing.T) {
	var p harnessProblems
	golden := readGolden(t)
	caps := fixtureAgents(t, capsFixture)
	phone := fixtureAgents(t, phoneCapsFixture)
	goCaps, err := os.ReadFile(capsFixture)
	if err != nil {
		t.Fatal(err)
	}
	kitCaps, err := os.ReadFile(kitCapsFixture)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(goCaps, kitCaps) {
		t.Errorf("%s is not a byte-for-byte copy of %s: copy it", kitCapsFixture, capsFixture)
	}
	schema := schemaAgentKinds(t)
	registered := agentkind.Names()

	for _, d := range agentkind.Registry() {
		k := string(d.Kind)
		if d.Label == "" || d.DisplayName == "" {
			p.add(k, "agentkind's registry entry needs a label and a display name")
		}
		if !slices.Contains(providers.IDs(), k) {
			p.add(k, "no provider of the same id (the agent kinds are their providers: policy and workbench.default_agent)")
		}
		if _, ok := caps[k]; !ok {
			p.add(k, "no row in %s", capsFixture)
		}
		if _, ok := phone[k]; !ok {
			p.add(k, "no row in %s", phoneCapsFixture)
		}
		if !slices.Contains(schema, k) {
			p.add(k, "not in terminal_sessions.kind's CHECK in %s (a migration rebuilds the table)", schemaFile)
		}
		a, ok := sessionagent.For(d.Kind)
		if !ok {
			p.add(k, "no session adapter (sessionagent's adapterList)")
			continue
		}
		checkAdapterPieces(&p, k, a)
		sa := suiteSession(k)
		if sa == nil {
			p.add(k, "no suite session row (transporttest adapters, Session)")
			continue
		}
		checkSessionCells(&p, k, a, golden)
		checkInstalledHooks(t, &p, k, a, sa)
	}

	// The other direction: nothing names a kind the registry lacks.
	for _, a := range adapters {
		if a.Session != nil && !slices.Contains(registered, a.Name) {
			p.add(a.Name, "suite session row of no registered agent kind (agentkind's registry)")
		}
	}
	for _, rows := range []struct {
		where string
		names []string
	}{
		{capsFixture, keys(caps)},
		{phoneCapsFixture, keys(phone)},
		{"terminal_sessions.kind's CHECK in " + schemaFile, schema},
	} {
		for _, name := range rows.names {
			if !slices.Contains(registered, name) {
				p.add(name, "listed in %s but no registered agent kind", rows.where)
			}
		}
	}
	p.report(t)
}

func keys(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// checkAdapterPieces checks what an adapter must answer for a start, the
// phone and the hooks.
func checkAdapterPieces(p *harnessProblems, k string, a sessionagent.Adapter) {
	if a.LaunchCommand(sessionagent.Start{}).Command == "" {
		p.add(k, "no launch command (Adapter.LaunchCommand)")
	}
	if a.NotFoundReason() == "" || a.NotFoundMessage() == "" {
		p.add(k, "no not-found reason and message (Adapter.NotFoundReason, NotFoundMessage)")
	}
	if a.WireAgent() == "" {
		p.add(k, "no phone wire value (Adapter.WireAgent)")
	}
	if _, pulls := a.Watch(); len(a.HookSpecs()) == 0 && !pulls {
		p.add(k, "no hook specs and no pull-only signal (Adapter.HookSpecs or Adapter.Watch)")
	}
}

// checkSessionCells checks the golden resolves every session scenario for
// kind k, and that analytics: true has an importer that passes.
func checkSessionCells(p *harnessProblems, k string, a sessionagent.Adapter, golden map[string]string) {
	for _, s := range sessionScenarios {
		key := k + "/" + string(LevelSession) + " " + s.Name
		if _, ok := golden[key]; !ok {
			p.add(k, "no suite row for scenario %s (run go test ./internal/transporttest -update)", s.Name)
		}
	}
	analytics := k + "/" + string(LevelSession) + " session-analytics"
	if a.Caps().Analytics && golden[analytics] != "pass" {
		p.add(k, "analytics: true, but session-analytics is %q: add the importer (Adapter.Transcript) or declare analytics: false", golden[analytics])
	}
}

// checkInstalledHooks checks devpack installs every hook spec of the
// adapter.
func checkInstalledHooks(t *testing.T, p *harnessProblems, k string, a sessionagent.Adapter, sa *Adapter) {
	if sa.Session.installed == nil {
		p.add(k, "the suite session row has no installed hook reader (sessionAgent.installed)")
		return
	}
	installed := sa.Session.installed(t, t.TempDir(), 1)
	for _, h := range a.HookSpecs() {
		if !slices.ContainsFunc(installed[h.Event], func(c string) bool { return strings.Contains(c, h.Subcommand) }) {
			p.add(k, "devpack does not install hook spec %s %q", h.Event, h.Subcommand)
		}
	}
}

// llmScenarioLevels is every (scenario, level) pair an LLM provider's suite
// rows must cover.
func llmScenarioLevels() (out [][2]string) {
	for _, s := range scenarios {
		for _, l := range s.Levels {
			if l != LevelSession {
				out = append(out, [2]string{s.Name, string(l)})
			}
		}
	}
	return out
}

// TestLLMTRANSPORT01_LLMHarnessComplete: every registered LLM provider has
// a capability row, the factory's constructors, an organization-policy
// value, suite rows covering every LLM scenario at every level, and a
// failure classifier the fail-* cells prove; every suite row runs as a
// registered provider.
// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
func TestLLMTRANSPORT01_LLMHarnessComplete(t *testing.T) {
	var p harnessProblems
	golden := readGolden(t)
	if err := transport.CheckConstructors(); err != nil {
		t.Error(err)
	}
	pairs := llmScenarioLevels()
	for _, id := range providers.IDs() {
		if _, ok := providers.CapsFor(id); !ok {
			p.add(id, "no capability row (internal/providers/caps)")
		}
		if !policy.Normalize(map[string]any{policy.KeyAllowedAIProviders: []any{id}}).ProviderAllowed(id) {
			p.add(id, "the organization policy's AllowedAIProviders does not know it (internal/policy, policy_cases.json)")
		}
		var rows []*Adapter
		for _, a := range adapters {
			if a.Provider == id {
				rows = append(rows, a)
			}
		}
		if len(rows) == 0 {
			p.add(id, "no suite LLM row (transporttest adapters)")
			continue
		}
		for _, pair := range pairs {
			covered := false
			for _, a := range rows {
				if _, ok := golden[a.Name+"/"+pair[1]+" "+pair[0]]; ok {
					covered = true
				}
			}
			if !covered {
				p.add(id, "no suite row for scenario %s at level %s", pair[0], pair[1])
			}
		}
		checkFailureCells(&p, id, rows, golden)
	}
	for _, a := range adapters {
		if !slices.Contains(providers.IDs(), a.Provider) {
			p.add(a.Name, "suite row runs as %q, which is no registered provider", a.Provider)
		}
	}
	p.report(t)
}

// checkFailureCells: the provider's failure classifier types every fail-*
// fixture (the cells assert the category and chat.CodeForFailure's code), so
// each of its fail-* cells passes or is unsupported, never an open gap.
func checkFailureCells(p *harnessProblems, id string, rows []*Adapter, golden map[string]string) {
	passed := false
	for _, a := range rows {
		for _, l := range a.levels() {
			for _, s := range scenarios {
				if !strings.HasPrefix(s.Name, "fail-") || !slices.Contains(s.Levels, l) {
					continue
				}
				switch got := golden[cellKey(a, l, s)]; got {
				case "pass":
					passed = true
				case "unsupported":
				default:
					p.add(id, "failure classifier: %s is %q, not pass", cellKey(a, l, s), got)
				}
			}
		}
	}
	if !passed {
		p.add(id, "failure classifier: no fail-* cell passes")
	}
}
