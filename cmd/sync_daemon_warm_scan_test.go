package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestRunSyncDaemon_KeepsConnectionWarm guards the daemon's opt-out from the
// 30 s idle close (board #603): runSyncDaemon calls
// database.KeepConnectionWarm() on its watchtower.db handle, so the one
// connection keeps the page cache every cycle reads through. The call has no
// observable effect a daemon test could check cheaply, so this scans
// sync.go's source.
func TestRunSyncDaemon_KeepsConnectionWarm(t *testing.T) {
	f, err := parser.ParseFile(token.NewFileSet(), "sync.go", nil, 0)
	require.NoError(t, err)

	var body *ast.BlockStmt
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == "runSyncDaemon" {
			body = fn.Body
		}
	}
	require.NotNil(t, body, "runSyncDaemon not found in sync.go")

	found := false
	for _, st := range body.List {
		es, ok := st.(*ast.ExprStmt)
		if !ok {
			continue
		}
		call, ok := es.X.(*ast.CallExpr)
		if !ok {
			continue
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			continue
		}
		if id, ok := sel.X.(*ast.Ident); ok && id.Name == "database" && sel.Sel.Name == "KeepConnectionWarm" {
			found = true
		}
	}
	require.True(t, found, "runSyncDaemon must call database.KeepConnectionWarm() in its top-level body")
}
