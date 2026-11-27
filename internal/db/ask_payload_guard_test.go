package db

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// An ask's questions and checklist key its "Not clear?" item chats by
// position (`<wb>:<ask>:q<N>`, spec 2026-11-27 D3), so they must never be
// rewritten after filing (D18). The guard scans the SQL literals of every
// writer of owner_asks — Go under internal/ and cmd/, Swift under the Desktop,
// the Kit and the phone — and fails on a write naming payload other than the
// filing INSERT and the merge's two folder-ask other_bench statements. SQL
// assembled from parts at run time is outside what a text scan sees: an
// owner_asks write is written as one literal statement (docs/review/review-rules.md §8);
// the one built exception, workbenchfolders' pinHomeThenMove/pinHomeSQL, is
// pinned by TestOwnerAsksBuiltSQLNeverNamesPayload there. Its Swift
// companion is AskExplainTests.testOwnerAskHasNoRecordWrite.
func TestAskPayloadItemsAreNeverRewritten(t *testing.T) {
	var stmts []sqlLiteral
	for _, root := range []string{"../../internal", "../../cmd"} {
		stmts = append(stmts, walkSources(t, root, func(path string) bool {
			return strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go")
		}, func(path string, src []byte) []sqlLiteral { return goSQLLiterals(t, path, src) })...)
	}
	for _, root := range []string{"../../WatchtowerDesktop/Sources", "../../WatchtowerKit/Sources", "../../WatchtowerMobile"} {
		stmts = append(stmts, walkSources(t, root, func(path string) bool {
			return strings.HasSuffix(path, ".swift")
		}, swiftSQLLiterals)...)
	}

	allowedMerge := 0
	for _, s := range stmts {
		switch payloadWriteVerdict(s) {
		case payloadWriteNone:
		case payloadWriteAllowedMerge:
			allowedMerge++
		case payloadWriteForbidden:
			t.Errorf("%s:%d writes owner_asks.payload: an ask's questions and checklist key its Not clear? item chats "+
				"by position (spec 2026-11-27 D3/D18); rewriting them needs a re-key of those chats in the same transaction\n%s",
				s.file, s.line, s.text)
		}
	}
	assert.Equal(t, 2, allowedMerge,
		"the scan sees exactly the two moveAsks folder-ask statements in internal/workbenchfolders/merge.go")
}

