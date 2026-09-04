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
