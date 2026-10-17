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

	var run *ast.FuncDecl
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "Run" && fd.Recv != nil {
			run = fd
		}
	}
	require.NotNil(t, run, "Daemon.Run not found in daemon.go")

	// Top-level statements only: the ticker loop's runSync calls sit inside
	// the for statement and must not count as the first cycle.
	order := map[string]int{}
	for i, stmt := range run.Body.List {
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
	firstCycle, ok := order["runSync"]
	require.True(t, ok, "Run must start with an immediate runSync")
	at, ok := order["startupCalendarSync"]
	require.True(t, ok, "Run must call startupCalendarSync before the first cycle")
	assert.Less(t, at, firstCycle, "startupCalendarSync must run before the first runSync")

	// startupCalendarSync runs both calendar phases.
	var startup *ast.FuncDecl
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "startupCalendarSync" {
			startup = fd
		}
	}
	require.NotNil(t, startup, "startupCalendarSync not found in daemon.go")
	called := map[string]bool{}
	ast.Inspect(startup.Body, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				called[sel.Sel.Name] = true
			}
		}
		return true
	})
	for _, phase := range []string{"phaseCalendarSync", "phaseCalDAVSync"} {
		assert.True(t, called[phase], "startupCalendarSync must call %s", phase)
	}
}
