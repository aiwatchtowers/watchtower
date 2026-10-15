package cmd

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// The daemon's runners index the personal folder <WorkspaceDir>/automations
// (spec §20 D8) and the executor leaves an unconfirmed recipe alone.
func TestNewDaemonAutomations_IndexesPersonalFolder(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "acme", Automations: config.AutomationsConfig{Enabled: true}}
	dir := automations.PersonalDir(cfg.WorkspaceDir())
	require.NoError(t, os.MkdirAll(dir, 0o755))
	recipe := "---\nname: Morning note\ntrigger:\n  schedule: \"0 9 * * 1-5\"\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n\n```js\noutput.inbox({ title: \"Hi\", body: llm(\"Say hi\") });\n```\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "morning-note.md"), []byte(recipe), 0o644))

	database := db.OpenTestDB(t)
	gen := &automationstest.FakeGenerator{}
	sched, exec := newDaemonAutomations(cfg, database, gen, log.New(io.Discard, "", 0))

	require.NoError(t, sched.Tick(context.Background(), time.Now()))
	list, err := database.ListAutomations(db.AutomationFilter{})
	require.NoError(t, err)
	require.Len(t, list, 1)
	assert.Equal(t, "morning-note", list[0].Slug)
	assert.False(t, list[0].Runnable(), "a new recipe waits for the owner's confirmation")

	started, err := exec.Step(context.Background())
	require.NoError(t, err)
	assert.Zero(t, started)
	assert.Zero(t, gen.CallCount())
}

// TestRunSyncDaemon_WiresAutomations pins the one call that gives the daemon
// its scheduler and executor (the TestRunSyncDaemon_CallsTheJiraFeatureKeyMigration
// precedent: runSyncDaemon cannot run in a test, so its body is parsed with
// comments discarded — a commented-out call reads as missing).
func TestRunSyncDaemon_WiresAutomations(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "sync.go", nil, 0)
	require.NoError(t, err)
	var called bool
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv != nil || fn.Name.Name != "runSyncDaemon" {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "wireAutomations" {
					called = true
				}
			}
			return true
		})
	}
	assert.True(t, called, "runSyncDaemon must call wireAutomations")
}
