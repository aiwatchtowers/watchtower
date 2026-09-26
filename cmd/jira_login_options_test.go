package cmd

import (
	"testing"

	"watchtower/internal/jira"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// jiraLoginFlagsCmd builds a bare *cobra.Command carrying the three flags
// runJiraLogin/runJiraAdd register on the real jiraLoginCmd/jiraAddCmd —
// jiraLoginOptionsFromFlags only reads from cmd.Flags(), so this is enough
// to exercise it without any DB/network setup.
func jiraLoginFlagsCmd(t *testing.T) *cobra.Command {
	t.Helper()
	cmd := &cobra.Command{Use: "test"}
	cmd.Flags().Bool("no-open", false, "")
	cmd.Flags().Bool("app-return", false, "")
	cmd.Flags().Bool("with-confluence", false, "")
	return cmd
}

// TestJiraLoginOptionsFromFlags_DefaultExcludesConfluence pins the opt-in
// ruling at the flag-parsing boundary: with --with-confluence left at its
// default (false), the LoginOptions handed to jira.Login must not set
// WithConfluence — exactly the pre-Confluence-connector behavior. Combined
// with internal/jira's TestLogin_ScopeReflectsWithConfluence (which pins
// LoginOptions.WithConfluence -> the requested auth URL scope), this closes
// the loop from the CLI flag all the way to the scope Atlassian is asked
// for, without needing a network-mocking seam inside the cmd package (there
// is none: jira.Login talks to a hardcoded package-level token/auth
// endpoint var that only internal/jira's own tests can override).
func TestJiraLoginOptionsFromFlags_DefaultExcludesConfluence(t *testing.T) {
	cmd := jiraLoginFlagsCmd(t)

	opts := jiraLoginOptionsFromFlags(cmd)
	assert.Equal(t, jira.LoginOptions{}, opts)
}

func TestJiraLoginOptionsFromFlags_WithConfluenceFlagReaches(t *testing.T) {
	cmd := jiraLoginFlagsCmd(t)
	require.NoError(t, cmd.Flags().Set("with-confluence", "true"))
	require.NoError(t, cmd.Flags().Set("no-open", "true"))
	require.NoError(t, cmd.Flags().Set("app-return", "true"))

	opts := jiraLoginOptionsFromFlags(cmd)
	assert.Equal(t, jira.LoginOptions{SkipBrowserOpen: true, AppReturn: true, WithConfluence: true}, opts)
}

// TestJiraCmds_HaveWithConfluenceFlag guards against the flag being wired
// into jiraLoginOptionsFromFlags but never actually registered on the real
// commands (cmd.Flags().GetBool silently returns false, "", 0 for an unknown
// flag name — a registration gap here would otherwise fail silently at
// runtime instead of at build/test time).
func TestJiraCmds_HaveWithConfluenceFlag(t *testing.T) {
	assert.NotNil(t, jiraLoginCmd.Flags().Lookup("with-confluence"))
	assert.NotNil(t, jiraAddCmd.Flags().Lookup("with-confluence"))
}
