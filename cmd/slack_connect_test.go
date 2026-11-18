package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/slackconnect"
	"watchtower/internal/slackmode"
)

// Placeholder Slack ids, not real workspaces or apps.
const (
	connTeam      = "T0ACME"
	connOtherTeam = "T0OTHER"
	connUser      = "U0OWNER"
	connOtherUser = "U0SOMEONE"
	connRetiredID = "1000.0001" // the retired public shared app
	connCorpID    = "2000.0002" // a company app a build bakes
	connNewID     = "4000.0004" // a workspace app made by setup
	connAppID     = "A0NEWAPP"
)

// connectEnv is an install with an open database and a HOME of its own.
type connectEnv struct {
	cfg *config.Config
	db  *db.DB
}

func newConnectEnv(t *testing.T) connectEnv {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	setSlackBuild(t, "", "", connRetiredID)
	policytest.Set(t, nil)
	return connectEnv{cfg: &config.Config{ActiveWorkspace: "test"}, db: db.OpenTestDB(t)}
}

// seedAccount adds an ok account on team for connUser with clientID and a
// token file issued through it.
func (e connectEnv) seedAccount(t *testing.T, team, clientID string) int64 {
	t.Helper()
	id, err := e.db.CreateSlackAccount(db.SlackAccount{Label: "Acme"})
	require.NoError(t, err)
	require.NoError(t, e.db.UpdateSlackAccountConnection(id, team, "Acme", "acme", watchtowerslack.Namespace(id, connUser)))
	require.NoError(t, e.db.SetSlackAccountClientID(id, clientID))
	require.NoError(t, e.db.SetSlackAccountAuthState(id, "ok", ""))
	require.NoError(t, e.store(id).Save(&watchtowerslack.Token{
		AccessToken: "xoxp-old", TeamID: team, UserID: connUser, ClientID: clientID}))
	return id
}

func (e connectEnv) store(id int64) *watchtowerslack.TokenStore {
	return watchtowerslack.NewTokenStore(e.cfg.WorkspaceDir(), id)
}

func (e connectEnv) tokenBytes(t *testing.T, id int64) []byte {
	t.Helper()
	b, err := os.ReadFile(e.store(id).Path())
	require.NoError(t, err)
	return b
}

func (e connectEnv) account(t *testing.T, id int64) db.SlackAccount {
	t.Helper()
	a, err := e.db.GetSlackAccount(id)
	require.NoError(t, err)
	return a
}

func (e connectEnv) write(t slackconnect.Target, g slackconnect.Grant) (int64, string, error) {
	return writeConnectedAccount(context.Background(), e.cfg, e.db, t, g, io.Discard)
}

// tableCounts is the row count of every table.
func (e connectEnv) tableCounts(t *testing.T) map[string]int {
	t.Helper()
	names := e.tableNames(t)
	counts := map[string]int{}
	for _, n := range names {
		var c int
		require.NoError(t, e.db.QueryRow(`SELECT COUNT(*) FROM "`+n+`"`).Scan(&c))
		counts[n] = c
	}
	return counts
}

func (e connectEnv) tableNames(t *testing.T) []string {
	t.Helper()
	rows, err := e.db.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	return names
}

func connGrant(clientID string) slackconnect.Grant {
	return slackconnect.Grant{
		AccessToken: "xoxp-new", RefreshToken: "xoxe-refresh", ExpiresIn: 43200,
		ClientID: clientID, AppID: connAppID, TeamID: connTeam, TeamName: "Acme", UserID: connUser,
		Scope: "chat:write,channels:history",
	}
}

func connTarget(clientID string) slackconnect.Target {
	return slackconnect.Target{TeamID: connTeam, ClientID: clientID}
}

