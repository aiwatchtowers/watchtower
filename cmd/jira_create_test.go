package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func runJira(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"jira"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	jiraFlagAccount = 0
	jiraCreateFlagProject = ""
	jiraCreateFlagType = ""
	jiraCreateFlagSummary = ""
	jiraCreateFlagDescription = ""
	jiraCreateFlagPriority = ""
	jiraCreateFlagJSON = false
	jiraCreateFlagLabels = nil
	return out.String(), err
}

func TestJiraCreate_ValidatesBeforeTouchingJira(t *testing.T) {
	writeActionsConfig(t) // no Jira account connected
	out, err := runJira(t, "create", "--project", "ABC", "--type", "Task", "--summary", "s", "--json")
	require.Error(t, err)
	assert.Contains(t, out+err.Error(), "no Jira site")
}

func TestJiraCreate_ReadsDescriptionFile(t *testing.T) {
	writeActionsConfig(t)
	path := filepath.Join(t.TempDir(), "d.txt")
	require.NoError(t, os.WriteFile(path, []byte("body"), 0o600))

	// A readable file gets past the read and dies where every run without a
	// connected site dies — which is what proves the file WAS read: an
	// unreadable path never reaches the account lookup at all.
	_, err := runJira(t, "create", "--project", "ABC", "--type", "Task", "--summary", "s", "--description-file", path)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no Jira site")
	assert.NotContains(t, err.Error(), "description-file")

	_, err = runJira(t, "create", "--project", "ABC", "--type", "Task", "--summary", "s", "--description-file", "/nonexistent")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "description-file")
}

func TestRenderJiraCreateResult_WithoutWarning(t *testing.T) {
	envelope, lines := renderJiraCreateResult(map[string]any{"key": "ABC-1", "url": "https://x/browse/ABC-1"})
	assert.Equal(t, map[string]any{"ok": true, "key": "ABC-1", "url": "https://x/browse/ABC-1"}, envelope)
	assert.Equal(t, []string{"Created ABC-1 — https://x/browse/ABC-1"}, lines)
}

func TestRenderJiraCreateResult_WithWarningSurfacesOnBothFaces(t *testing.T) {
	res := map[string]any{"key": "ABC-1", "url": "https://x/browse/ABC-1", "warning": "created, but the local mirror was not updated: boom"}
	envelope, lines := renderJiraCreateResult(res)
	assert.Equal(t, "created, but the local mirror was not updated: boom", envelope["warning"])
	assert.Equal(t, true, envelope["ok"])
	require.Len(t, lines, 2)
	assert.Equal(t, "Warning: created, but the local mirror was not updated: boom", lines[1])
}
