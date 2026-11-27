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
// owner_asks write is written as one literal statement (review rule).
// Its Swift companion is AskExplainTests.testOwnerAskHasNoRecordWrite.
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
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = json_set(payload, '$.other_bench', ?) WHERE kind = 'folder'"},
	} {
		assert.NotEqual(t, payloadWriteForbidden, payloadWriteVerdict(s), s.text)
	}
	for _, s := range []sqlLiteral{
		{file: "../../internal/db/owner_asks.go", text: "INSERT INTO owner_asks (id, payload) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET payload = excluded.payload"},
		{file: "../../internal/db/owner_asks.go", text: "INSERT OR REPLACE INTO owner_asks (id, payload) VALUES (?, ?)"},
		{file: "../../internal/db/owner_asks.go", text: "REPLACE INTO owner_asks (id, payload) VALUES (?, ?)"},
		{file: "../../internal/workbenchfolders/merge.go", text: "UPDATE owner_asks SET payload = ? WHERE kind = 'question'"},
		{file: "../../internal/x/merge.go", text: "UPDATE owner_asks SET payload = json_set(payload, '$.other_bench', ?) WHERE kind = 'folder'"},
	} {
		assert.Equal(t, payloadWriteForbidden, payloadWriteVerdict(s), s.text)
	}
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

var (
	ownerAsksWriteRE  = regexp.MustCompile(`(?is)\b(UPDATE|REPLACE\s+INTO|INSERT\s+OR\s+REPLACE\s+INTO)\s+owner_asks\b`)
	ownerAsksUpsertRE = regexp.MustCompile(`(?is)\bINSERT\s+INTO\s+owner_asks\b.*\bON\s+CONFLICT\b.*\bDO\s+UPDATE\b`)
	payloadRE         = regexp.MustCompile(`(?i)\bpayload\b`)
)

// payloadWriteVerdict classifies a literal. The filing INSERT in
// internal/db/owner_asks.go has no ON CONFLICT, so it is no write here; the
// merge's folder-ask statements must name kind = 'folder' and $.other_bench.
func payloadWriteVerdict(s sqlLiteral) payloadWrite {
	if !ownerAsksWriteRE.MatchString(s.text) && !ownerAsksUpsertRE.MatchString(s.text) {
		return payloadWriteNone
	}
	if !payloadRE.MatchString(s.text) {
		return payloadWriteNone
	}
	if filepath.ToSlash(filepath.Clean(s.file)) == "../../internal/workbenchfolders/merge.go" &&
		strings.Contains(s.text, "kind = 'folder'") && strings.Contains(s.text, "$.other_bench") {
		return payloadWriteAllowedMerge
	}
	return payloadWriteForbidden
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