func TestSlackLinkConnect_NewAccount(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	before := time.Now()

	id, rebound, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	assert.Empty(t, rebound)
	a := env.account(t, id)
	assert.Equal(t, "ok", a.Status)
	assert.Equal(t, connTeam, a.TeamID)
	assert.Equal(t, connNewID, a.ClientID)
	assert.Equal(t, connAppID, a.AppID)
	assert.Equal(t, watchtowerslack.Namespace(id, connUser), a.CurrentUserID)
	assert.Empty(t, a.RefreshTokenExpiresAt, "Slack sent no refresh-token lifetime")

	tok, err := env.store(id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", tok.AccessToken)
	assert.Equal(t, "xoxe-refresh", tok.RefreshToken)
	assert.Equal(t, connNewID, tok.ClientID)
	assert.Equal(t, connAppID, tok.AppID)
	assert.WithinDuration(t, before.Add(12*time.Hour), tok.ExpiresAt, time.Minute)
}

func TestSlackLinkConnect_RefreshExpiryRecorded(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	g := connGrant(connNewID)
	g.RefreshExpiresIn = 30 * 24 * 3600
	id, _, err := env.write(connTarget(connNewID), g)
	require.NoError(t, err)
	at, err := time.Parse(time.RFC3339, env.account(t, id).RefreshTokenExpiresAt)
	require.NoError(t, err)
	assert.WithinDuration(t, time.Now().Add(30*24*time.Hour), at, time.Minute)
}

// Seven-point review focus 7: the team Slack returns is not the link's.
func TestSlackLinkConnect_TeamMismatch(t *testing.T) {
	env := newConnectEnv(t)
	// The exchange reported the link's team, but the token is another's.
	stubSlackIdentityServer(t, connUser, connOtherTeam, "Other", "other")
	before := env.tableCounts(t)

	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.ErrorIs(t, err, errSlackTeamMismatch)
	assert.Equal(t, "team_mismatch", slackConnectReason(err))
	assert.Equal(t, before, env.tableCounts(t), "nothing stored: the new row is made only after the checks")

	// A grant for another team never reaches Slack's identity check either.
	g := connGrant(connNewID)
	g.TeamID = connOtherTeam
	_, _, err = env.write(connTarget(connNewID), g)
	require.ErrorIs(t, err, errSlackTeamMismatch)
	assert.Equal(t, before, env.tableCounts(t))
}

// A new row whose write fails after it was created is rolled back
// (rollbackSlackAccount) and keeps no token.
func TestSlackLinkConnect_NewRowRolledBack(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	_, err := env.db.Exec(`CREATE TRIGGER fail_app BEFORE UPDATE OF client_id ON slack_accounts
        BEGIN SELECT RAISE(ABORT, 'row write failed'); END`)
	require.NoError(t, err)

	_, _, err = env.write(connTarget(connNewID), connGrant(connNewID))
	require.Error(t, err)
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "removed", accounts[0].Status)
	assert.False(t, accounts[0].Enabled)
	assert.False(t, env.store(accounts[0].ID).Exists(), "the rolled-back row keeps no token")
}

// PURGE-02: a purge that starts while the grant is being checked (after the
// early check, before the lock) wins; nothing is written.
func TestSlackLinkConnect_PurgeStartsDuringCheck(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	oldFile := env.tokenBytes(t, id)
	stub := stubSlackIdentity(t, connUser, connTeam)
	stub.onAuth = func() { startRunningPurge(t, env.db, "slack", id) }

	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.Equal(t, oldFile, env.tokenBytes(t, id))
	assert.Equal(t, connRetiredID, env.account(t, id).ClientID)
}

// An explicit target (a removed account) is refused while another live
// account holds the team: the connect would leave two live rows.
func TestSlackLinkConnect_ExplicitTargetWithLiveRowRefused(t *testing.T) {
	env := newConnectEnv(t)
	removed := env.seedAccount(t, connTeam, connRetiredID)
	require.NoError(t, env.db.SetSlackAccountRemoved(removed))
	live := env.seedAccount(t, connTeam, connNewID)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	before := env.tableCounts(t)

	tgt := connTarget(connNewID)
	tgt.AccountID = removed
	_, _, err := env.write(tgt, connGrant(connNewID))
	require.ErrorIs(t, err, errSlackTeamHasLiveRow)
	assert.Contains(t, err.Error(), "account "+strconv.FormatInt(live, 10))
	assert.Equal(t, "removed", env.account(t, removed).Status)
	assert.Equal(t, before, env.tableCounts(t))

	// Without an explicit target the live row is the one re-bound.
	got, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, live, got)
}

func TestSlackLinkConnect_ReconsentSameClient(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connNewID)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	got, rebound, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, id, got)
	assert.Empty(t, rebound, "same app: no re-bind")
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1, "no new row")
	tok, err := env.store(id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", tok.AccessToken)
}

