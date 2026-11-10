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

// terminalSessionsReadRe finds a query that reads terminal_sessions rows. A
// JOIN reads rows too; terminal_sessions_* tables (worktrees, agent sessions)
// do not match.
var terminalSessionsReadRe = regexp.MustCompile(`(?i)\b(FROM|JOIN)\s+terminal_sessions\b`)

// terminalSessionsDeleteRe is a DELETE of rows, not a read: it is taken out
// of the text before terminalSessionsReadRe looks at it.
var terminalSessionsDeleteRe = regexp.MustCompile(`(?i)\bDELETE\s+FROM\s+terminal_sessions\b`)

// lookupByID lists the reads of terminal_sessions that stay unfiltered on
// purpose (spec §4 "Lookups by id are unchanged"): each reads one row the
// caller already holds by id (or the rows joined to such a row), and a
// deleting row behaves there as a finished session until the cascade removes
// it. Key: "<repo-relative file>:<function>". Anything that lists rows for a
// UI, the phone, a brief or a rollup, or picks "the latest" row, is not a
// lookup and must filter with NotDeletingSQL instead.
var lookupByID = map[string]string{
	// cmd: the session commands read one row they were handed by id.
	"cmd/workbench_session.go:runWorkbenchSessionStart":  "the folder of the row this start just created",
	"cmd/workbench_session.go:runWorkbenchSessionFinish": "the row's workbench for the caller check; sessionstart.Finish then refuses a deleting row",
	"cmd/workbench_session.go:runWorkbenchSessionStop":   "the row's workbench for the caller check; stopping a deleting row's run stays allowed",
	"cmd/workbench_session.go:checkSessionCaller":        "the caller's own row ($WATCHTOWER_TERMINAL_SESSION_ID)",
	// internal/db: by-id reads and the history the cleanup and the report keep.
	"internal/db/owner_asks.go:DB.InsertOwnerAsk":                              "ownership check of the ask's own session",
	"internal/db/owner_asks.go:DB.AnsweredAsksForBrief":                        "LEFT JOIN to each ask's own session (an owner_asks join, spec §4)",
	"internal/db/review_agent.go:DB.TerminalAgentWorking":                      "one row's agent state by id",
	"internal/db/session_report.go:DB.SessionLeafOwners":                       "session report history: who last stamped each leaf (spec §4)",
	"internal/db/session_report.go:DB.SessionBindings":                         "session report history: target bindings (spec §4)",
	"internal/db/session_ticket.go:DB.SessionTicket":                           "one row's target by id",
	"internal/db/terminal_agent_turns.go:DB.TerminalAgentTurns":                "one row's turns by id (hooks)",
	"internal/db/terminal_agent_turns.go:DB.RecordTerminalAgentTurn":           "one row by id in the hook's write",
	"internal/db/terminal_session_worktrees.go:DB.HasSessionWorktree":          "one row's run start by id (hooks)",
	"internal/db/terminal_session_worktrees.go:DB.TerminalSessionStart":        "one row's start by id for its own cleanup",
	"internal/db/terminal_session_worktrees.go:DB.WorkbenchSessionWorktrees":   "cleanup ownership: a deleting row's worktrees are what its background cleanup removes",
	"internal/db/terminal_session_worktrees.go:DB.ListTerminalSessionActivity": "cleanup in-use/recent-owner catches: a deleting row still protects what it holds until it goes (fail closed)",
	"internal/db/terminal_sessions.go:DB.GetTerminalSession":                   "one row by id",
	"internal/db/terminal_sessions.go:DB.TerminalTranscriptPath":               "one row by id",
	"internal/db/terminal_sessions.go:DB.PlacedSessions":                       "a workbench delete cleans every placed row's worktree, deleting rows included",
	"internal/db/terminal_sessions.go:DB.HeldWorktreeBranches":                 "a deleting row still reserves its worktree branch name",
	"internal/db/terminal_sessions.go:DB.TerminalAgentCwd":                     "one row by id (hooks)",
	"internal/db/terminal_sessions.go:DB.TakeChatQuestion":                     "one row by id in the escalation's write",
	"internal/db/terminal_watch_issue.go:DB.ClearAgentWatchIssue":              "one row by id",
	"internal/db/terminal_watch_issue.go:DB.GetCodexWatchRow":                  "one row by id",
	"internal/db/workbench_agent_analytics.go:DB.ClaudeTerminalSessionIDs":     "agent analytics: a transcript uuid to its row (spec §4)",
	"internal/db/workbench_agent_analytics.go:DB.CodexTerminalSessionIDs":      "agent analytics: a transcript uuid to its row (spec §4)",
	"internal/db/workbench_agent_analytics.go:DB.WorkbenchCodexSessions":       "agent analytics ingest: a deleting row's spend is still real (spec §4)",
	// session report: by id, and summaries the Desktop shows on a Not fully
	// cleaned row; the phone joins them only to the sessions its filtered
	// terminal_session slice publishes.
	"internal/sessionreport/scope.go:loadSession":     "one row by id",
	"internal/sessionreport/scope.go:workbenchLinks":  "target links of sessions chosen elsewhere",
	"internal/sessionreport/summary.go:agentSessions": "summaries keyed by session id; the Desktop's finished group shows a Not fully cleaned row's",
}

