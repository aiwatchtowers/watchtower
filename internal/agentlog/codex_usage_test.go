package agentlog

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

// cxTokensCW is cxTokens with a cache-write figure (spec 2026-11-03 §4.7).
func cxTokensCW(t *testing.T, ts string, in, cached, cacheWrite, out, reasoning, total int64) string {
	u := map[string]any{"input_tokens": in, "cached_input_tokens": cached, "cache_write_input_tokens": cacheWrite,
		"output_tokens": out, "reasoning_output_tokens": reasoning, "total_tokens": in + out}
	tot := map[string]any{"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": total}
	return cx(t, ts, "event_msg", map[string]any{"type": "token_count", "info": map[string]any{"last_token_usage": u, "total_token_usage": tot}})
}

func apiCalls(pr *ParseResult) []agentlogdb.AgentLogEvent {
	var out []agentlogdb.AgentLogEvent
	for _, e := range pr.Events {
		if e.Kind == "api_call" {
			out = append(out, e)
		}
	}
	return out
}

func TestParseCodex_CacheWriteMapping(t *testing.T) {
	pr := parseCodex(t, cxMeta(t, "00.000", cxParent, "/work")+cxTokensCW(t, "01.000", 100, 60, 10, 20, 5, 120),
		ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
	calls := apiCalls(pr)
	require.Len(t, calls, 1)
	assert.Equal(t, int64(30), calls[0].InputTokens, "input − cached − cache write")
	assert.Equal(t, int64(60), calls[0].CacheReadTokens)
	assert.Equal(t, int64(10), calls[0].CacheWrite5mTokens)
	assert.Zero(t, calls[0].CacheWrite1hTokens)
	assert.Equal(t, int64(20), calls[0].OutputTokens, "reasoning is inside output, never added twice")
	assert.Equal(t, int64(5), calls[0].ThinkingTokens)
	assert.Zero(t, pr.CodexUsageMismatch)
}

func TestParseCodex_NegativeFreshInputCounted(t *testing.T) {
	for _, tc := range []struct{ in, cached, cw int64 }{{50, 60, 0}, {50, 40, 20}} {
		pr := parseCodex(t, cxMeta(t, "00.000", cxParent, "/work")+cxTokensCW(t, "01.000", tc.in, tc.cached, tc.cw, 20, 0, 70),
			ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
		calls := apiCalls(pr)
		require.Len(t, calls, 1)
		assert.Zero(t, calls[0].InputTokens, "%+v: stored as 0", tc)
		assert.Equal(t, 1, pr.CodexUsageMismatch, "%+v: counted, never floored silently", tc)
	}
}

// The key keeps the figures main stored (the literal is what the code before
// the cache-write mapping produced for this line), with or without the new field.
func TestParseCodex_KeyUnchangedWithoutCacheWrite(t *testing.T) {
	const want = "api_call:codex:" + cxParent + "/100.60.20.5.120/0.0.0.0.120"
	head := cxMeta(t, "00.000", cxParent, "/work")
	for _, l := range []string{cxTokens(t, "01.000", 100, 60, 20, 5, 120), cxTokensCW(t, "01.000", 100, 60, 10, 20, 5, 120)} {
		calls := apiCalls(parseCodex(t, head+l, ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent}))
		require.Len(t, calls, 1)
		assert.Equal(t, want, calls[0].Key)
	}
}

func TestScan_CodexUsageMismatchSummed(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxMeta(t, "00.000", cxParent, f.folder)+cxModel(t, "00.500", "gpt-test")+
		cxTokensCW(t, "01.000", 50, 60, 0, 20, 0, 70)+cxTokensCW(t, "02.000", 100, 60, 10, 20, 0, 190))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, 1, r.CodexUsageMismatch)
	b, err := json.Marshal(r)
	require.NoError(t, err)
	assert.Contains(t, string(b), `"codex_usage_mismatch":1`)
}

// codexSplit is the stored token split of every codex api_call, by key.
func codexSplit(t *testing.T, f *fixture) map[string][3]float64 {
	t.Helper()
	rows, err := f.al.Query(`SELECT key, input_tokens, cache_write_5m_tokens, cost_usd FROM agent_log_events
		WHERE kind = 'api_call' AND key LIKE 'api_call:codex:%'`)
	require.NoError(t, err)
	defer rows.Close()
	out := map[string][3]float64{}
	for rows.Next() {
		var k string
		var in, cw int64
		var usd float64
		require.NoError(t, rows.Scan(&k, &in, &cw, &usd))
		out[k] = [3]float64{float64(in), float64(cw), usd}
	}
	require.NoError(t, rows.Err())
	return out
}

// downgradeCodexRows puts the stored codex rows back to main's split (the
// cache write inside the fresh input, cost from that) under parser version 4.
func downgradeCodexRows(t *testing.T, f *fixture) {
	t.Helper()
	_, err := f.al.Exec(`UPDATE agent_log_events SET input_tokens = input_tokens + cache_write_5m_tokens,
		cache_write_5m_tokens = 0, cost_usd = 99 WHERE key LIKE 'api_call:codex:%'`)
	require.NoError(t, err)
	_, err = f.al.Exec(`UPDATE agent_log_files SET parser_version = 4 WHERE agent = 'codex'`)
	require.NoError(t, err)
}

