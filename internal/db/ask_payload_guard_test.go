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
// filing INSERT and the merge's two folder-ask other_bench statements. The
// SQL migrations are scanned too: a table rebuild may copy payload verbatim
// and nothing else (migrationPayloadVerdict). SQL
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
		case payloadWriteNone, payloadWriteAllowedCopy:
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

	// The SQL migrations (the Go one, migration_00125.go, is scanned above):
	// a table rebuild may copy payload verbatim, nothing more.
	copies := 0
	for _, s := range walkSources(t, "migrations", func(path string) bool {
		return strings.HasSuffix(path, ".sql")
	}, sqlMigrationStatements) {
		switch migrationPayloadVerdict(s) {
		case payloadWriteNone, payloadWriteAllowedMerge:
		case payloadWriteAllowedCopy:
			copies++
		case payloadWriteForbidden:
			t.Errorf("%s:%d writes an owner_asks payload: a migration may only copy the column verbatim in a table "+
				"rebuild (spec 2026-11-27 D18)\n%s", s.file, s.line, s.text)
		}
	}
	assert.GreaterOrEqual(t, copies, 2, "the scan sees 00209's two owner_asks rebuild copies")
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

	// A top-level raw string, one-line and block: its inner quotes do not
	// split it.
	swiftSrc = "try db.execute(sql: #\"UPDATE \"owner_asks\" SET payload = ?\"#)\n" +
		"let b = ##\"\"\"\n    UPDATE \"owner_asks\"\n    SET payload = ?\n    \"\"\"##\n" +
		"#if DEBUG\nlet c = #\"\"#\n#endif\n"
	got = swiftSQLLiterals("WatchtowerDesktop/Sources/v.swift", []byte(swiftSrc))
	forbidden = 0
	for _, s := range got {
		if payloadWriteVerdict(s) == payloadWriteForbidden {
			forbidden++
		}
	}
	assert.Equal(t, 2, forbidden, "a top-level Swift raw string and raw block: %v", got)
}

