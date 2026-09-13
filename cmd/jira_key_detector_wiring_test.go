package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// findFuncDecl returns the top-level function `name` declared in cmd/<file>.
//
// Parsed with comments discarded, not string-matched: a text search reads a
// commented-out call as present, which is exactly the "someone disabled it
// while debugging" case these call-site tests exist for. Walking one function's
// body also pins that the call lives in THAT function rather than anywhere in
// the file. Same shape as TestRunSyncDaemon_CallsTheJiraFeatureKeyMigration.
func findFuncDecl(t *testing.T, file, name string) *ast.FuncDecl {
	t.Helper()
	parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	require.NoError(t, err)

	for _, decl := range parsed.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if ok && fn.Name.Name == name {
			return fn
		}
	}
	t.Fatalf("%s must declare %s", file, name)
	return nil
}

// callsMethod reports whether fn's body contains a `<receiver>.<method>(…)`
// call.
func callsMethod(fn *ast.FuncDecl, receiver, method string) bool {
	found := false
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel.Name != method {
			return true
		}
		if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == receiver {
			found = true
		}
		return true
	})
	return found
}

// TestJiraKeyDetectorIsWiredAtEveryCallSite is the guard against the defect
// this whole task removes: jira.NewKeyDetector and both SetJiraKeyDetector
// hooks shipped with ZERO production callers and stayed that way for the life
// of the feature, so jira_slack_links was never written once and every reader
// of it — the --jira/--no-jira track filter, the Desktop "Linked Jira Issues"
// badges, get_task_context, find_experts, who-to-ping, DetectChannelsWithoutJira
// — silently returned nothing. Nothing else fails if these calls disappear
// again: the pipelines and the sync run perfectly well with a nil hook.
func TestJiraKeyDetectorIsWiredAtEveryCallSite(t *testing.T) {
	sites := []struct {
		fn       string
		receiver string
		why      string
	}{
		{"runSyncDaemon", "pipe", "digest decisions are linked only from the daemon's digest pipeline"},
		{"runSyncDaemon", "tracksPipe", "extracted tracks are linked only from the daemon's tracks pipeline"},
		{"runPostSyncPipelines", "pipe", "the one-shot `watchtower sync` path must not be a silent asymmetry"},
		{"runPostSyncPipelines", "tracksPipe", "the one-shot `watchtower sync` path must not be a silent asymmetry"},
		{"wireSlackSyncers", "orch", "per-message mention links are the only kind the flagship readers can use"},
	}

	for _, site := range sites {
		fn := findFuncDecl(t, "sync.go", site.fn)
		assert.True(t, callsMethod(fn, site.receiver, "SetJiraKeyDetector"),
			"%s must call %s.SetJiraKeyDetector — %s", site.fn, site.receiver, site.why)
	}
}

// The gate is cfg.Jira.Enabled and nothing else: `jira add`/`jira login` flip
// it true, so it is on for exactly the installs that have a Jira site — and
// off is the pre-wiring behaviour exactly, with no detector constructed and no
// key set ever loaded.
func TestNewJiraKeyDetector_GatedOnJiraEnabled(t *testing.T) {
	database := db.OpenTestDB(t)

	assert.Nil(t, newJiraKeyDetector(&config.Config{}, database),
		"an install without Jira must get no detector")

	cfg := &config.Config{Jira: config.JiraConfig{Enabled: true}}
	assert.NotNil(t, newJiraKeyDetector(cfg, database),
		"an install with Jira connected must get a detector")
}
