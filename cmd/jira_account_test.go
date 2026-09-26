package cmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// --- resolveJiraAccount: the --account flag contract ---

// Nothing connected: the error has to name the command that fixes it, since
// this is what every jira subcommand shows on a fresh install.
func TestResolveJiraAccount_NoAccountsPointsAtAdd(t *testing.T) {
	database := db.OpenTestDB(t)

	_, err := resolveJiraAccount(database, 0)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "watchtower jira add")
}

// The single-site install must keep working without ever typing --account.
func TestResolveJiraAccount_SingleEnabledIsAutoPicked(t *testing.T) {
	database := db.OpenTestDB(t)
	id := db.SeedTestJiraAccount(t, database)

	account, err := resolveJiraAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, id, account.ID)
}

// Two connected sites are ambiguous: picking one silently would sync the wrong
// site, so the command stops and names the flag.
func TestResolveJiraAccount_MultipleEnabledRequireExplicitFlag(t *testing.T) {
	database := db.OpenTestDB(t)
	db.SeedTestJiraAccount(t, database)
	db.SeedTestJiraAccount(t, database)

	_, err := resolveJiraAccount(database, 0)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--account")
}

// An explicit id wins over the ambiguity — that is the whole point of the flag.
func TestResolveJiraAccount_ExplicitIDSelectsThatAccount(t *testing.T) {
	database := db.OpenTestDB(t)
	db.SeedTestJiraAccount(t, database)
	second := db.SeedTestJiraAccount(t, database)

	account, err := resolveJiraAccount(database, second)
	require.NoError(t, err)
	assert.Equal(t, second, account.ID)
}

// A removed account has no token left, so naming it explicitly must be refused
// rather than run a command that can only fail at Atlassian. Pre-fix this
// returned the row and the command went on to a doomed API call.
func TestResolveJiraAccount_ExplicitRemovedIsRefused(t *testing.T) {
	database := db.OpenTestDB(t)
	id := db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.SetJiraAccountRemoved(id))

	_, err := resolveJiraAccount(database, id)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "removed")
	assert.Contains(t, err.Error(), "watchtower jira add")
}

// --- resolveJiraAccountForLogin: which account a bare `jira login` re-consents ---

// A legacy token-only install resolves to the account the seed just minted;
// the login path takes the seed's own id instead of re-listing rows behind it.
func TestResolveJiraAccountForLogin_UsesSeededLegacyAccount(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	writeLegacyJiraToken(t, wsDir)

	id, isNewRow, err := resolveJiraAccountForLogin(cfg, database, 0, quietTestLogger())
	require.NoError(t, err)
	assert.False(t, isNewRow, "a seeded legacy row is not a new row")

	account, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-legacy", account.CloudID)
}

// The very first Jira login ever: nothing to seed, nothing to list, so the row
// is created and flagged new (the rollback path depends on that flag).
func TestResolveJiraAccountForLogin_FirstEverLoginCreatesAccount(t *testing.T) {
	cfg, database, _ := legacyJiraFixture(t)

	id, isNewRow, err := resolveJiraAccountForLogin(cfg, database, 0, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)
	assert.True(t, isNewRow)

	accounts, err := database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1)
}

// --- setJiraAccountEnabled: `jira enable` / `jira disable` ---

// jiraCmdFixture points the command preamble at a temp config + HOME and
// returns the workspace DB, so command-level helpers that call openJiraCmdDB
// can be exercised end to end.
func jiraCmdFixture(t *testing.T) *db.DB {
	t.Helper()
	t.Setenv("HOME", t.TempDir())

	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	old := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = old })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func newQuietJiraCmd() *cobra.Command {
	cmd := &cobra.Command{}
	cmd.SetOut(io.Discard)
	cmd.SetErr(io.Discard)
	return cmd
}

// Re-enabling a removed account would resume syncing a site whose token was
// deleted — the daemon would just paint it red again. Pre-fix the toggle
// flipped enabled=1 and reported success.
func TestSetJiraAccountEnabled_RefusesRemovedAccount(t *testing.T) {
	database := jiraCmdFixture(t)
	id := db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.SetJiraAccountRemoved(id))

	err := setJiraAccountEnabled(newQuietJiraCmd(), "1", true)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "watchtower jira add")

	account, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.False(t, account.Enabled, "a refused enable must not flip the row")
}

// The ordinary path still works: a live account toggles off and back on.
func TestSetJiraAccountEnabled_TogglesLiveAccount(t *testing.T) {
	database := jiraCmdFixture(t)
	id := db.SeedTestJiraAccount(t, database)

	require.NoError(t, setJiraAccountEnabled(newQuietJiraCmd(), "1", false))
	account, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.False(t, account.Enabled)

	require.NoError(t, setJiraAccountEnabled(newQuietJiraCmd(), "1", true))
	account, err = database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.True(t, account.Enabled)
}

// --- selectJiraSite: which Atlassian site a grant lands on ---

func twoJiraSites() []jira.CloudResource {
	return []jira.CloudResource{
		{ID: "cloud-a", URL: "https://alpha.atlassian.net", Name: "Alpha"},
		{ID: "cloud-b", URL: "https://beta.atlassian.net", Name: "Beta"},
	}
}