// The migration scan: a statement writing an owner_asks table's payload is
// forbidden, a rebuild copying the column verbatim is not.
func TestAskPayloadGuardMigrationScanner(t *testing.T) {
	verdicts := func(src string) []payloadWrite {
		var out []payloadWrite
		for _, s := range sqlMigrationStatements("migrations/99999_fake.sql", []byte(src)) {
			out = append(out, migrationPayloadVerdict(s))
		}
		return out
	}
	rebuild := "-- +goose Up\n-- +goose StatementBegin\nBEGIN IMMEDIATE;\n" +
		"CREATE TABLE owner_asks_new (id INTEGER PRIMARY KEY, kind TEXT, payload TEXT NOT NULL DEFAULT '{}'); -- payload; kept\n" +
		"INSERT INTO owner_asks_new (id, kind, payload)\n    SELECT id, kind, payload FROM owner_asks;\n" +
		"DROP TABLE owner_asks;\nALTER TABLE owner_asks_new RENAME TO owner_asks;\nCOMMIT;\n-- +goose StatementEnd\n"
	got := verdicts(rebuild)
	assert.NotContains(t, got, payloadWriteForbidden, "a verbatim rebuild copy")
	assert.Contains(t, got, payloadWriteAllowedCopy, "the copy is seen")

	for _, src := range []string{
		"UPDATE owner_asks SET payload = json_remove(payload, '$.questions');",
		"UPDATE \"owner_asks\" SET payload = '{}' WHERE kind = 'check'",
		"-- a comment; then\nUPDATE [main].[owner_asks]\n  SET payload = ?;",
		"REPLACE INTO owner_asks (id, kind) SELECT id, kind FROM owner_asks_old;",
		"INSERT INTO owner_asks (id, payload) VALUES (1, '{}') ON CONFLICT (id) DO UPDATE SET payload = excluded.payload;",
		// A rebuild's copy transforming payload, in any position or shape.
		"INSERT INTO owner_asks_new (id, kind, payload) SELECT id, kind, json_remove(payload, '$.questions[0]') FROM owner_asks;",
		"INSERT INTO owner_asks_new (id, payload, kind) SELECT id, kind, payload FROM owner_asks;",
		"INSERT INTO owner_asks_new (id, kind, payload) SELECT id, kind, '{}' FROM owner_asks WHERE payload <> '{}';",
		"INSERT INTO owner_asks_new (id, payload) SELECT id, payload FROM owner_asks UNION ALL SELECT 0, '{}';",
		"INSERT INTO asks_tmp (id, payload) SELECT id, (SELECT payload FROM owner_asks LIMIT 1) FROM owner_asks;",
		"CREATE TABLE asks_tmp AS SELECT id, json_set(payload, '$.x', 1) AS payload FROM owner_asks;",
		// The temporary table rewritten before its rename.
		"UPDATE owner_asks_new SET payload = '{}';",
		"INSERT INTO owner_asks_new (id, payload) VALUES (1, '{}');",
		"CREATE TRIGGER t AFTER INSERT ON owner_asks BEGIN UPDATE owner_asks SET payload = '{}' WHERE id = NEW.id; END;",
	} {
		assert.Contains(t, verdicts(src), payloadWriteForbidden, src)
	}
	for _, src := range []string{
		"UPDATE owner_asks SET automation_run_id = NULL WHERE automation_run_id IN (SELECT id FROM runs);",
		"CREATE INDEX idx ON owner_asks (json_extract(payload, '$.x'));",
		"INSERT INTO other (id, body) SELECT id, payload FROM inbox_items;",
		"UPDATE inbox_items SET payload = '{}';",
	} {
		assert.NotContains(t, verdicts(src), payloadWriteForbidden, src)
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
	// A migration's table rebuild copying payload verbatim.
	payloadWriteAllowedCopy
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

// ownerAsksTable is owner_asks or a table named after it (a rebuild's
// owner_asks_new / owner_asks_old), quoted or not, with or without main.
const ownerAsksTable = `(?:(?:` + sqlQuote + `main` + sqlQuote + `|\[main\])\.)?(?:` + sqlQuote + `owner_asks\w*|\[owner_asks\w*\])`

var (
	migUpdateRE     = regexp.MustCompile(`(?is)\bUPDATE(?:\s+OR\s+\w+)?\s+` + ownerAsksTable)
	migReplaceRE    = regexp.MustCompile(`(?is)\b(?:REPLACE|INSERT\s+OR\s+REPLACE)\s+INTO\s+` + ownerAsksTable)
	migInsertIntoRE = regexp.MustCompile(`(?is)\bINSERT(?:\s+OR\s+\w+)?\s+INTO\s+` + ownerAsksTable)
	migReadsRE      = regexp.MustCompile(`(?is)\b(?:FROM|JOIN)\s+` + ownerAsksTable)
	migCopyRE       = regexp.MustCompile(`(?is)^INSERT\s+INTO\s+\S+\s*\(`)
	migSelectRE     = regexp.MustCompile(`(?is)^\s*SELECT\s+`)
	migFromRE       = regexp.MustCompile(`(?i)^FROM\b`)
	migCompoundRE   = regexp.MustCompile(`(?i)\b(?:UNION|INTERSECT|EXCEPT)\b`)
	migLeadRE       = regexp.MustCompile(`(?i)^(?:INSERT|REPLACE|CREATE)\b`)
)

// migrationPayloadVerdict classifies one statement of a SQL migration, where
// an owner_asks write is any table named after it (a rebuild writes
// owner_asks_new and renames it). An UPDATE, REPLACE or upsert of one naming
// payload is forbidden (a REPLACE whether or not it names it). An INSERT
// into one, or an INSERT / CREATE … AS reading one, that names payload is
// allowed only as a rebuild's verbatim copy: INSERT INTO t (… payload …)
// SELECT … payload … FROM …, the bare column at the same position in both
// lists, payload named nowhere else and no compound SELECT. Other statements
// naming payload (an index, a delete, a read of another table) write none.
func migrationPayloadVerdict(s sqlLiteral) payloadWrite {
	if migReplaceRE.MatchString(s.text) {
		return payloadWriteForbidden
	}
	if !payloadRE.MatchString(s.text) {
		return payloadWriteNone
	}
	if migUpdateRE.MatchString(s.text) {
		return payloadWriteForbidden
	}
	if !migInsertIntoRE.MatchString(s.text) && !(migReadsRE.MatchString(s.text) && migLeadRE.MatchString(s.text)) {
		return payloadWriteNone
	}
	if isVerbatimPayloadCopy(s.text) {
		return payloadWriteAllowedCopy
	}
	return payloadWriteForbidden
}

func isVerbatimPayloadCopy(text string) bool {
	if len(payloadRE.FindAllStringIndex(text, -1)) != 2 || migCompoundRE.MatchString(text) {
		return false
	}
	loc := migCopyRE.FindStringIndex(text)
	if loc == nil {
		return false
	}
	cols, rest, ok := sqlParenList(text[loc[1]:])
	if !ok {
		return false
	}
	sel := migSelectRE.FindStringIndex(rest)
	if sel == nil {
		return false
	}
	items, ok := sqlSelectList(rest[sel[1]:])
	if !ok || len(items) != len(cols) {
		return false
	}
	for i, c := range cols {
		if strings.EqualFold(sqlUnquote(c), "payload") {
			return strings.EqualFold(sqlUnquote(items[i]), "payload")
		}
	}
	return false
}

// sqlParenList splits the list up to the ")" closing an already opened "("
// at its top-level commas, and returns what follows it.
func sqlParenList(s string) (items []string, rest string, ok bool) {
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			if depth == 0 {
				return append(items, s[start:i]), s[i+1:], true
			}
			depth--
		case ',':
			if depth == 0 {
				items = append(items, s[start:i])
				start = i + 1
			}
		}
	}
	return nil, "", false
}

