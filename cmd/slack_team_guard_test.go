package cmd

import (
	"bytes"
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// teamGuardEnv is an install whose account #1 holds the home team's data
// (the legacy workspace row names it) and has a token file for it.
type teamGuardEnv struct {
	cfg *config.Config
	db  *db.DB
	id  int64
}

func newTeamGuardEnv(t *testing.T, rowTeamID, rowTeamName string) teamGuardEnv {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "Acme"}))
	id, err := database.CreateSlackAccount(db.SlackAccount{Label: "Acme"})
	require.NoError(t, err)
	require.NoError(t, database.UpdateSlackAccountConnection(id, rowTeamID, rowTeamName, "", "1:U_OWNER"))
	require.NoError(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Save(
		&watchtowerslack.Token{AccessToken: "xoxp-old", TeamID: rowTeamID}))
	return teamGuardEnv{cfg: cfg, db: database, id: id}
}

func (e teamGuardEnv) connect(t *testing.T) (slackIdentity, error) {
	t.Helper()
	identity, _, err := e.connectWarnings(t)
	return identity, err
}

// connectWarnings is connect returning what it printed as warnings.
func (e teamGuardEnv) connectWarnings(t *testing.T) (slackIdentity, string, error) {
	t.Helper()
	var warn bytes.Buffer
	identity, err := connectSlackAccount(context.Background(), e.cfg, e.db, e.id,
		&auth.OAuthResult{AccessToken: "xoxp-new", Scope: "chat:write"}, false, &warn)
	return identity, warn.String(), err
}

func (e teamGuardEnv) token(t *testing.T) *watchtowerslack.Token {
	t.Helper()
	tok, err := watchtowerslack.NewTokenStore(e.cfg.WorkspaceDir(), e.id).Load()
	require.NoError(t, err)
	require.NotNil(t, tok)
	return tok
}

func (e teamGuardEnv) addMessage(t *testing.T, at time.Time) {
	t.Helper()
	_, err := e.db.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES (?, ?, '')`,
		watchtowerslack.Namespace(e.id, "C001"), strconv.FormatInt(at.Unix(), 10)+".000100")
	require.NoError(t, err)
}

func TestConnectSlackAccount_RefusesAnotherTeam(t *testing.T) {
	env := newTeamGuardEnv(t, "T_HOME", "Acme")
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(env.id, "2026-03-01"))
	stubSlackIdentityServer(t, "U_OTHER", "T_OTHER", "Dev Sandbox", "dev")

	_, err := env.connect(t)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Dev Sandbox")
	assert.Contains(t, err.Error(), "Acme")
	assert.Equal(t, `sign in to "Acme", this account's Slack workspace (you chose "Dev Sandbox"); `+
		"to also connect the one you chose, use Add Slack Workspace (`watchtower slack add`)", err.Error(),
		"docs/guide/troubleshooting/account-needs-attention.md quotes this text")
	assert.Less(t, len(err.Error()), 200, "the Desktop shows only stderr's first 200 characters under Re-login")

	acct, err := env.db.GetSlackAccount(env.id)
	require.NoError(t, err)
	assert.Equal(t, "T_HOME", acct.TeamID, "nothing is written before the refusal")
	assert.Equal(t, "Acme", acct.TeamName)
	assert.Equal(t, "1:U_OWNER", acct.CurrentUserID)
	assert.Equal(t, "2026-03-01", acct.SearchLastDate)
	assert.Equal(t, "xoxp-old", env.token(t).AccessToken, "the token file is untouched")
}

func TestConnectSlackAccount_AcceptsTheSameTeam(t *testing.T) {
	env := newTeamGuardEnv(t, "T_HOME", "Acme")
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(env.id, "2026-03-01"))
	env.addMessage(t, time.Date(2026, 2, 1, 12, 0, 0, 0, time.Local))
	stubSlackIdentityServer(t, "U_OWNER", "T_HOME", "Acme", "acme")

	_, err := env.connect(t)
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", env.token(t).AccessToken)
	acct, err := env.db.GetSlackAccount(env.id)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
	assert.Equal(t, "2026-03-01", acct.SearchLastDate, "a plain re-consent never rewinds the watermark")
}

func TestConnectSlackAccount_NoTeamYetAcceptsAnyTeam(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	// A legacy row seeded offline: no team, and no legacy workspace row.
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	stubSlackIdentityServer(t, "U_OWNER", "T_ANY", "Any Team", "any")

	_, err = connectSlackAccount(context.Background(), cfg, database, id,
		&auth.OAuthResult{AccessToken: "xoxp-new"}, false, &bytes.Buffer{})
	require.NoError(t, err)
	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "T_ANY", acct.TeamID)
}

// A row a pre-#915 Re-login moved to another team is repaired by a sign-in
// into the home team: the row gets its team back, the status is ok, and the
// search watermark goes back to the newest stored message so the next search
// fetches the days the wrong team's empty searches skipped.
func TestConnectSlackAccount_RepairsMovedAccountAndRewindsWatermark(t *testing.T) {
	env := newTeamGuardEnv(t, "T_OTHER", "Dev Sandbox")
	require.NoError(t, env.db.SetSlackAccountAuthState(env.id, "error", "Signed in to a different Slack workspace"))
	today := time.Now()
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(env.id, today.Format("2006-01-02")))
	newest := time.Date(today.Year(), today.Month(), today.Day(), 12, 0, 0, 0, time.Local).AddDate(0, 0, -9)
	env.addMessage(t, newest.AddDate(0, 0, -3))
	env.addMessage(t, newest)
	stubSlackIdentityServer(t, "U_OWNER", "T_HOME", "Acme", "acme")

	_, warn, err := env.connectWarnings(t)
	require.NoError(t, err)
	assert.NotContains(t, warn, "slack backfill", "the rewind covers the missed days")
	acct, err := env.db.GetSlackAccount(env.id)
	require.NoError(t, err)
	assert.Equal(t, "T_HOME", acct.TeamID)
	assert.Equal(t, "Acme", acct.TeamName)
	assert.Equal(t, "ok", acct.Status)
	assert.Empty(t, acct.Error)
	assert.Equal(t, newest.Format("2006-01-02"), acct.SearchLastDate)
	assert.Equal(t, "T_HOME", env.token(t).TeamID)
}