// The scanner catches a payload write in each literal form, and lets the
// three allowed statements through.
func TestAskPayloadGuardScanner(t *testing.T) {
	goSrc := []byte("package x\n\nfunc f() {\n" +
		"\t_ = `UPDATE owner_asks\n\t\tSET payload = ? WHERE id = ?`\n" +
		"\t_ = \"UPDATE owner_asks SET status = 'x', \" + col + \" = ?, payload = ?\"\n" +
		"}\n")
	got := goSQLLiterals(t, "internal/x/x.go", goSrc)
	forbidden := 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 2, forbidden, "a Go raw string and a Go one-line string (joined across +): %v", got)

	swiftSrc := "let a = \"\"\"\n    UPDATE owner_asks\n    SET payload = ?\n    \"\"\"\n" +
		"// a comment with \"quotes\"\n" +
		"try db.execute(sql: \"UPDATE owner_asks SET payload = ?\", arguments: [p])\n"
	got = swiftSQLLiterals("WatchtowerDesktop/Sources/x.swift", []byte(swiftSrc))
	forbidden = 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 2, forbidden, "a Swift \"\"\" block and a Swift one-line string: %v", got)

	for _, s := range []sqlLiteral{
		{file: "../../internal/db/owner_asks.go", text: "INSERT INTO owner_asks (project_id, payload) VALUES (?, ?)"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_remove(payload, '$.other_bench') WHERE kind = 'folder'"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_set(payload, '$.other_bench', json_object('id', ?, 'name', ?))\n\t\tWHERE kind = 'folder' AND project_id <> ?"},
	} {
		assert.NotEqual(t, payloadWriteForbidden, payloadWriteVerdict(s), s.text)
	}
	for _, s := range []sqlLiteral{
		{file: "../../internal/db/owner_asks.go", text: "INSERT INTO owner_asks (id, payload) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET payload = excluded.payload"},
		{file: "../../internal/db/owner_asks.go", text: "INSERT OR REPLACE INTO owner_asks (id, payload) VALUES (?, ?)"},
		{file: "../../internal/db/owner_asks.go", text: "REPLACE INTO owner_asks (id, payload) VALUES (?, ?)"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = ? WHERE kind = 'question'"},
		{file: "../../internal/x/merge.go", text: "UPDATE owner_asks SET payload = json_set(payload, '$.other_bench', ?) WHERE kind = 'folder'"},
		// A REPLACE resets the whole row, payload named or not.
		{file: "../../internal/db/owner_asks.go", text: "REPLACE INTO owner_asks (id, title) VALUES (?, ?)"},
		{file: "../../internal/db/owner_asks.go", text: "INSERT OR REPLACE INTO owner_asks (id, title) VALUES (?, ?)"},
		// The merge exception is the two exact statements, not a look-alike.
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_remove(payload, '$.other_bench', '$.questions') WHERE kind = 'folder'"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_remove(payload, '$.other_bench') WHERE kind = 'folder' OR 1"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_remove(payload, '$.other_bench') WHERE kind = 'folder'; UPDATE owner_asks SET payload = '{}'"},
		// Conflict clauses, quoting and the schema name.
		{file: "../../internal/db/owner_asks.go", text: "UPDATE OR REPLACE owner_asks SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: "UPDATE OR IGNORE owner_asks SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: `UPDATE "owner_asks" SET payload = ?`},
		{file: "../../internal/db/owner_asks.go", text: "UPDATE `owner_asks` SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: "UPDATE main.owner_asks SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: `UPDATE "main"."owner_asks" SET payload = ?`},
		{file: "../../internal/db/owner_asks.go", text: `REPLACE INTO "owner_asks" (id) VALUES (?)`},
		{file: "../../internal/db/owner_asks.go", text: "INSERT OR REPLACE INTO main.owner_asks (id) VALUES (?)"},
		{file: "../../internal/db/owner_asks.go", text: `INSERT INTO "owner_asks" (id, payload) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET payload = excluded.payload`},
		{file: "../../internal/db/owner_asks.go", text: "INSERT INTO main.owner_asks (id, payload) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET payload = excluded.payload"},
		// SQLite's bracket quoting.
		{file: "../../internal/db/owner_asks.go", text: "UPDATE [owner_asks] SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: "UPDATE [main].[owner_asks] SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: "UPDATE main.[owner_asks] SET payload = ?"},
		{file: "../../internal/db/owner_asks.go", text: "REPLACE INTO [owner_asks] (id) VALUES (?)"},
		{file: "../../internal/db/owner_asks.go", text: "REPLACE INTO [main].[owner_asks] (id) VALUES (?)"},
	} {
		assert.Equal(t, payloadWriteForbidden, payloadWriteVerdict(s), s.text)
	}

	// A quoted "(" inside an interpolation does not unbalance the scan: a
	// write on a later line is still seen.
	swiftSrc = "let label = \"\\(x ?? \"(\")\"\n" +
		"try db.execute(sql: \"UPDATE owner_asks SET payload = ?\")\n"
	got = swiftSQLLiterals("WatchtowerDesktop/Sources/y.swift", []byte(swiftSrc))
	forbidden = 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 1, forbidden, "a write after an interpolation holding a quoted paren: %v", got)

	// A raw string inside an interpolation: its backslash escapes nothing,
	// so the string ends at `"#` and a write on a later line is still seen.
	swiftSrc = "let label = \"\\(v ?? #\"\\\"#)\"\n" +
		"try db.execute(sql: \"UPDATE owner_asks SET payload = ?\")\n"
	got = swiftSQLLiterals("WatchtowerDesktop/Sources/z.swift", []byte(swiftSrc))
	forbidden = 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 1, forbidden, "a write after an interpolation holding a raw string: %v", got)

	// A raw string's own escape `\#"` does not close it.
	swiftSrc = "let label = \"\\(v ?? #\"a\"b\\#\"#\"#)\"\n" +
		"try db.execute(sql: \"UPDATE owner_asks SET payload = ?\")\n"
	got = swiftSQLLiterals("WatchtowerDesktop/Sources/w.swift", []byte(swiftSrc))
	forbidden = 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 1, forbidden, "a write after an interpolation holding a raw string with an escape: %v", got)
}

// sqlLiteral is one string literal (or a + chain of them, a non-literal part
// standing as "?") with where it starts.
type sqlLiteral struct {
	file string
	line int
	text string
}

type payloadWrite int

const (
	payloadWriteNone payloadWrite = iota
	payloadWriteAllowedMerge
	payloadWriteForbidden
)

// ownerAsksName is owner_asks as SQLite takes it: bare, quoted ("…", `…`
// or […]), with or without the main schema.
const (
	sqlQuote      = "[\"`]?"
	ownerAsksName = `(?:(?:` + sqlQuote + `main` + sqlQuote + `|\[main\])\.)?(?:` + sqlQuote + `owner_asks\b|\[owner_asks\])`
)

