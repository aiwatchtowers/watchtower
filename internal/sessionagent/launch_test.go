package sessionagent

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const launchTestID = "0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6"

// Claude Code takes the id the app chose (--session-id); Codex mints its own
// and its first SessionStart reports it.
func TestSessionAgent_AppSessionID(t *testing.T) {
	assert.True(t, claudeAdapter{}.Caps().AppSessionID)
	assert.False(t, codexAdapter{}.Caps().AppSessionID)
}

// A Claude Code transcript records the context parts and the skill listing
// the Analytics Context and Skills blocks read; a Codex rollout does not.
func TestSessionAgent_AnalyticsContext(t *testing.T) {
	assert.True(t, claudeAdapter{}.Caps().AnalyticsContext)
	assert.False(t, codexAdapter{}.Caps().AnalyticsContext)
	assert.True(t, claudeAdapter{}.Caps().ScratchpadLanes)
	assert.False(t, codexAdapter{}.Caps().ScratchpadLanes)
}

// Each adapter's start command is the one sessionstart.Launch built by kind
// (testdata/launch_cases.json pins the whole launch on both sides).
func TestSessionAgent_LaunchCommand(t *testing.T) {
	prompt := "-fix it"
	binary := &LaunchArgs{Binary: "/opt/codex", PathPrepend: "/opt/node", Args: []string{"-c", "a='b'"}}
	for _, tc := range []struct {
		name  string
		a     Adapter
		start Start
		want  LaunchCommand
	}{
		{"claude new", claudeAdapter{}, Start{SessionID: launchTestID},
			LaunchCommand{Command: "exec claude --session-id " + launchTestID, Runs: true}},
		{"claude new with a prompt", claudeAdapter{}, Start{SessionID: launchTestID, Prompt: &prompt},
			LaunchCommand{Command: "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id " +
				launchTestID + ` "$WATCHTOWER_FIRST_PROMPT"'`, Prompt: new(" -fix it"), Runs: true}},
		{"claude resume", claudeAdapter{}, Start{SessionID: launchTestID, Resume: true},
			LaunchCommand{Command: "exec claude --resume " + launchTestID, Runs: true}},
		{"codex without its binary", codexAdapter{}, Start{Prompt: &prompt},
			LaunchCommand{Command: "exit 127", Prompt: &prompt}},
		{"codex new with a prompt", codexAdapter{}, Start{Prompt: &prompt, Binary: binary},
			LaunchCommand{Command: `exec /bin/sh -c 'eval "$WATCHTOWER_CODEX_COMMAND"'`,
				Env: []string{`WATCHTOWER_CODEX_COMMAND=PATH='/opt/node':"$PATH" exec env -u WATCHTOWER_FIRST_PROMPT ` +
					`-u WATCHTOWER_CODEX_COMMAND '/opt/codex' '-c' 'a='\''b'\''' -- "$WATCHTOWER_FIRST_PROMPT"`},
				Prompt: &prompt, Runs: true}},
		{"codex resume", codexAdapter{}, Start{SessionID: launchTestID, Resume: true, Binary: &LaunchArgs{Binary: "codex"}},
			LaunchCommand{Command: `exec /bin/sh -c 'eval "$WATCHTOWER_CODEX_COMMAND"'`,
				Env: []string{"WATCHTOWER_CODEX_COMMAND=exec env -u WATCHTOWER_FIRST_PROMPT -u WATCHTOWER_CODEX_COMMAND " +
					"'codex' resume '" + launchTestID + "'"},
				Runs: true}},
	} {
		assert.Equal(t, tc.want, tc.a.LaunchCommand(tc.start), tc.name)
	}
}

// LoadSession reads the stored transcript path only for an agent whose
// SessionStart path Watchtower keeps (Codex); a Claude row's stays unread,
// as GetTerminalSession left it before (Claude readers find the transcript
// by id).
func TestSessionAgent_LoadSessionReadsTheStoredPathByAdapter(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	insert := func(kind, sid string) int64 {
		res, err := d.Exec(`INSERT INTO terminal_sessions (kind, title, title_source, folder_path, claude_session_id,
			agent_transcript_path) VALUES (?, 't', 'auto', '/Users/example/acme', ?, '/Users/example/r.jsonl')`, kind, sid)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	codex, claude := insert("codex", launchTestID), insert("claude", launchTestID)

	s, err := LoadSession(d, codex)
	require.NoError(t, err)
	assert.Equal(t, "/Users/example/r.jsonl", s.TranscriptPath.String)
	s, err = LoadSession(d, claude)
	require.NoError(t, err)
	assert.False(t, s.TranscriptPath.Valid)
	_, err = LoadSession(d, 999)
	assert.ErrorIs(t, err, db.ErrTerminalSessionNotFound)
}

// The phone's not-found reason and message for a start whose binary is
// missing: the wire values the Kit's ActionReason decodes, and the
// Desktop's TerminalLaunch.exitMessage(code: 127) copy.
func TestSessionAgent_NotFound(t *testing.T) {
	assert.Equal(t, "claude_not_found", claudeAdapter{}.NotFoundReason())
	assert.Equal(t, "codex_not_found", codexAdapter{}.NotFoundReason())
	assert.Equal(t, "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart.",
		claudeAdapter{}.NotFoundMessage())
	assert.Equal(t, "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again.",
		codexAdapter{}.NotFoundMessage())
}