func TestConnectSlackAccount_RepairKeepsAnOlderWatermark(t *testing.T) {
	env := newTeamGuardEnv(t, "T_OTHER", "Dev Sandbox")
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(env.id, "2026-03-01"))
	env.addMessage(t, time.Date(2026, 3, 5, 12, 0, 0, 0, time.Local))
	stubSlackIdentityServer(t, "U_OWNER", "T_HOME", "Acme", "acme")

	_, warn, err := env.connectWarnings(t)
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(warn, "watchtower slack backfill --account 1"),
		"the watermark did not move: one warning points at the backfill")
	acct, err := env.db.GetSlackAccount(env.id)
	require.NoError(t, err)
	assert.Equal(t, "T_HOME", acct.TeamID)
	assert.Equal(t, "2026-03-01", acct.SearchLastDate, "a watermark older than the newest message stays")
}

// `slack add` of a team another live account already holds would sync the
// same team twice under two namespaces: refused, the new row rolled back.
func TestConnectSlackAccount_NewRowRefusesATeamAlreadyConnected(t *testing.T) {
	env := newTeamGuardEnv(t, "T_HOME", "Acme")
	id, err := env.db.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	stubSlackIdentityServer(t, "U_OWNER", "T_HOME", "Acme", "acme")

	_, err = connectSlackAccount(context.Background(), env.cfg, env.db, id,
		&auth.OAuthResult{AccessToken: "xoxp-dup"}, true, &bytes.Buffer{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "already connected")
	added, err := env.db.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "removed", added.Status)
	assert.Empty(t, added.TeamID)
	assert.False(t, watchtowerslack.NewTokenStore(env.cfg.WorkspaceDir(), id).Exists())
}

// `auth login` decides its workspace on the home team too, so the auth
// login path can repair a moved account #1 and still refuses the other team.
func TestReusableSlackWorkspace_UsesTheHomeTeam(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T_HOME", Name: "Acme"}))
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, database.UpdateSlackAccountConnection(id, "T_OTHER", "Dev Sandbox", "", ""))
	require.NoError(t, database.Close())

	ws, err := reusableSlackWorkspace(cfg, "T_HOME", false)
	require.NoError(t, err)
	assert.Equal(t, "default", ws)

	_, err = reusableSlackWorkspace(cfg, "T_OTHER", false)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Acme")
}

func TestConnectSlackAccount_RefusalFitsTheDesktopLineWithLongNames(t *testing.T) {
	env := newTeamGuardEnv(t, "T_HOME", "Acme")
	_, err := env.db.Exec(`UPDATE workspace SET name = 'Acme Engineering Worldwide'`)
	require.NoError(t, err)
	stubSlackIdentityServer(t, "U_OTHER", "T_OTHER", "Acme Dev Sandbox Workspace", "dev")

	_, err = env.connect(t)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "watchtower slack add")
	assert.Less(t, len(err.Error()), 200, err.Error())
}

// A removed account keeps its row but no longer holds the team: adding the
// team again is allowed. So is the other team a moved account #1 was signed
// in to, because duplicates compare home teams.
func TestConnectSlackAccount_NewRowAllowsRemovedOrMovedTeams(t *testing.T) {
	env := newTeamGuardEnv(t, "T_OTHER", "Dev Sandbox") // moved: home T_HOME
	gone, err := env.db.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, env.db.UpdateSlackAccountConnection(gone, "T_THIRD", "Third", "", ""))
	require.NoError(t, env.db.SetSlackAccountRemoved(gone))

	for _, team := range []string{"T_OTHER", "T_THIRD"} {
		id, err := env.db.CreateSlackAccount(db.SlackAccount{})
		require.NoError(t, err)
		stubSlackIdentityServer(t, "U_OWNER", team, "Team "+team, "t")
		_, err = connectSlackAccount(context.Background(), env.cfg, env.db, id,
			&auth.OAuthResult{AccessToken: "xoxp-" + team}, true, &bytes.Buffer{})
		require.NoError(t, err, team)
	}
}

func TestConnectSlackAccount_RepairWithoutMessagesOrWatermarkLeavesItAlone(t *testing.T) {
	env := newTeamGuardEnv(t, "T_OTHER", "Dev Sandbox")
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(env.id, "2026-03-01"))
	stubSlackIdentityServer(t, "U_OWNER", "T_HOME", "Acme", "acme")
	_, warn, err := env.connectWarnings(t)
	require.NoError(t, err)
	assert.Contains(t, warn, "watchtower slack backfill --account 1")
	acct, err := env.db.GetSlackAccount(env.id)
	require.NoError(t, err)
	assert.Equal(t, "2026-03-01", acct.SearchLastDate, "no stored message: nothing to rewind to")

	env2 := newTeamGuardEnv(t, "T_OTHER", "Dev Sandbox")
	env2.addMessage(t, time.Date(2026, 2, 1, 12, 0, 0, 0, time.Local))
	_, warn, err = env2.connectWarnings(t)
	require.NoError(t, err)
	assert.Empty(t, warn, "a first sync fetches everything: no warning")
	acct, err = env2.db.GetSlackAccount(env2.id)
	require.NoError(t, err)
	assert.Empty(t, acct.SearchLastDate, "no watermark stays a first run")
}