var (
	ownerAsksUpdateRE  = regexp.MustCompile(`(?is)\bUPDATE(?:\s+OR\s+\w+)?\s+` + ownerAsksName)
	ownerAsksReplaceRE = regexp.MustCompile(`(?is)\b(?:REPLACE|INSERT\s+OR\s+REPLACE)\s+INTO\s+` + ownerAsksName)
	ownerAsksUpsertRE  = regexp.MustCompile(`(?is)\bINSERT(?:\s+OR\s+\w+)?\s+INTO\s+` + ownerAsksName + `.*\bON\s+CONFLICT\b.*\bDO\s+UPDATE\b`)
	payloadRE          = regexp.MustCompile(`(?i)\bpayload\b`)
	spaceRE            = regexp.MustCompile(`\s+`)
	sqlOrRE            = regexp.MustCompile(`(?i)\bOR\b`)
)

// mergePayloadWrites are the two moveAsks statements up to their folder
// restriction, whitespace normalised: the merge may set or drop a folder
// ask's $.other_bench and nothing else.
var mergePayloadWrites = []string{
	"UPDATE owner_asks SET payload = json_remove(payload, '$.other_bench') WHERE kind = 'folder'",
	"UPDATE owner_asks SET payload = json_set(payload, '$.other_bench', json_object('id', ?, 'name', ?)) WHERE kind = 'folder'",
}

// payloadWriteVerdict classifies a literal. A REPLACE of an owner_asks row
// resets every column it omits, payload included, so any is forbidden. The
// filing INSERT in internal/db/owner_asks.go has no ON CONFLICT, so it is no
// write here. The merge's statements are allowed only in
// internal/workbenchfolders/merge.go, exactly as mergePayloadWrites spells
// them, their WHERE going on only with AND (an OR would widen the folder
// restriction) and no second statement after them.
func payloadWriteVerdict(s sqlLiteral) payloadWrite {
	if ownerAsksReplaceRE.MatchString(s.text) {
		return payloadWriteForbidden
	}
	if !ownerAsksUpdateRE.MatchString(s.text) && !ownerAsksUpsertRE.MatchString(s.text) {
		return payloadWriteNone
	}
	if !payloadRE.MatchString(s.text) {
		return payloadWriteNone
	}
	if filepath.ToSlash(filepath.Clean(s.file)) == "../../internal/workbenchfolders/merge.go" && isMergePayloadWrite(s.text) {
		return payloadWriteAllowedMerge
	}
	return payloadWriteForbidden
}

func isMergePayloadWrite(text string) bool {
	norm := strings.TrimSpace(spaceRE.ReplaceAllString(text, " "))
	if strings.Contains(norm, ";") {
		return false
	}
	for _, stmt := range mergePayloadWrites {
		rest, ok := strings.CutPrefix(norm, stmt)
		if !ok {
			continue
		}
		if rest != "" && !strings.HasPrefix(rest, " AND ") {
			return false
		}
		if sqlOrRE.MatchString(rest) {
			return false
		}
		return true
	}
	return false
}

// walkSources reads every file under root that keep accepts (skipping .build)
// and collects its literals.
func walkSources(t *testing.T, root string, keep func(string) bool, scan func(string, []byte) []sqlLiteral) []sqlLiteral {
	t.Helper()
	var out []sqlLiteral
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".build" {
				return filepath.SkipDir
			}
			return nil
		}
		if !keep(path) {
			return nil
		}
		src, err := os.ReadFile(path) //nolint:gosec // test reads the repo's own sources
		if err != nil {
			return err
		}
		out = append(out, scan(path, src)...)
		return nil
	})
	require.NoError(t, err, root)
	return out
}

// goSQLLiterals collects a Go file's string literals, a + chain joined into
// one (a non-literal operand stands as "?").
func goSQLLiterals(t *testing.T, path string, src []byte) []sqlLiteral {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
	require.NoError(t, err, path)
	var out []sqlLiteral
	ast.Inspect(f, func(n ast.Node) bool {
		switch e := n.(type) {
		case *ast.BinaryExpr:
			if e.Op != token.ADD {
				return true
			}
			var b strings.Builder
			hasLit := false
			var flatten func(ast.Expr)
			flatten = func(x ast.Expr) {
				x = ast.Unparen(x)
				if be, ok := x.(*ast.BinaryExpr); ok && be.Op == token.ADD {
					flatten(be.X)
					flatten(be.Y)
					return
				}
				if lit, ok := x.(*ast.BasicLit); ok && lit.Kind == token.STRING {
					if v, err := strconv.Unquote(lit.Value); err == nil {
						b.WriteString(v)
						hasLit = true
						return
					}
				}
				b.WriteString("?")
				// Literals nested inside a non-literal operand (a call's
				// arguments) are statements of their own.
				ast.Inspect(x, func(m ast.Node) bool {
					if lit, ok := m.(*ast.BasicLit); ok && lit.Kind == token.STRING {
						if v, err := strconv.Unquote(lit.Value); err == nil {
							out = append(out, sqlLiteral{file: path, line: fset.Position(lit.Pos()).Line, text: v})
						}
					}
					return true
				})
			}
			flatten(e)
			if hasLit {
				out = append(out, sqlLiteral{file: path, line: fset.Position(e.Pos()).Line, text: b.String()})
			}
			return false
		case *ast.BasicLit:
			if e.Kind == token.STRING {
				if v, err := strconv.Unquote(e.Value); err == nil {
					out = append(out, sqlLiteral{file: path, line: fset.Position(e.Pos()).Line, text: v})
				}
			}
		}
		return true
	})
	return out
}

