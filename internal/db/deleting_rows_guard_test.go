package db

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The guard's word for the table: terminal_sessions itself, never one of
// the terminal_sessions_* tables (worktrees, agent sessions).
var terminalSessionsWordRe = regexp.MustCompile(`(?i)\bterminal_sessions\b`)

// terminalSessionsWriteRe is a write's target table; it is taken out of the
// text before the guard looks for a read, so a pure UPDATE, INSERT or DELETE
// is not one. terminal_sessions named anywhere else in the same unit is.
var terminalSessionsWriteRe = regexp.MustCompile(`(?i)\b(UPDATE|INSERT\s+(OR\s+\w+\s+)?INTO|DELETE\s+FROM)\s+terminal_sessions\b`)

// sqlReadWordRe is what makes a unit naming the table a read.
var sqlReadWordRe = regexp.MustCompile(`(?i)\b(SELECT|FROM|JOIN)\b`)

// notDeletingRe is the filter written out: the column alone (a SELECT that
// returns it, an UPDATE that sets it) is not the filter.
var notDeletingRe = regexp.MustCompile(`(?i)\bdelete_requested_at\s+IS\s+NULL\b`)

// allowedRead is one lookupByID entry: how many unfiltered read units the
// function holds, and why they stay unfiltered.
type allowedRead struct {
	n   int
	why string
}

// lookupByID lists the reads of terminal_sessions that stay unfiltered on
// purpose (spec §4 "Lookups by id are unchanged"): each reads one row the
// caller already holds by id (or the rows joined to such a row), or history
// a deleting row still owns until the cascade removes it. Key:
// "<repo-relative file>:<function>"; n is the exact number of unfiltered read
// units in that function, so a second one added there fails too. Anything
// that lists rows for a UI, the phone, a brief or a rollup, or picks "the
// latest" row, is not a lookup and must filter with NotDeletingSQL instead.
var lookupByID = map[string]allowedRead{
	// cmd: the session commands read one row they were handed by id.
	"cmd/workbench_session.go:runWorkbenchSessionStart":  {1, "the folder of the row this start just created"},
	"cmd/workbench_session.go:runWorkbenchSessionFinish": {1, "the row's workbench for the caller check; sessionstart.Finish then refuses a deleting row"},
	"cmd/workbench_session.go:runWorkbenchSessionStop":   {1, "the row's workbench for the caller check; stopping a deleting row's run stays allowed"},
	"cmd/workbench_session.go:checkSessionCaller":        {1, "the caller's own row ($WATCHTOWER_TERMINAL_SESSION_ID)"},
	// internal/db: by-id reads and the history the cleanup and the report keep.
	"internal/db/owner_asks.go:DB.InsertOwnerAsk":                              {1, "ownership check of the ask's own session"},
	"internal/db/owner_asks.go:DB.AnsweredAsksForBrief":                        {1, "LEFT JOIN to each ask's own session (an owner_asks join, spec §4)"},
	"internal/db/review_agent.go:DB.TerminalAgentWorking":                      {1, "one row's agent state by id"},
	"internal/db/session_report.go:DB.SessionLeafOwners":                       {1, "session report history: who last stamped each leaf (spec §4)"},
	"internal/db/session_report.go:DB.SessionBindings":                         {1, "session report history: target bindings (spec §4)"},
	"internal/db/session_ticket.go:DB.SessionTicket":                           {1, "one row's target by id"},
	"internal/db/terminal_agent_turns.go:DB.TerminalAgentTurns":                {1, "one row's turns by id (hooks)"},
	"internal/db/terminal_agent_turns.go:DB.RecordTerminalAgentTurn":           {1, "one row by id in the hook's write"},
	"internal/db/terminal_session_agent_sessions.go:DB.AgentSessionIDs":        {1, "one row's agent session ids by id (cleanup adoption)"},
	"internal/db/terminal_session_agent_sessions.go:DB.AgentSessionIDOwners":   {1, "cleanup adoption: a deleting row still owns its uuids, so a shared uuid adopts nothing (fail closed)"},
	"internal/db/terminal_session_worktrees.go:DB.HasSessionWorktree":          {1, "one row's run start by id (hooks)"},
	"internal/db/terminal_session_worktrees.go:DB.TerminalSessionStart":        {1, "one row's start by id for its own cleanup"},
	"internal/db/terminal_session_worktrees.go:DB.WorkbenchSessionWorktrees":   {1, "cleanup ownership: a deleting row's worktrees are what its background cleanup removes"},
	"internal/db/terminal_session_worktrees.go:DB.ListTerminalSessionActivity": {1, "cleanup in-use/recent-owner catches: a deleting row still protects what it holds until it goes (fail closed)"},
	"internal/db/terminal_sessions.go:DB.GetTerminalSession":                   {1, "one row by id"},
	"internal/db/terminal_sessions.go:DB.terminalBackgroundShells":             {1, "one row by id"},
	"internal/db/terminal_sessions.go:DB.TerminalTranscriptPath":               {1, "one row by id"},
	"internal/db/terminal_sessions.go:DB.PlacedSessions":                       {1, "a workbench delete cleans every placed row's worktree, deleting rows included"},
	"internal/db/terminal_sessions.go:DB.HeldWorktreeBranches":                 {1, "a deleting row still reserves its worktree branch name"},
	"internal/db/terminal_sessions.go:DB.TerminalAgentCwd":                     {1, "one row by id (hooks)"},
	"internal/db/terminal_sessions.go:DB.TakeChatQuestion":                     {1, "one row by id in the escalation's write"},
	"internal/db/terminal_watch_issue.go:DB.ClearAgentWatchIssue":              {1, "one row by id"},
	"internal/db/terminal_watch_issue.go:DB.GetCodexWatchRow":                  {1, "one row by id"},
	"internal/db/workbench_agent_analytics.go:DB.ClaudeTerminalSessionIDs":     {1, "agent analytics: a transcript uuid to its row (spec §4)"},
	"internal/db/workbench_agent_analytics.go:DB.CodexTerminalSessionIDs":      {1, "agent analytics: a transcript uuid to its row (spec §4)"},
	"internal/db/workbench_agent_analytics.go:DB.WorkbenchCodexSessions":       {1, "agent analytics ingest: a deleting row's spend is still real (spec §4)"},
	// session report: by id, and summaries the Desktop shows on a Not fully
	// cleaned row; the phone joins them only to the sessions its filtered
	// terminal_session slice publishes.
	"internal/sessionreport/scope.go:loadSession":     {1, "one row by id"},
	"internal/sessionreport/scope.go:workbenchLinks":  {1, "target links of sessions chosen elsewhere"},
	"internal/sessionreport/summary.go:agentSessions": {1, "summaries keyed by session id; the Desktop's finished group shows a Not fully cleaned row's"},
}

