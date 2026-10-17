package daemon

import (
	"go/ast"
	"go/parser"
	"go/token"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestDaemon_Run_SyncsCalendarsBeforeFirstCycle pins #740's startup order: a
// daemon started right after a calendar connect syncs the calendars before
// its first runSync, whose Slack sync on a fresh install takes minutes and
// runs ahead of the calendar phases. Pinned statically (the
// TestDaemon_RunSync_PollsReactionsBeforeAIPipelines precedent) because Run
// has no seam to observe phase order at run time.
func TestDaemon_Run_SyncsCalendarsBeforeFirstCycle(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)

	order := topLevelCallOrder(daemonFunc(t, file, "Run", true))
	firstCycle, ok := order["runSync"]
	require.True(t, ok, "Run must start with an immediate runSync")
	at, ok := order["startupCalendarSync"]
	require.True(t, ok, "Run must call startupCalendarSync before the first cycle")
	assert.Less(t, at, firstCycle, "startupCalendarSync must run before the first runSync")

	// startupCalendarSync runs both calendar phases.
	called := calledMethods(daemonFunc(t, file, "startupCalendarSync", true))
	for _, phase := range []string{"phaseCalendarSync", "phaseCalDAVSync"} {
		assert.True(t, called[phase], "startupCalendarSync must call %s", phase)
	}
}

// daemonFunc returns the named function (a method when method) of daemon.go.
func daemonFunc(t *testing.T, file *ast.File, name string, method bool) *ast.FuncDecl {
	t.Helper()
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == name && (fd.Recv != nil) == method {
			return fd
		}
	}
	t.Fatalf("%s not found in daemon.go", name)
	return nil
}

// topLevelCallOrder maps each method called as a top-level statement of fn
// to the index of its first such statement. Top-level only: Run's ticker
// loop's runSync calls sit inside the for statement and must not count as
// the first cycle.
func topLevelCallOrder(fn *ast.FuncDecl) map[string]int {
	order := map[string]int{}
	for i, stmt := range fn.Body.List {
		expr, ok := stmt.(*ast.ExprStmt)
		if !ok {
			continue
		}
		call, ok := expr.X.(*ast.CallExpr)
		if !ok {
			continue
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
			if _, seen := order[sel.Sel.Name]; !seen {
				order[sel.Sel.Name] = i
			}
		}
	}
	return order
}

// calledMethods is the set of methods fn calls anywhere in its body.
func calledMethods(fn *ast.FuncDecl) map[string]bool {
	called := map[string]bool{}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				called[sel.Sel.Name] = true
			}
		}
		return true
	})
	return called
}
