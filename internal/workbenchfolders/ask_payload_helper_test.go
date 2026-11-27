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
		if p.table == "owner_asks" {
			built = append(built, pinHomeSQL(p.table, p.column, p.where))
		}
	}
	for _, mt := range mergeTables {
		if mt.table == "owner_asks" {
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
		sqls := ownerAsksHelperSQL(t, f, src)
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

// The scan catches a helper call that would write payload.
func TestOwnerAsksBuiltSQLScanner(t *testing.T) {
	src := []byte("package x\n\nvar bad = pinHomeThenMove(\"owner_asks\", \"payload\", \"\")\n" +
		"var ok = pinHomeThenMove(\"targets\", \"payload\", \"\")\n")
	got := ownerAsksHelperSQL(t, "x.go", src)
	require.Len(t, got, 2, "only the owner_asks call is collected: its pin and its move")
	assert.Regexp(t, payloadWord, got[0], "the pin sets the named column")
}

// ownerAsksHelperSQL is the SQL every pinHomeThenMove / pinHomeSQL call in
// src with the literal table "owner_asks" builds (the same strings the
// helper assembles). A forwarding call with non-literal arguments is skipped:
// its rows come from homePins, checked by value.
func ownerAsksHelperSQL(t *testing.T, path string, src []byte) []string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
	require.NoError(t, err, path)
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
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
				return true // a forwarding call (pinHomeRows, pinHomeThenMove's body): homePins covers it
			}
			args[i], err = strconv.Unquote(lit.Value)
			require.NoError(t, err)
		}
		if args[0] != "owner_asks" {
			return true
		}
		out = append(out, pinHomeSQL(args[0], args[1], args[2]),
			`UPDATE `+args[0]+` SET project_id = ? WHERE project_id = ?`)
		return true
	})
	return out
}
