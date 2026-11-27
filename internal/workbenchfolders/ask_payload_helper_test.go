package workbenchfolders

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var payloadWord = regexp.MustCompile(`(?i)\bpayload\b`)

// The one owner_asks write assembled at run time: the merge's and Remove's
// home-folder pin and project move (pinHomeThenMove, pinHomeSQL over
// homePins). They re-key folder and bench columns only, never payload — an
// ask's questions and checklist key its "Not clear?" item chats by position
// (spec 2026-11-27 D3/D18), and the literal scan of
// internal/db/ask_payload_guard_test.go cannot see this SQL. Named as the
// exception in docs/review/review-rules.md §8.
func TestOwnerAsksBuiltSQLNeverNamesPayload(t *testing.T) {
	var built []string
	for _, p := range homePins {
		if isOwnerAsks(p.table) {
			built = append(built, pinHomeSQL(p.table, p.column, p.where))
		}
	}
	for _, mt := range mergeTables {
		if isOwnerAsks(mt.table) {
			assert.NotRegexp(t, payloadWord, mt.column, "mergeTables re-keys owner_asks by %q", mt.column)
		}
	}
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	calls := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		require.NoError(t, err)
		sqls, unreadable := ownerAsksHelperSQL(t, f, src)
		for _, u := range unreadable {
			t.Errorf("%s: a pinHomeThenMove/pinHomeSQL call with a non-literal argument cannot be checked for "+
				"owner_asks.payload; pass literals (or add the call to helperForwarders if it only forwards)", u)
		}
		calls += len(sqls)
		built = append(built, sqls...)
	}
	assert.Positive(t, calls, "the scan sees askMove's pinHomeThenMove(\"owner_asks\", …)")
	require.NotEmpty(t, built)
	for _, q := range built {
		assert.NotRegexp(t, payloadWord, q, "a built owner_asks statement names payload: "+
			"an ask's questions and checklist key its Not clear? item chats by position (spec 2026-11-27 D3/D18)")
	}
}

// The scan catches a helper call that would write payload, under any
// spelling of the table, and refuses a call it cannot read.
func TestOwnerAsksBuiltSQLScanner(t *testing.T) {
	src := []byte("package x\n\nvar bad = pinHomeThenMove(\"owner_asks\", \"payload\", \"\")\n" +
		"var ok = pinHomeThenMove(\"targets\", \"payload\", \"\")\n")
	got, unreadable := ownerAsksHelperSQL(t, "x.go", src)
	require.Len(t, got, 2, "only the owner_asks call is collected: its pin and its move")
	assert.Regexp(t, payloadWord, got[0], "the pin sets the named column")
	assert.Empty(t, unreadable)

	for _, table := range []string{"main.owner_asks", "OWNER_ASKS", "[owner_asks]", `"owner_asks"`, "`owner_asks`", "[main].[owner_asks]"} {
		src := []byte("package x\n\nvar bad = pinHomeSQL(" + strconv.Quote(table) + ", \"payload\", \"\")\n")
		got, _ := ownerAsksHelperSQL(t, "x.go", src)
		require.Len(t, got, 1, table)
		assert.Regexp(t, payloadWord, got[0], table)
	}

	src = []byte("package x\n\nconst col = \"payload\"\n\nvar bad = pinHomeThenMove(\"owner_asks\", col, \"\")\n" +
		"func pinHomeRows() { _ = pinHomeSQL(p.table, p.column, p.where) }\n" +
		"func other() { _ = pinHomeSQL(p.table, p.column, p.where) }\n")
	got, unreadable = ownerAsksHelperSQL(t, "x.go", src)
	assert.Empty(t, got)
	assert.Len(t, unreadable, 2, "the const column and the forwarding call outside the helpers: %v", unreadable)
}

// helperForwarders are the functions whose pinHomeSQL call only forwards
// their own arguments (pinHomeThenMove) or homePins rows (pinHomeRows) —
// both checked by value above.
var helperForwarders = map[string]bool{"pinHomeThenMove": true, "pinHomeRows": true}

// isOwnerAsks reports whether a SQLite table name is owner_asks: quotes,
// brackets and backticks dropped, the main schema dropped, case folded.
func isOwnerAsks(table string) bool {
	name := strings.ToLower(strings.NewReplacer(`"`, "", "`", "", "[", "", "]", "").Replace(strings.TrimSpace(table)))
	return strings.TrimPrefix(name, "main.") == "owner_asks"
}

// ownerAsksHelperSQL is the SQL every pinHomeThenMove / pinHomeSQL call in
// src on owner_asks builds — through the production pinHomeSQL and moveSQL —
// and where a call with a non-literal argument sits outside helperForwarders.
func ownerAsksHelperSQL(t *testing.T, path string, src []byte) (sqls, unreadable []string) {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
	require.NoError(t, err, path)
	for _, decl := range f.Decls {
		enclosing := ""
		if fd, ok := decl.(*ast.FuncDecl); ok {
			enclosing = fd.Name.Name
		}
		ast.Inspect(decl, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			fn, ok := call.Fun.(*ast.Ident)
			if !ok || (fn.Name != "pinHomeThenMove" && fn.Name != "pinHomeSQL") || len(call.Args) != 3 {
				return true
			}
			var args [3]string
			for i, a := range call.Args {
				lit, ok := a.(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					if !helperForwarders[enclosing] {
						unreadable = append(unreadable, fset.Position(call.Pos()).String())
					}
					return true
				}
				args[i], err = strconv.Unquote(lit.Value)
				require.NoError(t, err)
			}
			if !isOwnerAsks(args[0]) {
				return true
			}
			sqls = append(sqls, pinHomeSQL(args[0], args[1], args[2]))
			if fn.Name == "pinHomeThenMove" {
				sqls = append(sqls, moveSQL(args[0]))
			}
			return true
		})
	}
	return sqls, unreadable
}
