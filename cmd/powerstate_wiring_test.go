package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// funcExprs returns the source text of every call and key-value expression
// in the body of function name in file (go/types.ExprString, so spacing does
// not matter).
func funcExprs(t *testing.T, file, name string) map[string]bool {
	t.Helper()
	f, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	require.NoError(t, err)
	var body *ast.BlockStmt
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == name {
			body = fn.Body
		}
	}
	require.NotNil(t, body, "%s not found in %s", name, file)
	exprs := map[string]bool{}
	ast.Inspect(body, func(n ast.Node) bool {
		switch e := n.(type) {
		case *ast.CallExpr:
			exprs[types.ExprString(e)] = true
		case *ast.KeyValueExpr:
			exprs[types.ExprString(e.Key)+": "+types.ExprString(e.Value)] = true
		}
		return true
	})
	return exprs
}

// TestPowerstate_DarkWakeGateWired guards the #880 dark wake gate's
// production wiring: main installs the IOKit reader (a test binary never
// does), the sync daemon hands runLoop the probe, and the daemon's
// automations scheduler and executor get it too. Without any of them the
// gate silently reads "always awake" — no test of the gated packages fails —
// so this scans the sources.
func TestPowerstate_DarkWakeGateWired(t *testing.T) {
	mainCalls := funcExprs(t, filepath.Join("..", "main.go"), "main")
	assert.True(t, mainCalls["powerstate.UseSystemReader()"], "main must call powerstate.UseSystemReader()")

	sync := funcExprs(t, "sync.go", "runSyncDaemon")
	assert.True(t, sync["d.SetFullWakeProbe(powerstate.Probe)"], "runSyncDaemon must call d.SetFullWakeProbe(powerstate.Probe)")

	auto := funcExprs(t, "automations_daemon.go", "newDaemonAutomations")
	assert.True(t, auto["FullWake: powerstate.Probe"], "newDaemonAutomations must set ExecutorOptions.FullWake: powerstate.Probe")
	assert.True(t, auto["sched.SetFullWakeProbe(powerstate.Probe)"], "newDaemonAutomations must call sched.SetFullWakeProbe(powerstate.Probe)")
}
