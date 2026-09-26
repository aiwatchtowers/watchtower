package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// parseGoFile parses one Go file with comments discarded.
//
// Parsed, not string-matched: a text search reads a commented-out call as
// present, which is exactly the "someone disabled it while debugging" case
// these call-site tests exist for. Walking one function's body also pins that
// the call lives in THAT function rather than anywhere in the file. Same shape
// as TestRunSyncDaemon_CallsTheJiraFeatureKeyMigration.
func parseGoFile(t *testing.T, path string) *ast.File {
	t.Helper()
	parsed, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	require.NoError(t, err)
	return parsed
}

// findFuncDecl returns the top-level function `name` declared in cmd/<file>.
func findFuncDecl(t *testing.T, file, name string) *ast.FuncDecl {
	t.Helper()
	for _, decl := range parseGoFile(t, file).Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if ok && fn.Name.Name == name {
			return fn
		}
	}
	t.Fatalf("%s must declare %s", file, name)
	return nil
}

// callsMethod reports whether body contains a `<receiver>.<method>(…)` call.
// An empty receiver matches any receiver expression.
func callsMethod(body ast.Node, receiver, method string) bool {
	found := false
	ast.Inspect(body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != method {
			return true
		}
		if receiver == "" {
			found = true
			return true
		}
		if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == receiver {
			found = true
		}
		return true
	})
	return found
}

// TestEveryOrchestratorConstructionWiresTheJiraKeyDetector is the guard against
// the defect this task removes, stated as the property rather than as a list of
// today's call sites: jira.NewKeyDetector and both SetJiraKeyDetector hooks
// shipped with ZERO production callers and stayed that way for the life of the
// feature, so jira_slack_links was never written once. A sync path that writes
// messages without the hook is that bug again, scoped to whatever that path
// syncs — and permanently, because such a path advances search_last_date and
// sync_state, so the daemon never revisits those messages and this wave is
// forward-only with no backfill.
//
// Written as "every function that constructs a sync.Orchestrator also wires the
// detector" rather than as a fixed table, because the review of the first
// attempt found a fourth construction site (internal/repl's /sync, reached by a
// bare `watchtower` — the default command) that a fixed table had no way to
// notice. A fifth one now fails this test the day it is written.
func TestEveryOrchestratorConstructionWiresTheJiraKeyDetector(t *testing.T) {
	sites := orchestratorConstructionSites(t)
	require.NotEmpty(t, sites, "the scan must find the known construction sites")

	for path, fns := range sites {
		for _, fn := range fns {
			assert.True(t, callsMethod(fn.Body, "", "SetJiraKeyDetector"),
				"%s: %s constructs a sync.Orchestrator but never calls SetJiraKeyDetector — "+
					"every Jira key in the messages it syncs is lost permanently", path, fn.Name.Name)
		}
	}
}

// TestOrchestratorConstructionSitesAreTheKnownOnes fails when a construction
// site appears or disappears, so the scan above cannot quietly stop covering
// anything (an over-narrow scan would pass vacuously).
func TestOrchestratorConstructionSitesAreTheKnownOnes(t *testing.T) {
	var got []string
	for path, fns := range orchestratorConstructionSites(t) {
		for _, fn := range fns {
			got = append(got, filepath.ToSlash(path)+":"+fn.Name.Name)
		}
	}
	assert.ElementsMatch(t, []string{
		"../cmd/sync.go:wireSlackSyncers",
		"../internal/repl/commands.go:runSyncCommand",
	}, got)
}

// orchestratorConstructionSites walks the repository's non-test Go files and
// returns, per file, every function whose body calls sync.NewOrchestrator.
func orchestratorConstructionSites(t *testing.T) map[string][]*ast.FuncDecl {
	t.Helper()
	sites := map[string][]*ast.FuncDecl{}

	skipDirs := map[string]bool{".git": true, ".build": true, "WatchtowerDesktop": true, ".claude": true}
	err := filepath.WalkDir("..", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if skipDirs[d.Name()] {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		for _, decl := range parseGoFile(t, path).Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if ok && callsMethod(fn.Body, "sync", "NewOrchestrator") {
				sites[path] = append(sites[path], fn)
			}
		}
		return nil
	})
	require.NoError(t, err)
	return sites
}

// The two pipeline hooks have no orchestrator to hang off, so they are pinned
// by name. Without them a digest decision and an extracted track never link to
// the Jira issue they name.
func TestJiraKeyDetectorIsWiredIntoBothPipelines(t *testing.T) {
	sites := []struct {
		fn       string
		receiver string
		why      string
	}{
		{"runSyncDaemon", "pipe", "digest decisions are linked only from the daemon's digest pipeline"},
		{"runSyncDaemon", "tracksPipe", "extracted tracks are linked only from the daemon's tracks pipeline"},
		{"runPostSyncPipelines", "pipe", "the one-shot `watchtower sync` path must not be a silent asymmetry"},
		{"runPostSyncPipelines", "tracksPipe", "the one-shot `watchtower sync` path must not be a silent asymmetry"},
	}

	for _, site := range sites {
		fn := findFuncDecl(t, "sync.go", site.fn)
		assert.True(t, callsMethod(fn.Body, site.receiver, "SetJiraKeyDetector"),
			"%s must call %s.SetJiraKeyDetector — %s", site.fn, site.receiver, site.why)
	}
}