// TestProj17_DeletingRowsLeaveEveryList (spec §4): a row with
// delete_requested_at set is deleted as far as the owner is concerned, so
// every list read of terminal_sessions filters it out. A new read must either
// carry the filter (db.NotDeletingSQL) or be named on the lookupByID
// allowlist above with a reason and its count.
func TestProj17_DeletingRowsLeaveEveryList(t *testing.T) {
	root := repoRootForOwnerScan(t)
	var files []string
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() && strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
				files = append(files, path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	reads := map[string][]tsRead{}
	for _, path := range files {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		found, err := terminalSessionsReads(rel, src)
		if err != nil {
			t.Fatal(err)
		}
		if len(found) > 0 {
			reads[rel] = found
		}
	}
	for _, p := range deletingRowsProblems(reads, lookupByID) {
		t.Error(p)
	}
}

// tsRead is one read unit of terminal_sessions in a file.
type tsRead struct {
	fn       string
	line     int
	filtered bool
}

// deletingRowsProblems is the guard's verdict over every file's reads: an
// unfiltered read outside the allowlist, an allowlisted function whose
// unfiltered read count is not its n, and an entry that matches nothing.
func deletingRowsProblems(reads map[string][]tsRead, allow map[string]allowedRead) []string {
	unfiltered := map[string][]string{}
	for file, list := range reads {
		for _, r := range list {
			if !r.filtered {
				key := file + ":" + r.fn
				unfiltered[key] = append(unfiltered[key], file+":"+strconv.Itoa(r.line))
			}
		}
	}
	var out []string
	for key, sites := range unfiltered {
		a, ok := allow[key]
		switch {
		case !ok:
			out = append(out, "unfiltered terminal_sessions read in "+key+" at "+strings.Join(sites, ", ")+
				": add NotDeletingSQL, or name it on lookupByID with a reason and its count")
		case a.n != len(sites):
			out = append(out, "lookupByID "+key+" allows "+strconv.Itoa(a.n)+" unfiltered read(s), found "+
				strconv.Itoa(len(sites))+" at "+strings.Join(sites, ", "))
		}
	}
	for key := range allow {
		if _, ok := unfiltered[key]; !ok {
			out = append(out, "lookupByID entry "+key+" matches no unfiltered terminal_sessions read: remove it")
		}
	}
	sort.Strings(out)
	return out
}

// terminalSessionsReads returns every read unit of terminal_sessions in the
// file. A unit is the whole string expression a literal belongs to: a `+`
// chain of literals and names and, when that chain is a call argument, the
// call's other arguments too (fmt.Sprintf, a QueryRow's query); a nested
// call or function literal is its own unit. Each unit is counted once.
func terminalSessionsReads(name string, src []byte) ([]tsRead, error) {
	if !terminalSessionsWordRe.Match(src) {
		return nil, nil
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, name, src, 0)
	if err != nil {
		return nil, err
	}
	var out []tsRead
	for _, decl := range file.Decls {
		fn := declName(decl)
		seen := map[ast.Node]bool{}
		var stack []ast.Node
		ast.Inspect(decl, func(n ast.Node) bool {
			if n == nil {
				stack = stack[:len(stack)-1]
				return true
			}
			stack = append(stack, n)
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			unit := enclosingUnit(stack)
			if seen[unit] {
				return true
			}
			seen[unit] = true
			text, refsFilter := unitText(unit)
			if !isTerminalSessionsRead(text) {
				return true
			}
			out = append(out, tsRead{
				fn:       fn,
				line:     fset.Position(unit.Pos()).Line,
				filtered: refsFilter || notDeletingRe.MatchString(text),
			})
			return true
		})
	}
	return out, nil
}

// isTerminalSessionsRead: the unit names terminal_sessions other than as a
// write's target, and has SELECT, FROM or JOIN anywhere (comma joins and
// split literals included).
func isTerminalSessionsRead(text string) bool {
	rest := terminalSessionsWriteRe.ReplaceAllString(text, "")
	return terminalSessionsWordRe.MatchString(rest) && sqlReadWordRe.MatchString(rest)
}

func declName(decl ast.Decl) string {
	switch d := decl.(type) {
	case *ast.FuncDecl:
		if d.Recv != nil && len(d.Recv.List) > 0 {
			recv := d.Recv.List[0].Type
			if star, ok := recv.(*ast.StarExpr); ok {
				recv = star.X
			}
			if id, ok := recv.(*ast.Ident); ok {
				return id.Name + "." + d.Name.Name
			}
		}
		return d.Name.Name
	case *ast.GenDecl:
		for _, spec := range d.Specs {
			if vs, ok := spec.(*ast.ValueSpec); ok && len(vs.Names) > 0 {
				return vs.Names[0].Name
			}
		}
	}
	return "?"
}

// enclosingUnit climbs from the literal (top of stack) through `+` chains
// and, if the chain is a call argument, to the call.
func enclosingUnit(stack []ast.Node) ast.Node {
	i := len(stack) - 1
	for i > 0 {
		if be, ok := stack[i-1].(*ast.BinaryExpr); ok && be.Op == token.ADD {
			i--
			continue
		}
		break
	}
	if i > 0 {
		if call, ok := stack[i-1].(*ast.CallExpr); ok {
			return call
		}
	}
	return stack[i]
}

// unitText is the unit's string literals joined, and whether it names
// NotDeletingSQL; nested calls and function literals are their own units.
func unitText(unit ast.Node) (string, bool) {
	var parts []string
	refs := false
	ast.Inspect(unit, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.FuncLit:
			return false
		case *ast.CallExpr:
			return v == unit
		case *ast.BasicLit:
			if v.Kind == token.STRING {
				if s, err := strconv.Unquote(v.Value); err == nil {
					parts = append(parts, s)
				}
			}
		case *ast.Ident:
			if v.Name == "NotDeletingSQL" {
				refs = true
			}
		}
		return true
	})
	return strings.Join(parts, "\n"), refs
}

