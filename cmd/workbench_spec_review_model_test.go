package cmd

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"watchtower/internal/config"
	"watchtower/internal/specreview"

	"github.com/stretchr/testify/require"
)

func TestSpecReviewTranscriptModel_ExactMainModel(t *testing.T) {
	for _, tc := range []struct {
		name       string
		codex      bool
		body, want string
	}{
		{"codex latest", true, `{"type":"session_meta","payload":{"model":"old"}}
{"type":"turn_context","payload":{"model":"gpt-5.4-exact"}}
{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
`, "gpt-6.1-sol"},
		{"claude exact", false, `{"type":"assistant","message":{"model":"claude-opus-4-6"}}
{"type":"assistant","isSidechain":true,"message":{"model":"other"}}
{"type":"assistant","message":{"model":"<synthetic>"}}
`, "claude-opus-4-6"},
		{"no model", true, `{"type":"session_meta","payload":{}}
`, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "main.jsonl")
			require.NoError(t, os.WriteFile(path, []byte(tc.body), 0600))
			got, err := specReviewTranscriptModel(path, tc.codex)
			require.NoError(t, err)
			require.Equal(t, tc.want, got)
		})
	}
	_, err := specReviewTranscriptModel(filepath.Join(t.TempDir(), "missing"), true)
	require.Error(t, err, "read errors must not masquerade as missing model metadata")
}

func TestSpecReviewRun_UsesSessionModelAndRecordsDiscoveryFailure(t *testing.T) {
	for _, broken := range []bool{false, true} {
		t.Run(map[bool]string{false: "exact", true: "read failure"}[broken], func(t *testing.T) {
			database, id, repo := specReviewAsk(t)
			ask, err := database.GetOwnerAskByID(id)
			require.NoError(t, err)
			path := filepath.Join(t.TempDir(), "main.jsonl")
			if !broken {
				require.NoError(t, os.WriteFile(path, []byte(`{"type":"turn_context","payload":{"model":"gpt-5.4-exact"}}`+"\n"), 0600))
			}
			result, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_transcript_path) VALUES (?, 'codex', 'acme', ?, 'current-thread', ?)`, ask.WorkbenchID, repo, path)
			require.NoError(t, err)
			sid, err := result.LastInsertId()
			require.NoError(t, err)
			_, err = database.Exec(`UPDATE owner_asks SET session_id = ? WHERE id = ?`, sid, id)
			require.NoError(t, err)
			original := &config.Config{AI: config.AIConfig{Provider: "claude", Models: config.AIModels{Strong: "claude-opus-exact"}}}
			chosen, model, selectionErr := specReviewSessionConfig(context.Background(), database, id, original)
			require.Equal(t, "codex", chosen.AI.Provider)
			require.Equal(t, "claude", original.AI.Provider)
			if !broken {
				require.NoError(t, selectionErr)
				require.Equal(t, "gpt-5.4-exact", model)
			} else {
				require.Error(t, selectionErr)
			}
			old := specReviewAgentFactory
			calls := 0
			specReviewAgentFactory = func(cfg *config.Config, exact string) specreview.Agent {
				calls++
				require.Equal(t, "codex", cfg.AI.Provider)
				require.Equal(t, "gpt-5.4-exact", exact)
				return &fakeSpecReviewAgent{out: `{"summary":"Looks right.","agreements":[],"decided_alone":[],"blind_spots":[],"checks":[],"resolved":[],"notes":[]}`}
			}
			t.Cleanup(func() { specReviewAgentFactory = old })
			_, err = runSpecReview(t, "run", "--ask", itoa(id))
			row, readErr := database.GetSpecReview(id)
			require.NoError(t, readErr)
			if broken {
				require.Error(t, err)
				require.Equal(t, "failed", row.Status)
				require.Zero(t, calls)
			} else {
				require.NoError(t, err)
				require.Equal(t, "done", row.Status)
				require.Equal(t, "codex", row.Provider)
				require.Equal(t, "gpt-5.4-exact", row.Model)
			}
		})
	}
}

func TestSpecReviewTranscriptModel_ModelBeforeLongTurn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "long.jsonl")
	file, err := os.Create(path)
	require.NoError(t, err)
	writer := bufio.NewWriter(file)
	_, err = writer.WriteString(`{"type":"turn_context","payload":{"model":"gpt-5.4-exact"}}` + "\n")
	require.NoError(t, err)
	line := `{"type":"event_msg","payload":{"text":"` + strings.Repeat("x", 4096) + `"}}` + "\n"
	for n := 0; n < 65*1024*1024/len(line)+1; n++ {
		_, err = writer.WriteString(line)
		require.NoError(t, err)
	}
	require.NoError(t, writer.Flush())
	require.NoError(t, file.Close())
	model, err := specReviewTranscriptModel(path, true)
	require.NoError(t, err)
	require.Equal(t, "gpt-5.4-exact", model)
}

func TestSpecReviewRun_ClaudeDiscoveryFailureIsStored(t *testing.T) {
	database, id, repo := specReviewAsk(t)
	ask, err := database.GetOwnerAskByID(id)
	require.NoError(t, err)
	sid := reviewSession(t, database, ask.WorkbenchID, repo)
	_, err = database.Exec(`UPDATE owner_asks SET session_id=? WHERE id=?`, sid, id)
	require.NoError(t, err)
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "projects"), []byte("not a directory"), 0600))
	old := agentsClaudeDir
	agentsClaudeDir = func() string { return home }
	t.Cleanup(func() { agentsClaudeDir = old })
	_, err = runSpecReview(t, "run", "--ask", itoa(id))
	require.Error(t, err)
	row, err := database.GetSpecReview(id)
	require.NoError(t, err)
	require.Equal(t, "failed", row.Status)
}