func codexWriteRollout(t *testing.T, f *fixture, n int) string {
	var b strings.Builder
	b.WriteString(cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", "claude-opus-5-5"))
	for i := range n {
		b.WriteString(cxTokensCW(t, fmt.Sprintf("%02d.000", 10+i), 1000, 600, 100, int64(i+1), 0, int64(2000*(i+1))))
	}
	return f.writeRollout(cxParent, b.String())
}

func TestScan_CodexReReadOnceUnderNewParserVersion(t *testing.T) {
	f := newFixture(t)
	p := codexWriteRollout(t, f, 3)
	f.codexRow(f.wb, cxParent, f.folder, "")
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	require.Zero(t, f.scan().FailedFiles)
	want := codexSplit(t, f)
	require.Len(t, want, 3)
	for _, v := range want {
		require.Equal(t, [2]float64{300, 100}, [2]float64{v[0], v[1]})
	}
	downgradeCodexRows(t, f)
	_, err := f.al.Exec(`UPDATE agent_log_files SET parser_version = 4 WHERE agent = 'claude'`) // Claude's current version
	require.NoError(t, err)

	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, 1, r.FilesScanned, "only the codex rollout is re-read")
	assert.Equal(t, 1, r.FilesSkipped, "the Claude transcript under version 4 is unchanged")
	assert.Equal(t, want, codexSplit(t, f), "split and cost corrected under the unchanged keys")
	calls, _ := f.totals()
	assert.Equal(t, int64(4), calls, "no new rows")
	fr, err := f.al.GetAgentLogFile(p)
	require.NoError(t, err)
	assert.Equal(t, CodexParserVersion, fr.ParserVersion)

	r = f.scan()
	assert.Zero(t, r.FilesScanned, "a second scan re-reads nothing")
	assert.Equal(t, 2, r.FilesSkipped)
}

func TestScan_CodexReReadStoppedResumes(t *testing.T) {
	old := batchRows
	batchRows = 2
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	p := codexWriteRollout(t, f, 6)
	f.codexRow(f.wb, cxParent, f.folder, "")
	require.Zero(t, f.scan().FailedFiles)
	want := codexSplit(t, f)
	downgradeCodexRows(t, f)

	// Out of time after the first slice of the re-read: the file row then
	// carries version 5 again.
	start := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	now := func() time.Time {
		if fr, err := f.al.GetAgentLogFile(p); err == nil && fr != nil && fr.ParserVersion == CodexParserVersion {
			return start.Add(time.Hour)
		}
		return start
	}
	r, err := Scan(t.Context(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, CodexHome: f.codex, Budget: time.Minute, Now: now})
	require.NoError(t, err)
	require.True(t, r.Incomplete)
	fr, err := f.al.GetAgentLogFile(p)
	require.NoError(t, err)
	assert.Equal(t, CodexParserVersion, fr.ParserVersion)
	mid := fr.ReadOffset
	fi, err := os.Stat(p)
	require.NoError(t, err)
	require.Less(t, mid, fi.Size())

	// The next scan resumes at the slice's offset (no read from 0): the
	// re-read events are exactly the ones past it.
	r = f.scan()
	require.False(t, r.Incomplete)
	assert.Equal(t, 4, r.EventsWritten, "only the four calls past the stopped slice are read again")
	assert.Equal(t, want, codexSplit(t, f), "every row ends corrected")
}

// Every comparison with or stamp of a stored file's parser version goes
// through parserVersionFor (spec 2026-11-03 §4.7): a bare ParserVersion or
// CodexParserVersion anywhere else in the package's non-test files fails.
func TestParserVersionComparedOnlyThroughHelper(t *testing.T) {
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	fset := token.NewFileSet()
	var bad []string
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		require.NoError(t, err)
		for _, decl := range f.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "parserVersionFor" && fd.Recv == nil {
				continue
			}
			if gd, ok := decl.(*ast.GenDecl); ok && gd.Tok == token.CONST {
				continue // the declarations themselves
			}
			ast.Inspect(decl, func(n ast.Node) bool {
				if kv, ok := n.(*ast.KeyValueExpr); ok {
					ast.Inspect(kv.Value, func(m ast.Node) bool { return checkIdent(fset, m, &bad) })
					return false // the key is the File field's name
				}
				if sel, ok := n.(*ast.SelectorExpr); ok {
					ast.Inspect(sel.X, func(m ast.Node) bool { return checkIdent(fset, m, &bad) })
					return false // a field named ParserVersion (stored.ParserVersion) is not the constant
				}
				return checkIdent(fset, n, &bad)
			})
		}
	}
	assert.Empty(t, bad, "use parserVersionFor(agent)")
}

func checkIdent(fset *token.FileSet, n ast.Node, bad *[]string) bool {
	if id, ok := n.(*ast.Ident); ok && (id.Name == "ParserVersion" || id.Name == "CodexParserVersion") {
		*bad = append(*bad, fset.Position(id.Pos()).String())
	}
	return true
}
