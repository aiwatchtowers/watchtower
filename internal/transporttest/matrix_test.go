package transporttest

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/digest"
	"watchtower/internal/ollama"
)

var update = flag.Bool("update", false, "rewrite testdata/matrix.golden from today's results")

const goldenPath = "testdata/matrix.golden"

// openGaps are the open parity gaps of the spec's §2.2. Closed: L2 (#957),
// L12 (G1b), L1 (G1), L7-L10 (G3), S7-S8 (G6), S3-S5 and S10 (G7). L13 was
// found by this suite, as L12 was. A gap:<id> cell must name one of them.
var openGaps = map[string]bool{
	"L3": true, "L4": true, "L5": true, "L6": true, "L11": true, "L13": true,
	"S1": true, "S2": true, "S6": true, "S9": true,
}

// cellKey names a cell in the golden: "<adapter>/<level> <scenario>".
func cellKey(a *Adapter, level Level, s *Scenario) string {
	return a.Name + "/" + string(level) + " " + s.Name
}

type cellRef struct {
	a     *Adapter
	level Level
	s     *Scenario
}

// allCells is every adapter × level × scenario pair the table defines.
func allCells() []cellRef {
	var out []cellRef
	for _, a := range adapters {
		for _, level := range a.levels() {
			for _, s := range scenarios {
				if slices.Contains(s.Levels, level) {
					out = append(out, cellRef{a, level, s})
				}
			}
		}
	}
	return out
}

func supported(a *Adapter, s *Scenario) bool {
	for _, c := range s.Requires {
		if !a.Caps.Has(c) {
			return false
		}
	}
	return true
}

func readGolden(t *testing.T) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(goldenPath)
	if err != nil {
		if *update {
			return map[string]string{}
		}
		t.Fatalf("reading %s: %v (run with -update)", goldenPath, err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 3 {
			t.Fatalf("golden line %q: want `adapter scenario result`", line)
		}
		out[f[0]+" "+f[1]] = f[2]
	}
	return out
}

const goldenHeader = `# The transport contract suite's resolved matrix (internal/transporttest).
# One line per cell: <adapter>/<level> <scenario> pass|unsupported|gap:<id>.
# gap:<id> names an open gap of the spec's §2.2: the cell fails today and the
# gap's task flips it. Regenerate with: go test ./internal/transporttest -update
`