// TestProj17_DeletingRowsLeaveEveryList (spec §4): a row with
// delete_requested_at set is deleted as far as the owner is concerned, so
// every list read of terminal_sessions filters it out. A new read must either
// carry the filter (db.NotDeletingSQL) or be named on the lookupByID
// allowlist above with a reason.
func TestProj17_DeletingRowsLeaveEveryList(t *testing.T) {
	root := repoRootForOwnerScan(t)
	var unfiltered []string
	seen := map[string]bool{}
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			rel = filepath.ToSlash(rel)
			for _, site := range terminalSessionsReads(t, path) {
				key := rel + ":" + site.fn
				seen[key] = true
				if site.filtered {
					continue
				}
				if _, ok := lookupByID[key]; ok {
					continue
				}
				unfiltered = append(unfiltered, rel+":"+strconv.Itoa(site.line)+" ("+site.fn+")")
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	sort.Strings(unfiltered)
	for _, s := range unfiltered {
		t.Errorf("unfiltered terminal_sessions read: %s — add %s or name it on lookupByID with a reason", s, "NotDeletingSQL")
	}
	for key := range lookupByID {
		if !seen[key] {
			t.Errorf("lookupByID entry %q matches no terminal_sessions read: remove it", key)
		}
	}
}

type terminalSessionsRead struct {
	fn       string
	line     int
	filtered bool
}

// terminalSessionsReads returns every query text in the file that reads
// terminal_sessions. The unit checked is the whole string expression a
// literal belongs to: a `+` chain of literals and names, and, when that chain
// is a call argument, the call's other arguments too (fmt.Sprintf). A name
// NotDeletingSQL in the unit counts as the filter.
func terminalSessionsReads(t *testing.T, path string) []terminalSessionsRead {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "terminal_sessions") {
		return nil
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	var out []terminalSessionsRead
	for _, decl := range file.Decls {
		fn := declName(decl)
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
			text, err := strconv.Unquote(lit.Value)
			if err != nil || !terminalSessionsReadRe.MatchString(terminalSessionsDeleteRe.ReplaceAllString(text, "")) {
				return true
			}
			unit := enclosingUnit(stack)
			out = append(out, terminalSessionsRead{
				fn:       fn,
				line:     fset.Position(lit.Pos()).Line,
				filtered: unitFiltered(unit),
			})
			return true
		})
	}
	return out
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

// enclosingUnit climbs from the literal (top of stack) through `+` chains and,
// if the chain is a call argument, to the call.
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

func unitFiltered(unit ast.Node) bool {
	filtered := false
	ast.Inspect(unit, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.BasicLit:
			if s, err := strconv.Unquote(v.Value); err == nil && strings.Contains(s, "delete_requested_at") {
				filtered = true
			}
		case *ast.Ident:
			if v.Name == "NotDeletingSQL" {
				filtered = true
			}
		}
		return !filtered
	})
	return filtered
}
