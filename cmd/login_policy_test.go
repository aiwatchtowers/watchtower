package cmd

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// TestPolicyLogin_RefusedBeforeAnyWrite pins that the commands that
// connect, re-enable or fetch a source refuse a source the organization's
// policy forbids, before any network call, browser or write: nothing
// appears in HOME.
func TestPolicyLogin_RefusedBeforeAnyWrite(t *testing.T) {
	cases := []struct {
		path string
		src  string
	}{
		{"auth login", "slack"}, {"reaction-commands poll", "slack"}, {"slack add", "slack"}, {"slack login", "slack"}, {"slack enable", "slack"},
		{"google login", "google"}, {"google add", "google"}, {"gmail login", "google"}, {"gmail sync", "google"},
		{"calendar login", "google"}, {"calendar sync", "google"},
		{"imap add", "imap"}, {"outlook login", "imap"},
		{"caldav add", "caldav"}, {"caldav add-ics", "caldav"},
		{"jira add", "jira"}, {"jira login", "jira"}, {"jira enable", "jira"}, {"jira sync", "jira"},
		{"confluence sync", "jira"}, {"confluence access", "jira"},
		{"linear add", "linear"}, {"linear login", "linear"}, {"linear enable", "linear"}, {"linear sync", "linear"},
	}
	policytest.Set(t, map[string]any{"AllowedSources": []any{}})
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			cmd, _, err := rootCmd.Find(strings.Fields(c.path))
			require.NoError(t, err)
			require.Equal(t, c.path, sourceCommandKey(cmd))
			home := t.TempDir()
			t.Setenv("HOME", home)
			err = cmd.RunE(cmd, nil)
			require.Error(t, err)
			assert.True(t, errors.Is(err, policy.ErrNotAllowed), err.Error())
			assert.Contains(t, err.Error(), "source "+c.src+" is not allowed by your organization (allowed: none)")
			entries, err := os.ReadDir(home)
			require.NoError(t, err)
			assert.Empty(t, entries, "nothing is written")
		})
	}
}

// TestPolicyLogin_EverySourceCommandIsGuarded walks the command tree: every
// runnable command of a source group is guarded unless it is on the
// explicit exempt list (local reads and settings, taking an account away),
// and every exempt entry names a real command. A new subcommand is guarded
// by default; exempting one is a deliberate edit here.
func TestPolicyLogin_EverySourceCommandIsGuarded(t *testing.T) {
	applySourceGuards()
	seen := map[string]bool{}
	var walk func(c *cobra.Command, src string)
	walk = func(c *cobra.Command, src string) {
		key := sourceCommandKey(c)
		if c.RunE != nil {
			seen[key] = true
			if !sourceGuardExempt[key] {
				assert.Equal(t, src, sourceGuarded[c], "%q is not guarded", key)
			}
		}
		for _, sub := range c.Commands() {
			walk(sub, src)
		}
	}
	for _, c := range rootCmd.Commands() {
		if src, ok := sourceCommandGroups[c.Name()]; ok {
			walk(c, src)
		}
	}
	for key := range sourceGuardExempt {
		assert.True(t, seen[key], "exempt %q is not a runnable source command", key)
	}
	for _, group := range []string{"auth", "reaction-commands", "slack", "google", "gmail", "calendar", "imap", "outlook", "caldav", "jira", "confluence", "linear"} {
		_, ok := sourceCommandGroups[group]
		assert.True(t, ok, group)
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

	policytest.Set(t, nil)
	require.NoError(t, run(&cobra.Command{}, nil), "no profile restricts nothing")
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

// The assistant's tool clients refuse a source the policy forbids before
// any token is read (#608): one check per factory.
func TestPolicyToolFactories_RefuseForbiddenSource(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})
	cfg := &config.Config{ActiveWorkspace: "test"}
	t.Setenv("HOME", t.TempDir())
	jiraAcct := db.JiraAccount{ID: 1, CloudID: "cloud-1"}

	_, err := jiraClientFactory(cfg)(jiraAcct)
	require.ErrorIs(t, err, policy.ErrNotAllowed, "jira create")
	_, err = jiraWriteClientFactory(cfg)(jiraAcct)
	require.ErrorIs(t, err, policy.ErrNotAllowed, "jira writes")
	_, err = confluencePageClientFactory(cfg)(jiraAcct)
	require.ErrorIs(t, err, policy.ErrNotAllowed, "confluence pages")
	_, err = jiraConnectFactory(cfg, nil)(jiraAcct)
	require.ErrorIs(t, err, policy.ErrNotAllowed, "jira connect")
	_, err = linearWriteClientFactory(cfg, nil)(db.LinearAccount{ID: 1})
	require.ErrorIs(t, err, policy.ErrNotAllowed, "linear writes")
	_, _, err = slackSenderFactory(cfg)(db.SlackAccount{ID: 1})
	require.ErrorIs(t, err, policy.ErrNotAllowed, "slack send")
	assert.Contains(t, err.Error(), "source slack is not allowed by your organization (allowed: google)")
}

// testPolicyEnv hands a runCLIEnv subprocess its forced policy (TestMain).
const testPolicyEnv = "WATCHTOWER_TEST_POLICY_JSON"

// TestPolicyLogin_RealExecuteAppliesGuards runs the test binary as the real
// CLI, where TestMain applies nothing: cobra's initializer must guard the
// command on the plain Execute path.
func TestPolicyLogin_RealExecuteAppliesGuards(t *testing.T) {
	c := exec.Command(os.Args[0], "auth", "login")
	c.Env = append(os.Environ(), runCLIEnv+"=1", "HOME="+t.TempDir(), testPolicyEnv+`={"AllowedSources":["google"]}`)
	out, err := c.CombinedOutput()
	require.Error(t, err, string(out))
	assert.Contains(t, string(out), "source slack is not allowed by your organization (allowed: google)")
}

// main installs the system reader; nothing else does (tests never read this
// Mac's managed preferences).
func TestPolicy_MainInstallsTheSystemReader(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "main.go"))
	require.NoError(t, err)
	assert.Contains(t, string(b), "policy.UseSystemReader()")
}

func TestPolicySync_UsersOnlySlackRefused(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgFile := filepath.Join(home, "config.yaml")
	require.NoError(t, os.WriteFile(cfgFile, []byte("active_workspace: test\n"), 0o600))
	orig, origUsers := flagConfig, syncFlagUsersOnly
	flagConfig, syncFlagUsersOnly = cfgFile, true
	t.Cleanup(func() { flagConfig, syncFlagUsersOnly = orig, origUsers })

	err := runSync(&cobra.Command{}, nil)
	require.ErrorIs(t, err, policy.ErrNotAllowed)
}
