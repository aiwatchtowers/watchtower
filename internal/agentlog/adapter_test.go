package agentlog

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/sessionagent"
)

// fakeCodexAdapter is the codex adapter with its Transcript replaced: every
// rollout the importer reads must come through it.
type fakeCodexAdapter struct {
	sessionagent.Adapter
	path     string
	rows     []sessionagent.Row
	opens    []string
	children []string // ChildImportFile ids asked (none is ever found)
}

func (a *fakeCodexAdapter) Transcript(row sessionagent.Row) sessionagent.Transcript {
	a.rows = append(a.rows, row)
	return fakeTranscript{a: a}
}

type fakeTranscript struct{ a *fakeCodexAdapter }

func (fakeTranscript) OwnerText(int) (string, error) { return "", nil }

func (t fakeTranscript) ImportFile() (string, bool) { return t.a.path, true }

func (t fakeTranscript) ChildImportFile(id string, _ []string) (string, bool, error) {
	t.a.children = append(t.a.children, id)
	return "", false, nil
}

func (t fakeTranscript) Open(path string) (io.ReadCloser, bool, error) {
	t.a.opens = append(t.a.opens, path)
	f, err := os.Open(path)
	return f, false, err
}

// TestAgentlog_CodexImportGoesThroughAdapterTranscript: the importer finds
// and opens codex rollouts only through the session adapter's Transcript
// (spec 2026-11-05 §3.5, plan Task A5 Step 2b). The fake adapter's fixture
// is the only source read: a decoy rollout where the real discovery would
// look is never opened.
func TestAgentlog_CodexImportGoesThroughAdapterTranscript(t *testing.T) {
	f := newFixture(t)
	codex, ok := sessionagent.For(agentkind.Codex)
	require.True(t, ok)
	fixture := filepath.Join(t.TempDir(), "rollout-2026-11-01T10-00-00-"+cxParent+".jsonl")
	require.NoError(t, os.WriteFile(fixture, []byte(cxSession(t, cxParent, f.folder)), 0o600))
	decoy := f.writeRollout(cxParent, strings.ReplaceAll(cxSession(t, cxParent, f.folder), "gpt-test", "gpt-decoy"))
	require.NoError(t, os.Chmod(decoy, 0o000), "opening the decoy would fail the file")
	f.codexRow(f.wb, cxParent, f.folder, decoy)

	fake := &fakeCodexAdapter{Adapter: codex, path: fixture}
	sessions := func(k sessionagent.Kind) (sessionagent.Adapter, bool) {
		if k == agentkind.Codex {
			return fake, true
		}
		return sessionagent.For(k)
	}
	r, err := Scan(t.Context(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, CodexHome: f.codex, Sessions: sessions})
	require.NoError(t, err)
	assert.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs())
	require.Len(t, fake.rows, 1)
	assert.Equal(t, sessionagent.Row{SessionID: cxParent, TranscriptPath: decoy, Home: f.codex}, fake.rows[0])
	require.NotEmpty(t, fake.opens)
	for _, p := range fake.opens {
		assert.Equal(t, fixture, p)
	}
	var model string
	require.NoError(t, f.al.QueryRow(`SELECT model FROM agent_log_sessions WHERE session_uuid = ?`, cxParent).Scan(&model))
	assert.Equal(t, "gpt-test", model)
}

// TestAgentlog_NoInterimRolloutDiscovery: internal/agentlog keeps no codex
// rollout discovery of its own (G8's interim CodexTranscripts) and never
// opens a rollout directly; both are the session adapter's (A5).
func TestAgentlog_NoInterimRolloutDiscovery(t *testing.T) {
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	fset := token.NewFileSet()
	banned := map[string]bool{"CodexTranscripts": true, "locateCodexRollout": true, "noSymlinkBelow": true}
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.SkipObjectResolution)
		require.NoError(t, err)
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncDecl:
				assert.False(t, banned[n.Name.Name], "%s declares %s: rollout discovery is the session adapter's", name, n.Name.Name)
			case *ast.CallExpr:
				if id, ok := n.Fun.(*ast.Ident); ok && banned[id.Name] {
					t.Errorf("%s calls %s: find rollouts through sessionagent.Adapter.Transcript", name, id.Name)
				}
				if sel, ok := n.Fun.(*ast.SelectorExpr); ok {
					if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "rollout" && sel.Sel.Name == "Open" {
						t.Errorf("%s calls rollout.Open: open rollouts through the Transcript", name)
					}
				}
			}
			return true
		})
	}
}

// A rollout the adapter located but the importer cannot stat is counted:
// gone in between = missing; any other stat error = a failed file naming
// the session, never the path (FILES-01).
func TestAgentlog_CodexRolloutStatFailureCounted(t *testing.T) {
	codex, ok := sessionagent.For(agentkind.Codex)
	require.True(t, ok)
	scanWith := func(f *fixture, path string) *Result {
		fake := &fakeCodexAdapter{Adapter: codex, path: path}
		sessions := func(k sessionagent.Kind) (sessionagent.Adapter, bool) {
			if k == agentkind.Codex {
				return fake, true
			}
			return sessionagent.For(k)
		}
		r, err := Scan(t.Context(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, CodexHome: f.codex, Sessions: sessions})
		require.NoError(t, err)
		return r
	}
	t.Run("gone", func(t *testing.T) {
		f := newFixture(t)
		f.codexRow(f.wb, cxParent, f.folder, "")
		r := scanWith(f, filepath.Join(t.TempDir(), "rollout-2026-11-01T10-00-00-"+cxParent+".jsonl"))
		assert.Equal(t, 1, r.CodexRolloutsMissing)
		assert.Zero(t, r.FailedFiles)
	})
	t.Run("unreadable folder", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root stats through a mode-000 folder")
		}
		f := newFixture(t)
		f.codexRow(f.wb, cxParent, f.folder, "")
		dir := t.TempDir()
		p := filepath.Join(dir, "rollout-2026-11-01T10-00-00-"+cxParent+".jsonl")
		require.NoError(t, os.WriteFile(p, []byte(cxSession(t, cxParent, f.folder)), 0o600))
		require.NoError(t, os.Chmod(dir, 0))
		t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
		r := scanWith(f, p)
		require.Equal(t, 1, r.FailedFiles)
		msg := r.FirstFailure.Error()
		assert.Contains(t, msg, cxParent)
		assert.NotContains(t, msg, dir)
		assert.ErrorIs(t, r.FirstFailure, fs.ErrPermission)
	})
}
