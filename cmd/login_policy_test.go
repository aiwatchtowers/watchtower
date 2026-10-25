package cmd

import (
	"errors"
	"os"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// TestPolicyLogin_RefusedBeforeAnyWrite pins that every command that
// connects a source refuses a source the organization's policy forbids,
// before any network call, browser or write: nothing appears in HOME.
func TestPolicyLogin_RefusedBeforeAnyWrite(t *testing.T) {
	cases := []struct {
		name string
		cmd  *cobra.Command
		src  string
	}{
		{"slack add", slackAddCmd, "slack"},
		{"slack login", slackLoginCmd, "slack"},
		{"google login", googleLoginCmd, "google"},
		{"google add", googleAddCmd, "google"},
		{"gmail login", gmailLoginCmd, "google"},
		{"calendar login", calendarLoginCmd, "google"},
		{"imap add", imapAddCmd, "imap"},
		{"outlook login", outlookLoginCmd, "imap"},
		{"caldav add", caldavAddCmd, "caldav"},
		{"caldav add-ics", caldavAddICSCmd, "caldav"},
		{"jira add", jiraAddCmd, "jira"},
		{"jira login", jiraLoginCmd, "jira"},
		{"linear add", linearAddCmd, "linear"},
		{"linear login", linearLoginCmd, "linear"},
	}
	policytest.Set(t, map[string]any{"AllowedSources": []any{}})
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			err := c.cmd.RunE(c.cmd, nil)
			require.Error(t, err)
			assert.True(t, errors.Is(err, policy.ErrNotAllowed), err.Error())
			assert.Contains(t, err.Error(), "source "+c.src+" is not allowed by your organization (allowed: none)")
			entries, err := os.ReadDir(home)
			require.NoError(t, err)
			assert.Empty(t, entries, "nothing is written")
		})
	}
}

func TestPolicyLogin_AllowedSourceReachesItsCommand(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"slack"}})
	called := false
	run := guardSource("slack", func(*cobra.Command, []string) error { called = true; return nil })
	require.NoError(t, run(&cobra.Command{}, nil))
	assert.True(t, called)

	called = false
	run = guardSource("google", func(*cobra.Command, []string) error { called = true; return nil })
	err := run(&cobra.Command{}, nil)
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "(allowed: slack)")
	assert.False(t, called)
}

func TestPolicyLogin_NoProfileRestrictsNothing(t *testing.T) {
	policytest.Set(t, nil)
	assert.NoError(t, refuseSourceByPolicy("linear"))
}

// A one-shot `watchtower sync` (and --users-only) syncs Slack in this
// process: a forbidden slack source is refused before anything opens.
func TestPolicySync_OneShotSlackRefused(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgFile := home + "/config.yaml"
	require.NoError(t, os.WriteFile(cfgFile, []byte("active_workspace: test\n"), 0o600))
	orig := flagConfig
	flagConfig = cfgFile
	t.Cleanup(func() { flagConfig = orig })

	err := runSync(&cobra.Command{}, nil)
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "source slack is not allowed by your organization (allowed: google)")
}