// Review focus 6: moving a shared-app account to Full keeps its row,
// its data and its sync position.
func TestSlackLinkConnect_RebindKeepsHistory(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	require.Equal(t, int64(1), id)
	ch := watchtowerslack.Namespace(id, "C001")
	for _, q := range []string{
		`INSERT INTO messages (channel_id, ts, text) VALUES ('` + ch + `', '1700000000.000100', 'hello')`,
		`INSERT INTO messages (channel_id, ts, text) VALUES ('` + ch + `', '1700000001.000100', 'again')`,
		`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('` + ch + `', 1, 2, 'channel', 'kept')`,
	} {
		_, err := env.db.Exec(q)
		require.NoError(t, err)
	}
	require.NoError(t, env.db.SetSlackAccountSearchWatermark(id, "2026-03-01"))
	require.True(t, slackmode.SharedApp(env.account(t, id), connRetiredID))
	before := env.tableCounts(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	got, rebound, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, id, got, "the same row")
	assert.Equal(t, connRetiredID, rebound)
	a := env.account(t, id)
	assert.Equal(t, connNewID, a.ClientID)
	assert.Equal(t, connAppID, a.AppID)
	assert.False(t, slackmode.SharedApp(a, connRetiredID), "now Full")
	assert.Equal(t, "ok", a.Status)
	assert.Equal(t, "2026-03-01", a.SearchLastDate, "the watermark stays")
	assert.Equal(t, before, env.tableCounts(t), "no table gained or lost a row")
	tok, err := env.store(id).Load()
	require.NoError(t, err)
	assert.Equal(t, connNewID, tok.ClientID)
	assert.Equal(t, "xoxe-refresh", tok.RefreshToken)
}

// A failed exchange stores nothing: the old token keeps syncing.
func TestSlackLinkConnect_RebindExchangeFails(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	oldFile := env.tokenBytes(t, id)
	oldRow := env.account(t, id)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	h := startConnectServe(t, env, func(string) (slackconnect.Grant, error) {
		return slackconnect.Grant{}, errors.New("slack oauth.v2.access: invalid_code")
	})
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	flow := h.expect(t, "browser")["flow"].(string)
	h.callback(t, "code-1")
	ev := h.expect(t, "failed")
	assert.Equal(t, flow, ev["flow"])
	assert.Equal(t, "exchange", ev["reason"])

	assert.Equal(t, oldFile, env.tokenBytes(t, id), "the old token file is byte-identical")
	assert.Equal(t, oldRow, env.account(t, id), "the row is unchanged")
}

// A token save that fails leaves the old file and the row as they were.
func TestSlackLinkConnect_RebindTokenSaveFails(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	oldFile := env.tokenBytes(t, id)
	oldRow := env.account(t, id)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	// The atomic save's temp file cannot be created in a read-only dir; the
	// lock file is made first so the lock itself still works.
	unlock, err := env.store(id).Lock(context.Background())
	require.NoError(t, err)
	unlock()
	dir := filepath.Dir(env.store(id).Path())
	require.NoError(t, os.Chmod(dir, 0o500))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	_, _, err = env.write(connTarget(connNewID), connGrant(connNewID))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "saving token")
	require.NoError(t, os.Chmod(dir, 0o700))
	assert.Equal(t, oldFile, env.tokenBytes(t, id), "the old token keeps syncing")
	assert.Equal(t, oldRow, env.account(t, id))
}

// The process dies after the token save and before the row update: the
// file carries the new app, so the next token read repairs the row (A6).
func TestSlackLinkConnect_RebindRestartMidway(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	// The row update fails where a crash would have stopped the process.
	_, err := env.db.Exec(`CREATE TRIGGER die_midway BEFORE UPDATE OF client_id ON slack_accounts
        BEGIN SELECT RAISE(ABORT, 'process died'); END`)
	require.NoError(t, err)

	_, _, err = env.write(connTarget(connNewID), connGrant(connNewID))
	require.Error(t, err)
	tok, err := env.store(id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", tok.AccessToken, "the token file was saved first")
	assert.Equal(t, connNewID, tok.ClientID)
	assert.Equal(t, connAppID, tok.AppID)
	a := env.account(t, id)
	assert.Equal(t, connRetiredID, a.ClientID, "the row still names the old app until the repair")
	assert.NotEqual(t, "removed", a.Status, "an existing row is never rolled back")
	// The repair itself is slackauth.LoadFresh's (plan B Task 8): it copies
	// the file's client and app id onto the row.
}

// A18: the account's history belongs to its user.
func TestSlackLinkConnect_RebindOtherUserRefused(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	oldFile := env.tokenBytes(t, id)
	oldRow := env.account(t, id)
	stubSlackIdentityServer(t, connOtherUser, connTeam, "Acme", "acme")
	before := env.tableCounts(t)

	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.ErrorIs(t, err, errSlackOtherUser)
	assert.Equal(t, "other_user", slackConnectReason(err))
	assert.Equal(t, "signed in as someone else; nothing was changed", err.Error())
	assert.Equal(t, oldFile, env.tokenBytes(t, id))
	assert.Equal(t, oldRow, env.account(t, id))
	assert.Equal(t, before, env.tableCounts(t))
}

// A row on a corp-baked id connected through the same app's link: same
// row, still Full.
func TestSlackLinkConnect_CorpBakedRowRebinds(t *testing.T) {
	env := newConnectEnv(t)
	setSlackBuild(t, connCorpID, "", connRetiredID)
	id := env.seedAccount(t, connTeam, connCorpID)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	got, rebound, err := env.write(connTarget(connCorpID), connGrant(connCorpID))
	require.NoError(t, err)
	assert.Equal(t, id, got)
	assert.Empty(t, rebound)
	a := env.account(t, id)
	assert.Equal(t, connCorpID, a.ClientID)
	assert.False(t, slackmode.SharedApp(a, connRetiredID))
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1)
}

