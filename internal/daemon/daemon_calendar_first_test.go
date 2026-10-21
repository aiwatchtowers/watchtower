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
// has no seam to observe phase order at run time: Run calls
// startupCalendarSync before runLoop, and runLoop starts the first cycle
// before its loop.
func TestDaemon_Run_SyncsCalendarsBeforeFirstCycle(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)

	order := topLevelCallOrder(daemonFunc(t, file, "Run", true))
	loop, ok := order["runLoop"]
	require.True(t, ok, "Run must hand over to runLoop")
	at, ok := order["startupCalendarSync"]
	require.True(t, ok, "Run must call startupCalendarSync before the first cycle")
	assert.Less(t, at, loop, "startupCalendarSync must run before runLoop starts the first cycle")

	cycleFile, err := parser.ParseFile(token.NewFileSet(), "cycle.go", nil, 0)
	require.NoError(t, err)
	_, ok = topLevelCallOrder(daemonFunc(t, cycleFile, "runLoop", true))["startCycle"]
	assert.True(t, ok, "runLoop must start the first cycle at once, before its loop")

	// startupCalendarSync runs both calendar phases.
	called := calledMethods(daemonFunc(t, file, "startupCalendarSync", true))
	for _, phase := range []string{"phaseCalendarSync", "phaseCalDAVSync"} {
		assert.True(t, called[phase], "startupCalendarSync must call %s", phase)
	}
}

// daemonFunc returns the named function (a method when method) of file.
func daemonFunc(t *testing.T, file *ast.File, name string, method bool) *ast.FuncDecl {
	t.Helper()
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == name && (fd.Recv != nil) == method {
			return fd
		}
	}
	t.Fatalf("%s not found", name)
	return nil
}

// topLevelCallOrder maps each method called in a top-level statement of fn
// to the index of its first such statement. Loops are skipped: runLoop's
// startCycle calls inside its for statement must not count as the first
// cycle. So are function literals (a deferred closure runs last).
func topLevelCallOrder(fn *ast.FuncDecl) map[string]int {
	order := map[string]int{}
	for i, stmt := range fn.Body.List {
		if _, loop := stmt.(*ast.ForStmt); loop {
			continue
		}
		ast.Inspect(stmt, func(n ast.Node) bool {
			if _, lit := n.(*ast.FuncLit); lit {
				return false
			}
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					if _, seen := order[sel.Sel.Name]; !seen {
						order[sel.Sel.Name] = i
					}
				}
			}
			return true
		})
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

// Run wires the wake watcher whatever sync.sync_on_wake says: a sleep that
// interrupts a cycle cancels its fetches either way (runLoop). Pinned
// statically, like the test above: no statement of Run up to and including
// the WatchWake call reads SyncOnWake — not a guard around the call, and not
// an early return or a flag before it.
func TestDaemon_Run_WatchesWakeRegardlessOfSyncOnWake(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "daemon.go", nil, 0)
	require.NoError(t, err)

	found := false
	for _, stmt := range daemonFunc(t, file, "Run", true).Body.List {
		calls, reads := false, false
		ast.Inspect(stmt, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.Ident:
				calls = calls || n.Name == "WatchWake"
			case *ast.SelectorExpr:
				reads = reads || n.Sel.Name == "SyncOnWake"
			}
			return true
		})
		require.False(t, reads, "Run reads SyncOnWake at or before its WatchWake call (daemon.go:%d)",
			fset.Position(stmt.Pos()).Line)
		if calls {
			found = true
			break
		}
	}
	assert.True(t, found, "Run must start WatchWake")
}