// sqlSelectList splits a SELECT's result list, up to its top-level FROM, at
// its top-level commas.
func sqlSelectList(s string) ([]string, bool) {
	var items []string
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				items = append(items, s[start:i])
				start = i + 1
			}
		default:
			if depth == 0 && (i == 0 || !isSQLWordByte(s[i-1])) && migFromRE.MatchString(s[i:]) {
				return append(items, s[start:i]), true
			}
		}
	}
	return nil, false
}

func isSQLWordByte(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// sqlUnquote trims a list item and drops one pair of SQLite name quotes.
func sqlUnquote(item string) string {
	item = strings.TrimSpace(item)
	if len(item) >= 2 {
		if first, last := item[0], item[len(item)-1]; first == '"' && last == '"' || first == '`' && last == '`' || first == '[' && last == ']' {
			return item[1 : len(item)-1]
		}
	}
	return item
}

// sqlMigrationStatements splits a SQL migration into its statements at the
// semicolons outside quotes, `--` comments (goose's markers among them) and
// /* */ comments dropped, each with the line it starts on. A trigger's body
// splits into its statements, each classified on its own.
func sqlMigrationStatements(path string, src []byte) []sqlLiteral {
	s := string(src)
	var out []sqlLiteral
	var b strings.Builder
	line, start := 1, 0
	flush := func() {
		if text := strings.TrimSpace(b.String()); text != "" {
			out = append(out, sqlLiteral{file: path, line: start, text: text})
		}
		b.Reset()
		start = 0
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case strings.HasPrefix(s[i:], "--"):
			end := strings.IndexByte(s[i:], '\n')
			if end < 0 {
				i = len(s)
				continue
			}
			i += end - 1 // the newline is counted next
			continue
		case strings.HasPrefix(s[i:], "/*"):
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				i = len(s)
				continue
			}
			line += strings.Count(s[i:i+2+end+2], "\n")
			b.WriteByte(' ')
			i += 2 + end + 1
			continue
		case c == '\'' || c == '"' || c == '`' || c == '[':
			closing := c
			if c == '[' {
				closing = ']'
			}
			end := strings.IndexByte(s[i+1:], closing)
			if end < 0 {
				end = len(s) - i - 1
			}
			if start == 0 {
				start = line
			}
			lit := s[i : i+1+end+1]
			line += strings.Count(lit, "\n")
			b.WriteString(lit)
			i += end + 1
			continue
		case c == ';':
			flush()
			continue
		case c == '\n':
			line++
		}
		if start == 0 && c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			start = line
		}
		b.WriteByte(c)
	}
	flush()
	return out
}

// walkSources reads every file under root that keep accepts (skipping build
// output: .build, DerivedData, SourcePackages) and collects its literals.
func walkSources(t *testing.T, root string, keep func(string) bool, scan func(string, []byte) []sqlLiteral) []sqlLiteral {
	t.Helper()
	var out []sqlLiteral
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == ".build" || name == "DerivedData" || name == "SourcePackages" {
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
		hashes := swiftStringHashes(s, i)
		q := i + hashes
		if strings.HasPrefix(s[q:], `"""`) {
			closing := `"""` + strings.Repeat("#", hashes)
			end := strings.Index(s[q+3:], closing)
			if end < 0 {
				return s[q+3:], len(s)
			}
			return s[q+3 : q+3+end], q + 3 + end + len(closing)
		}
		if hashes > 0 {
			// A raw string: a backslash escapes nothing.
			end := skipSwiftString(s, i) + 1
			if closing := `"` + strings.Repeat("#", hashes); end-len(closing) > q && strings.HasSuffix(s[:end], closing) {
				return s[q+1 : end-len(closing)], end
			}
			return s[q+1 : end], end
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
		case swiftStringHashes(s, i) >= 0:
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
				if swiftStringHashes(s, k) >= 0 {
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

// swiftStringHashes returns the number of # opening the string literal at
// s[i] (0 for a plain `"`), or -1 when none starts there (`#if`, `#available`).
func swiftStringHashes(s string, i int) int {
	hashes := 0
	for i+hashes < len(s) && s[i+hashes] == '#' {
		hashes++
	}
	if i+hashes < len(s) && s[i+hashes] == '"' {
		return hashes
	}
	return -1
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