func TestSlackLinkConnect_PurgeRunningRefused(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	oldFile := env.tokenBytes(t, id)
	startRunningPurge(t, env.db, "slack", id)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.Equal(t, "purge_running", slackConnectReason(err))
	assert.Equal(t, oldFile, env.tokenBytes(t, id))
}

func TestSlackLinkConnect_ClearsSetupApprovalRequest(t *testing.T) {
	env := newConnectEnv(t)
	require.NoError(t, env.db.InsertSlackAppSetup(db.SlackAppSetup{
		TeamID: connTeam, TeamName: "Acme", ClientID: connNewID, InstallRequestedAt: "2026-11-01T10:00:00Z"}))
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	s, err := env.db.GetSlackAppSetup(connTeam)
	require.NoError(t, err)
	assert.Empty(t, s.InstallRequestedAt)
}

func TestSlackLinkConnect_PolicyBlocksSlack(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})

	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	ev := h.expect(t, "failed")
	assert.Equal(t, "policy", ev["reason"])
	assert.Equal(t, "", ev["flow"])

	h.link(t, connTeam, connNewID)
	ev = h.expect(t, "failed")
	assert.Equal(t, "policy", ev["reason"])
	assert.NotEmpty(t, ev["flow"])
	h.closeStdin(t)
	assert.Empty(t, h.browserURLs(), "no browser")

	// The account write refuses as well (the policy changed mid-flow).
	_, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// slackConnectTestDeps points the connect commands at an ephemeral listener
// the test made, a fixed exchange and a recording browser.
func slackConnectTestDeps(t *testing.T, ln net.Listener, exchange func(clientID, code string) (slackconnect.Grant, error), opened chan<- string) {
	t.Helper()
	orig := newSlackConnectDeps
	newSlackConnectDeps = func() slackConnectDeps {
		return slackConnectDeps{
			port:   0,
			listen: func(int) (net.Listener, error) { return ln, nil },
			exchange: func(_ context.Context, clientID, code, _, _ string) (slackconnect.Grant, error) {
				return exchange(clientID, code)
			},
			openBrowser: func(u string) { opened <- u },
			clock:       slackconnect.SystemClock{},
		}
	}
	t.Cleanup(func() { newSlackConnectDeps = orig })
}

func TestSlackConnect_PortBusyMessage(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default", false)
	require.NoError(t, err)
	held, err := slackconnect.Listen(0)
	require.NoError(t, err)
	t.Cleanup(func() { _ = held.Close() })
	busyPort := held.Addr().(*net.TCPAddr).Port
	orig := newSlackConnectDeps
	newSlackConnectDeps = func() slackConnectDeps {
		d := orig()
		d.port, d.listen = busyPort, slackconnect.Listen
		d.openBrowser = func(string) { t.Error("no browser on a busy port") }
		return d
	}
	t.Cleanup(func() { newSlackConnectDeps = orig })

	_, _, err = runRootCmd(t, []*cobra.Command{slackCmd, slackConnectCmd},
		"slack", "connect", "--code", connTeam+":"+connNewID, "--config", configPath)
	require.Error(t, err)
	assert.Equal(t, "port 18551 is busy (is Watchtower open? connect from Connections → Slack)", err.Error())
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 2, ec.code)
}

func TestSlackConnect_FlagsNeedTeamAndClientOrCode(t *testing.T) {
	for _, args := range [][]string{
		{"--team", connTeam},
		{"--code", connTeam + ":" + connNewID, "--team", connTeam},
		{"--code", "not-a-code"},
	} {
		_, _, err := runRootCmd(t, []*cobra.Command{slackCmd, slackConnectCmd}, append([]string{"slack", "connect"}, args...)...)
		var ec *exitCodeError
		require.ErrorAs(t, err, &ec, args)
		assert.Equal(t, 2, ec.code, args)
	}
}