// swiftSQLLiterals collects a Swift file's string literals — """ blocks and
// one-line "…" strings, comments skipped, an interpolation standing as "?" —
// a + chain joined into one.
func swiftSQLLiterals(path string, src []byte) []sqlLiteral {
	s := string(src)
	var out []sqlLiteral
	line := 1
	i := 0
	// readString reads the literal starting at s[i] (a quote) and returns its
	// text and the index past it.
	readString := func(i int) (string, int) {
		var b strings.Builder
		if strings.HasPrefix(s[i:], `"""`) {
			end := strings.Index(s[i+3:], `"""`)
			if end < 0 {
				return s[i+3:], len(s)
			}
			return s[i+3 : i+3+end], i + 3 + end + 3
		}
		j := i + 1
		for j < len(s) && s[j] != '"' && s[j] != '\n' {
			if s[j] == '\\' && j+1 < len(s) {
				if s[j+1] == '(' {
					depth := 0
					k := j + 1
					for ; k < len(s); k++ {
						if s[k] == '"' || s[k] == '#' {
							// A string inside the interpolation: its
							// parens do not count.
							k = skipSwiftString(s, k)
							continue
						}
						if s[k] == '(' {
							depth++
						} else if s[k] == ')' {
							depth--
							if depth == 0 {
								break
							}
						}
					}
					b.WriteString("?")
					j = k + 1
					continue
				}
				b.WriteByte(s[j+1])
				j += 2
				continue
			}
			b.WriteByte(s[j])
			j++
		}
		return b.String(), j + 1
	}
	skipSpace := func(j int) int {
		for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
			j++
		}
		return j
	}
	for i < len(s) {
		switch {
		case strings.HasPrefix(s[i:], "//"):
			end := strings.IndexByte(s[i:], '\n')
			if end < 0 {
				return out
			}
			i += end
		case strings.HasPrefix(s[i:], "/*"):
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				return out
			}
			line += strings.Count(s[i:i+2+end+2], "\n")
			i += 2 + end + 2
		case s[i] == '\n':
			line++
			i++
		case s[i] == '"':
			start := line
			var b strings.Builder
			text, j := readString(i)
			b.WriteString(text)
			// Join a + chain: literals and identifiers (as "?").
			for {
				k := skipSpace(j)
				if k >= len(s) || s[k] != '+' || (k+1 < len(s) && s[k+1] == '=') {
					break
				}
				k = skipSpace(k + 1)
				if k < len(s) && s[k] == '"' {
					text, k = readString(k)
					b.WriteString(text)
				} else {
					m := k
					for m < len(s) && (s[m] == '_' || s[m] == '.' || s[m] >= 'a' && s[m] <= 'z' || s[m] >= 'A' && s[m] <= 'Z' || s[m] >= '0' && s[m] <= '9') {
						m++
					}
					if m == k {
						break
					}
					b.WriteString("?")
					k = m
				}
				j = k
			}
			line += strings.Count(s[i:min(j, len(s))], "\n")
			out = append(out, sqlLiteral{file: path, line: start, text: b.String()})
			i = j
		default:
			i++
		}
	}
	return out
}

// skipSwiftString returns the index of the last byte of the one-line string
// literal starting at s[i] — `"…"` (a backslash escapes) or a raw `#"…"#`
// (any number of #, a backslash escapes nothing, it ends at `"` and as many
// #). A # not opening a raw string is returned as is.
func skipSwiftString(s string, i int) int {
	hashes := 0
	for i+hashes < len(s) && s[i+hashes] == '#' {
		hashes++
	}
	if i+hashes >= len(s) || s[i+hashes] != '"' {
		return i + hashes - 1
	}
	closing := "\"" + strings.Repeat("#", hashes)
	for k := i + hashes + 1; k < len(s); k++ {
		if s[k] == '\n' {
			return k - 1 // unterminated on its line: stop before the newline
		}
		if hashes == 0 && s[k] == '\\' {
			k++
			continue
		}
		// A raw string's escape is `\` and its own number of #: it and the
		// escaped character never close the string.
		if hashes > 0 && s[k] == '\\' && strings.HasPrefix(s[k+1:], strings.Repeat("#", hashes)) {
			k += hashes + 1
			continue
		}
		if strings.HasPrefix(s[k:], closing) {
			return k + len(closing) - 1
		}
	}
	return len(s) - 1
}