func writeGolden(t *testing.T, results map[string]string) {
	t.Helper()
	var b strings.Builder
	b.WriteString(goldenHeader)
	for _, k := range slices.Sorted(maps.Keys(results)) {
		fmt.Fprintf(&b, "%s %s\n", k, results[k])
	}
	if err := os.WriteFile(goldenPath, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestTransportSuite runs every cell and compares it with the golden. A
// pass or unsupported cell must hold; a gap cell must still fail (its task
// flips it to pass when the gap closes). -update records today's results,
// keeping a still-failing cell's gap id and writing gap:? for a new one.
func TestTransportSuite(t *testing.T) {
	golden := readGolden(t)
	var mu sync.Mutex
	results := map[string]string{}
	// One group so the parallel session cells end before -update writes.
	t.Run("cells", func(t *testing.T) {
		for _, ref := range allCells() {
			runMatrixCell(t, ref, golden, &mu, results)
		}
	})
	if *update {
		// A filtered run (-run) updates its own cells and keeps the rest;
		// a line whose cell no longer exists goes.
		merged := map[string]string{}
		for _, ref := range allCells() {
			key := cellKey(ref.a, ref.level, ref.s)
			if r, ok := results[key]; ok {
				merged[key] = r
			} else if g, ok := golden[key]; ok {
				merged[key] = g
			}
		}
		writeGolden(t, merged)
	}
}

// gapSignatures is how each open gap fails today: a gap cell must fail
// this way, so a harness fault (a fake that rejected its input, a fixture
// typo, a hook that did not run) never passes as the gap. A gap's task
// flips its cells to pass; a fix that only changes the failure updates the
// signature.
var gapSignatures = map[string]*regexp.Regexp{
	"L3":  regexp.MustCompile(`a response past the cap ran|no turn cap in force`),
	"L5":  regexp.MustCompile(`web search`),
	"L6":  regexp.MustCompile(`images and PDFs need the Claude provider`),
	"L13": regexp.MustCompile(`without a budget failure`),
	"S1":  regexp.MustCompile(`no pull signal`),
	"S2":  regexp.MustCompile(`no pull signal`),
}

// runMatrixCell runs one cell as a subtest and checks it against the
// golden. Session cells run in parallel (each has its own HOME); the LLM
// cells share the process environment and the ledger, so they run one at a
// time.
func runMatrixCell(t *testing.T, ref cellRef, golden map[string]string, mu *sync.Mutex, results map[string]string) {
	key := cellKey(ref.a, ref.level, ref.s)
	t.Run(strings.ReplaceAll(key, " ", "/"), func(t *testing.T) {
		if ref.level == LevelSession {
			t.Parallel()
		}
		sup := supported(ref.a, ref.s)
		path, found := fixturePath(t, ref.a, ref.s, ref.level)
		if sup && ref.level != LevelSession && !found {
			t.Fatalf("no fixture for %s", key)
		}
		o := runCell(t, ref.a, ref.s, ref.level)
		cell := &Cell{A: ref.a, S: ref.s, Level: ref.level, Supported: sup, O: o, fixture: readFixture(t, path)}
		err := ref.s.Assert(cell)
		if len(o.FakeErrors) > 0 {
			// The fake rejected its input (argv, stdin, a directive): a
			// harness or adapter fault, never a pass and never a gap.
			t.Errorf("%s: the fake rejected its input: %s (assertion: %v)", key, strings.Join(o.FakeErrors, "; "), err)
			mu.Lock()
			results[key] = "gap:?"
			mu.Unlock()
			return
		}
		want := golden[key]
		got := "pass"
		if !sup {
			got = "unsupported"
		}
		if err != nil {
			got = "gap:?"
			if id, ok := strings.CutPrefix(want, "gap:"); ok && gapSignatures[id] != nil && gapSignatures[id].MatchString(err.Error()) {
				got = want
			}
		}
		mu.Lock()
		results[key] = got
		mu.Unlock()
		if *update {
			if err != nil {
				t.Logf("%s fails: %v", key, err)
			}
			return
		}
		switch {
		case want == "":
			t.Errorf("%s is not in the golden (run with -update)", key)
		case strings.HasPrefix(want, "gap:") && err == nil:
			t.Errorf("%s now holds: flip %s to %s in the golden", key, want, got)
		case strings.HasPrefix(want, "gap:") && got != want:
			t.Errorf("%s fails, but not the way %s does: %v", key, want, err)
		case !strings.HasPrefix(want, "gap:") && err != nil:
			t.Errorf("%s (%s) fails: %v", key, want, err)
		case !strings.HasPrefix(want, "gap:") && want != got:
			t.Errorf("%s is %s, golden says %s", key, got, want)
		}
	})
}

// TestTransportSuite_EveryCellResolved checks the golden names every cell
// the table defines, no other, each with a valid result: unsupported
// exactly where the adapter lacks a required capability, and every gap an
// open gap of the spec's §2.2.
func TestTransportSuite_EveryCellResolved(t *testing.T) {
	golden := readGolden(t)
	seen := map[string]bool{}
	for _, ref := range allCells() {
		key := cellKey(ref.a, ref.level, ref.s)
		seen[key] = true
		got, ok := golden[key]
		if !ok {
			t.Errorf("%s has no golden line", key)
			continue
		}
		switch {
		case got == "pass" || got == "unsupported":
			if want := supported(ref.a, ref.s); want != (got == "pass") {
				t.Errorf("%s is %s but the adapter's capabilities say supported=%v", key, got, want)
			}
		case strings.HasPrefix(got, "gap:"):
			if id := strings.TrimPrefix(got, "gap:"); !openGaps[id] {
				t.Errorf("%s names %q, not an open gap of the spec's §2.2", key, got)
			} else if gapSignatures[id] == nil {
				t.Errorf("%s names %s, which has no failure signature", key, got)
			}
		default:
			t.Errorf("%s has result %q", key, got)
		}
	}
	for key := range golden {
		if !seen[key] {
			t.Errorf("golden line %q names no cell", key)
		}
	}
}

// TestTransportSuite_NoSkip forbids t.Skip in the package (spec §4.3): a
// missing capability is asserted as unsupported, never skipped. skipLive,
// the live gate, is the one exception.
func TestTransportSuite_NoSkip(t *testing.T) {
	fset := token.NewFileSet()
	var files []string
	for _, pattern := range []string{"*.go", "fakecli/*.go"} {
		m, err := filepath.Glob(pattern)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, m...)
	}
	if len(files) == 0 {
		t.Fatal("no files scanned")
	}
	for _, path := range files {
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name.Name == "skipLive" {
				continue
			}
			ast.Inspect(fn, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && strings.HasPrefix(sel.Sel.Name, "Skip") {
					t.Errorf("%s: %s skips a test; assert unsupported instead", fset.Position(call.Pos()), sel.Sel.Name)
				}
				return true
			})
		}
	}
}

// TestTransportSuite_Live is the one opt-in live job (spec §4.2): the plain
// answer against the real CLIs and server, which catches drift of the
// recorded formats. WATCHTOWER_LIVE_CLAUDE / _CODEX / _OLLAMA turn each on
// (OLLAMA_URL, OLLAMA_MODEL; CODEX_BIN for a codex outside PATH,
// CODEX_MODEL for another model).
func TestTransportSuite_Live(t *testing.T) {
	plain := scenarioNamed(t, "plain-answer")
	cases := []struct {
		env  string
		name string
		gen  func() digest.Generator
	}{
		{"WATCHTOWER_LIVE_CLAUDE", "claude",
			func() digest.Generator { return digest.NewClaudeGenerator("haiku", "haiku", "") }},
		{"WATCHTOWER_LIVE_CODEX", "codex",
			func() digest.Generator {
				model := cmp.Or(os.Getenv("CODEX_MODEL"), "gpt-6.1-sol")
				return codex.NewCodexGenerator(model, model, os.Getenv("CODEX_BIN"))
			}},
		{"WATCHTOWER_LIVE_OLLAMA", "ollama",
			func() digest.Generator {
				return ollama.NewGenerator(os.Getenv("OLLAMA_MODEL"), os.Getenv("OLLAMA_MODEL"), os.Getenv("OLLAMA_URL"))
			}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			skipLive(t, tc.env)
			t.Setenv("HOME", realHome)
			t.Setenv("CODEX_HOME", realCodexHome)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			ledger.take()
			o := &Outcome{}
			o.Text, o.Usage, _, o.Err = tc.gen().Generate(ctx, sysPrompt, userPrompt, "")
			o.Calls = ledger.take()
			c := &Cell{S: plain, Level: LevelBatch, Supported: true, O: o}
			if err := plain.Assert(c); err != nil {
				t.Errorf("live %s: %v", tc.name, err)
			}
		})
	}
}

func scenarioNamed(t *testing.T, name string) *Scenario {
	t.Helper()
	for _, s := range scenarios {
		if s.Name == name {
			return s
		}
	}
	t.Fatalf("no scenario %q", name)
	return nil
}