// newSelectSiteCmd captures stdout and feeds a fixed stdin, so the prompt
// branches are deterministic instead of reading the test runner's stdin.
func newSelectSiteCmd(stdin string) (*cobra.Command, *bytes.Buffer) {
	cmd := &cobra.Command{}
	out := &bytes.Buffer{}
	cmd.SetOut(out)
	cmd.SetErr(io.Discard)
	cmd.SetIn(strings.NewReader(stdin))
	return cmd, out
}

// --site matches on a substring of either the URL or the display name.
func TestSelectJiraSite_SiteFlagMatchesSubstring(t *testing.T) {
	cmd, _ := newSelectSiteCmd("")

	site, err := selectJiraSite(cmd, twoJiraSites(), "beta", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-b", site.ID)

	site, err = selectJiraSite(cmd, twoJiraSites(), "Alpha", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-a", site.ID)
}

// A --site that matches nothing errors and prints what was available, so the
// user can retype the flag without re-running the OAuth flow blind.
func TestSelectJiraSite_SiteFlagNoMatchErrorsAndListsSites(t *testing.T) {
	cmd, out := newSelectSiteCmd("")

	_, err := selectJiraSite(cmd, twoJiraSites(), "gamma", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "gamma")
	assert.Contains(t, out.String(), "https://alpha.atlassian.net")
	assert.Contains(t, out.String(), "https://beta.atlassian.net")
}

// Re-login with the account's site in the grant: no prompt, no output, the
// same site comes back.
func TestSelectJiraSite_PreferredCloudIDShortCircuits(t *testing.T) {
	cmd, out := newSelectSiteCmd("1\n")

	site, err := selectJiraSite(cmd, twoJiraSites(), "", "cloud-b")
	require.NoError(t, err)
	assert.Equal(t, "cloud-b", site.ID)
	assert.Empty(t, out.String(), "a resolved re-login must not prompt")
}

// Pins F3. Re-login whose grant reaches exactly ONE site, and it is not the
// account's: pre-fix the single-resource auto-pick silently re-pointed the
// account (and every issue/board synced under it) at the other site. It must
// error instead, naming the expected cloud id and the sites actually granted.
func TestSelectJiraSite_PreferredCloudIDMissingIsRefused(t *testing.T) {
	cmd, _ := newSelectSiteCmd("")
	other := []jira.CloudResource{{ID: "cloud-other", URL: "https://other.atlassian.net", Name: "Other"}}

	_, err := selectJiraSite(cmd, other, "", "cloud-a")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cloud-a", "the error must name the site that was expected")
	assert.Contains(t, err.Error(), "https://other.atlassian.net", "the error must list what the grant does reach")
	assert.Contains(t, err.Error(), "--site")
}

// Same miss with several sites granted: still an error, never the interactive
// prompt — a re-login must not offer to move the account by accident.
func TestSelectJiraSite_PreferredCloudIDMissingDoesNotPrompt(t *testing.T) {
	cmd, out := newSelectSiteCmd("1\n")

	_, err := selectJiraSite(cmd, twoJiraSites(), "", "cloud-missing")
	require.Error(t, err)
	assert.Empty(t, out.String(), "a refused re-login must not print the selection prompt")
}

// The deliberate move is still possible: --site is matched before the
// preferred-site check, so an explicit flag re-points the account on purpose.
func TestSelectJiraSite_SiteFlagOverridesPreferredCloudID(t *testing.T) {
	cmd, _ := newSelectSiteCmd("")

	site, err := selectJiraSite(cmd, twoJiraSites(), "beta", "cloud-a")
	require.NoError(t, err)
	assert.Equal(t, "cloud-b", site.ID)
}

// `jira add` (no preferred site) against a one-site grant needs no prompt.
func TestSelectJiraSite_SingleResourceAutoPicksOnAdd(t *testing.T) {
	cmd, out := newSelectSiteCmd("")
	only := []jira.CloudResource{{ID: "cloud-only", URL: "https://only.atlassian.net", Name: "Only"}}

	site, err := selectJiraSite(cmd, only, "", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-only", site.ID)
	assert.Empty(t, out.String())
}

// The interactive prompt still picks by number when a terminal is attached.
func TestSelectJiraSite_PromptSelectsByNumber(t *testing.T) {
	cmd, _ := newSelectSiteCmd("2\n")

	site, err := selectJiraSite(cmd, twoJiraSites(), "", "")
	require.NoError(t, err)
	assert.Equal(t, "cloud-b", site.ID)
}

// The Desktop "Add Jira Site" sheet spawns the CLI without a terminal: the
// error has to inline the site URLs, because the sheet shows only stderr and
// never the printed list.
func TestSelectJiraSite_NoStdinListsSitesInError(t *testing.T) {
	cmd, _ := newSelectSiteCmd("")

	_, err := selectJiraSite(cmd, twoJiraSites(), "", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--site")
	assert.Contains(t, err.Error(), "https://alpha.atlassian.net")
	assert.Contains(t, err.Error(), "https://beta.atlassian.net")
}