// guardFixture runs the guard over one Go snippet as file "x.go".
func guardFixture(t *testing.T, body string, allow map[string]allowedRead) []string {
	t.Helper()
	reads, err := terminalSessionsReads("x.go", []byte("package x\n\n"+body))
	if err != nil {
		t.Fatal(err)
	}
	return deletingRowsProblems(map[string][]tsRead{"x.go": reads}, allow)
}

// The guard itself, on small sources: what it flags and what it lets pass.
func TestProj17_DeletingRowsGuardFixtures(t *testing.T) {
	cases := []struct {
		name  string
		body  string
		allow map[string]allowedRead
		flags bool
	}{
		{"plain select", "func f() { q(`SELECT id FROM terminal_sessions WHERE project_id = ?`) }", nil, true},
		{"join", "func f() { q(`SELECT a.id FROM owner_asks a JOIN terminal_sessions s ON s.id = a.session_id`) }", nil, true},
		{"comma join", "func f() { q(`SELECT a.id FROM owner_asks a, terminal_sessions s WHERE s.id = a.session_id`) }", nil, true},
		{"split literal", "func f() { q(`SELECT id FROM ` + \"terminal_sessions\" + ` WHERE id > 0`) }", nil, true},
		{"filtered by name", "func f() { q(`SELECT id FROM terminal_sessions WHERE ` + NotDeletingSQL) }", nil, false},
		{"filtered by qualified name", "func f() { q(`SELECT id FROM terminal_sessions s WHERE s.` + db.NotDeletingSQL) }", nil, false},
		{"filtered written out", "func f() { q(`SELECT id FROM terminal_sessions WHERE Delete_Requested_At\n  is   null`) }", nil, false},
		{"sprintf argument", "func f() { q(fmt.Sprintf(`SELECT id FROM terminal_sessions WHERE %s`, NotDeletingSQL)) }", nil, false},
		{"returns the column only", "func f() { q(`SELECT delete_requested_at FROM terminal_sessions WHERE id = ?`) }", nil, true},
		{"is not null is no filter", "func f() { q(`SELECT id FROM terminal_sessions WHERE delete_requested_at IS NOT NULL`) }", nil, true},
		{"update setting the column", "func f() { q(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`) }", nil, false},
		{"insert", "func f() { q(`INSERT INTO terminal_sessions (title) VALUES (?)`) }", nil, false},
		{"delete", "func f() { q(`DELETE FROM terminal_sessions WHERE id = ?`) }", nil, false},
		{"update with another table's select", "func f() { q(`UPDATE terminal_sessions SET n = (SELECT COUNT(*) FROM owner_asks)`) }", nil, false},
		{"insert from a select of it", "func f() { q(`INSERT INTO x (id) SELECT id FROM terminal_sessions`) }", nil, true},
		{"other table", "func f() { q(`SELECT root FROM terminal_session_worktrees WHERE session_id = ?`) }", nil, false},
		{"suffixed table", "func f() { q(`SELECT id FROM terminal_sessions_agent WHERE x = ?`) }", nil, false},
		{"prose", "func f() { log(\"the terminal_sessions table\") }", nil, false},
		{"package-level query", "const listQ = `SELECT id FROM terminal_sessions`", nil, true},
		{"allowlisted", "func f() { q(`SELECT id FROM terminal_sessions WHERE id = ?`) }",
			map[string]allowedRead{"x.go:f": {1, "by id"}}, false},
		{"a second read in an allowlisted function", "func f() {\n\tq(`SELECT id FROM terminal_sessions WHERE id = ?`)\n\tq(`SELECT title FROM terminal_sessions`)\n}",
			map[string]allowedRead{"x.go:f": {1, "by id"}}, true},
		{"a count that matches", "func f() {\n\tq(`SELECT id FROM terminal_sessions WHERE id = ?`)\n\tq(`SELECT title FROM terminal_sessions WHERE id = ?`)\n}",
			map[string]allowedRead{"x.go:f": {2, "by id"}}, false},
		{"a filtered read beside an allowlisted one", "func f() {\n\tq(`SELECT id FROM terminal_sessions WHERE id = ?`)\n\tq(`SELECT title FROM terminal_sessions WHERE ` + NotDeletingSQL)\n}",
			map[string]allowedRead{"x.go:f": {1, "by id"}}, false},
		{"stale entry", "func f() { q(`SELECT id FROM terminal_sessions WHERE ` + NotDeletingSQL) }",
			map[string]allowedRead{"x.go:f": {1, "by id"}}, true},
		{"a closure's read is its own unit", "func f() { q(`SELECT 1`, func() { q(`SELECT id FROM terminal_sessions`) }) }", nil, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := guardFixture(t, c.body, c.allow)
			if (len(got) > 0) != c.flags {
				t.Errorf("problems = %q, want flagged = %v", got, c.flags)
			}
		})
	}
}