// slack login --account N on a company-app account runs the one-shot
// PKCE flow on that account's client id: no client secret is needed.
func TestSlackLogin_WorkspaceAppAccountUsesPKCE(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default", false)
	require.NoError(t, err)
	setSlackBuild(t, "", "", connRetiredID) // no built-in app at all
	policytest.Set(t, nil)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	env := connectEnv{cfg: cfg, db: database}
	id := env.seedAccount(t, connTeam, connNewID)
	require.NoError(t, database.Close())
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")

	ln, err := slackconnect.Listen(0)
	require.NoError(t, err)
	opened := make(chan string, 1)
	var gotClient string
	slackConnectTestDeps(t, ln, func(clientID, _ string) (slackconnect.Grant, error) {
		gotClient = clientID
		return connGrant(connNewID), nil
	}, opened)

	done := make(chan error, 1)
	go func() {
		_, _, err := runRootCmd(t, []*cobra.Command{slackCmd, slackLoginCmd},
			"slack", "login", "--account", strconv.FormatInt(id, 10), "--config", configPath)
		done <- err
	}()
	authorize := <-opened
	u, err := url.Parse(authorize)
	require.NoError(t, err)
	assert.Equal(t, connNewID, u.Query().Get("client_id"))
	assert.Equal(t, connTeam, u.Query().Get("team"))
	assert.Equal(t, "S256", u.Query().Get("code_challenge_method"))
	resp, err := http.Get("http://" + ln.Addr().String() + "/callback?state=" +
		url.QueryEscape(u.Query().Get("state")) + "&code=code-1")
	require.NoError(t, err)
	require.NoError(t, resp.Body.Close())
	require.NoError(t, <-done)
	assert.Equal(t, connNewID, gotClient)

	database, err = db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	tok, err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", tok.AccessToken)
	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1)
}

func TestSlackConnectReason_EveryOutcome(t *testing.T) {
	assert.Equal(t, "other", slackConnectReason(errors.New("boom")))
	err := slackOtherTeamError(slackIdentity{TeamID: connOtherTeam}, db.SlackHomeTeam{ID: connTeam, Name: "Acme"})
	assert.Equal(t, "team_mismatch", slackConnectReason(err))
	assert.True(t, strings.HasPrefix(err.Error(), `sign in to "Acme"`), "the refusal keeps its text")
}

// slack login without --account resolves account #1 and applies the same
// re-login rule: a company-app account signs in through PKCE.
func TestSlackLogin_ImplicitAccountUsesPKCE(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default", false)
	require.NoError(t, err)
	setSlackBuild(t, "", "", connRetiredID)
	policytest.Set(t, nil)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id := connectEnv{cfg: cfg, db: database}.seedAccount(t, connTeam, connNewID)
	require.NoError(t, database.Close())
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	ln, err := slackconnect.Listen(0)
	require.NoError(t, err)
	opened := make(chan string, 1)
	slackConnectTestDeps(t, ln, func(string, string) (slackconnect.Grant, error) { return connGrant(connNewID), nil }, opened)

	done := make(chan error, 1)
	go func() {
		_, _, err := runRootCmd(t, []*cobra.Command{slackCmd, slackLoginCmd}, "slack", "login", "--config", configPath)
		done <- err
	}()
	u, err := url.Parse(<-opened)
	require.NoError(t, err)
	assert.Equal(t, connNewID, u.Query().Get("client_id"))
	resp, err := http.Get("http://" + ln.Addr().String() + "/callback?state=" + url.QueryEscape(u.Query().Get("state")) + "&code=c")
	require.NoError(t, err)
	require.NoError(t, resp.Body.Close())
	require.NoError(t, <-done)
	tok, err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxp-new", tok.AccessToken)
}

// identityStub answers auth.test and team.info with an identity the test
// may change, and runs onAuth (when set) inside auth.test.
type identityStub struct {
	mu     sync.Mutex
	user   string
	team   string
	onAuth func()
}

func (s *identityStub) set(user, team string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.user, s.team = user, team
}

func (s *identityStub) get() (string, string, func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.user, s.team, s.onAuth
}

func stubSlackIdentity(t *testing.T, user, team string) *identityStub {
	t.Helper()
	stub := &identityStub{user: user, team: team}
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		u, tm, hook := stub.get()
		if hook != nil {
			hook()
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "user_id": u, "user": "owner", "team_id": tm})
	})
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		_, tm, _ := stub.get()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "team": map[string]any{"id": tm, "name": "Acme", "domain": "acme"}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	orig := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIURLUnlimited(token, srv.URL+"/")
	}
	t.Cleanup(func() { newSlackClientForToken = orig })
	return stub
}
