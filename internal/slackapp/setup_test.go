package slackapp

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

const cfgToken = "xoxe.xoxp-1-config-token"

// fakeAPI is Slack's apps.manifest.* for one workspace.
type fakeAPI struct {
	teamID, teamName              string
	teamErr, createErr, exportErr error
	updateErrs                    []error // consumed one per Update call
	manifests                     map[string]Manifest
	creates, updates, exports     int
	lastUpdate                    Manifest
	afterCreate                   func()
	afterUpdate                   func()
	createLost                    error // Slack made the app, the answer was lost
	tokens                        []string
}

func newFake() *fakeAPI {
	return &fakeAPI{teamID: "T0ACME", teamName: "Acme", manifests: map[string]Manifest{}}
}

func (f *fakeAPI) Team(_ context.Context, tok string) (string, string, error) {
	f.tokens = append(f.tokens, tok)
	if f.teamErr != nil {
		return "", "", f.teamErr
	}
	return f.teamID, f.teamName, nil
}

func (f *fakeAPI) Create(_ context.Context, _ string, m Manifest) (string, string, error) {
	f.creates++
	if f.createErr != nil {
		return "", "", f.createErr
	}
	f.manifests["A0NEW"] = m
	if f.afterCreate != nil {
		f.afterCreate()
	}
	if f.createLost != nil {
		return "", "", f.createLost
	}
	return "A0NEW", "1111.2222", nil
}

func (f *fakeAPI) Update(ctx context.Context, _, appID string, m Manifest) error {
	f.updates++
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(f.updateErrs) > 0 {
		err := f.updateErrs[0]
		f.updateErrs = f.updateErrs[1:]
		if err != nil {
			return err
		}
	}
	f.lastUpdate = m
	f.manifests[appID] = m
	if f.afterUpdate != nil {
		f.afterUpdate()
	}
	return nil
}

func (f *fakeAPI) Export(ctx context.Context, _, appID string) (Manifest, error) {
	f.exports++
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if f.exportErr != nil {
		return nil, f.exportErr
	}
	m, ok := f.manifests[appID]
	if !ok {
		return nil, &SlackError{Method: "apps.manifest.export", Code: "invalid_app_id"}
	}
	return m, nil
}

type harness struct {
	db    *db.DB
	api   *fakeAPI
	r     *Runner
	steps []Step
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	h := &harness{db: d, api: newFake()}
	h.r = &Runner{DB: d, API: h.api, LockPath: filepath.Join(t.TempDir(), "slack_app_setup.lock"),
		RetiredClientID: "9999.0000", Emit: func(s Step) { h.steps = append(h.steps, s) }}
	return h
}

func (h *harness) account(t *testing.T, team, clientID, appID, status string) int64 {
	t.Helper()
	id, err := h.db.CreateSlackAccount(db.SlackAccount{TeamID: team, TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = h.db.Exec(`UPDATE slack_accounts SET client_id = ?, app_id = ?, status = ? WHERE id = ?`, clientID, appID, status, id)
	require.NoError(t, err)
	return id
}

func (h *harness) setups(t *testing.T) []db.SlackAppSetup {
	t.Helper()
	s, err := h.db.ListSlackAppSetups()
	require.NoError(t, err)
	return s
}

func (h *harness) stage(t *testing.T) string {
	t.Helper()
	st, err := Status(h.db)
	require.NoError(t, err)
	require.Len(t, st, 1)
	return st[0].Stage
}

func TestAppSetup_CreateOK(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindOK, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0NEW", ClientID: "1111.2222", LinkWritten: true}, res)
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepCreateApp, StateRunning}, {StepCreateApp, StateDone},
		{StepWriteLink, StateRunning}, {StepWriteLink, StateDone},
	}, h.steps)
	s := h.setups(t)
	require.Len(t, s, 1)
	assert.Equal(t, "A0NEW", s[0].AppID)
	assert.Equal(t, "1111.2222", s[0].ClientID)
	assert.True(t, s[0].LinkWritten)
	assert.Equal(t, StageInstall, h.stage(t))
	h.account(t, "T0ACME", "1111.2222", "A0NEW", "ok")
	assert.Equal(t, StageDone, h.stage(t))
}

func TestAppSetup_BadConfigToken(t *testing.T) {
	h := newHarness(t)
	h.api.teamErr = &SlackError{Method: "auth.test", Code: "invalid_auth"}
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindBadToken, res.Kind)
	assert.Equal(t, "invalid_auth", res.Code)
	assert.Zero(t, h.api.creates)
	assert.Empty(t, h.setups(t))
	assert.Equal(t, []Step{{StepCheckToken, StateRunning}, {StepCheckToken, StateFailed}}, h.steps)
}

func TestAppSetup_CreateFailures(t *testing.T) {
	for name, tc := range map[string]struct {
		err  error
		kind string
	}{
		"not allowed": {&SlackError{Code: "restricted_action"}, KindNotAllowed},
		// apps.manifest.create's no_permission: the token may not make apps
		// here — not the adopt's "not a collaborator".
		"no permission": {&SlackError{Code: "no_permission"}, KindNotAllowed},
		"access denied": {&SlackError{Code: "access_denied"}, KindNotAllowed},
		"refused":       {&SlackError{Code: "invalid_manifest", Details: []string{"x at /y"}}, KindRefused},
		"network":       {&net.OpError{Op: "dial", Net: "tcp", Err: errors.New("no route to host")}, KindNetwork},
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			h.api.createErr = tc.err
			res, err := h.r.Create(context.Background(), cfgToken)
			require.NoError(t, err)
			assert.Equal(t, tc.kind, res.Kind)
			assert.Empty(t, h.setups(t), "nothing created, nothing recorded")
			assert.Zero(t, h.api.updates)
		})
	}
}

func TestAppSetup_WritesLinkToDescription(t *testing.T) {
	h := newHarness(t)
	_, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	require.Equal(t, 1, h.api.updates)
	long := h.api.lastUpdate.LongDescription()
	assert.Contains(t, long, "Connect: http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222")
	assert.Contains(t, long, "Connect code: T0ACME:1111.2222")
	assert.Contains(t, long, "Watchtower for Acme.")
	created, err := BuildManifest(Link{TeamID: "T0ACME", TeamName: "Acme"})
	require.NoError(t, err)
	assert.NotContains(t, created.LongDescription(), "/slack/connect", "the create call carries no link")
}

func TestAppSetup_LinkUpdateFails(t *testing.T) {
	h := newHarness(t)
	h.api.updateErrs = []error{&SlackError{Code: "invalid_auth"}}
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindLinkFailed, res.Kind)
	assert.Equal(t, "invalid_auth", res.Code)
	assert.Equal(t, "A0NEW", res.AppID)
	assert.False(t, res.LinkWritten)
	s := h.setups(t)
	require.Len(t, s, 1)
	assert.False(t, s[0].LinkWritten)

	h.steps = nil
	res, err = h.r.Link(context.Background(), "xoxe.xoxp-1-fresh-token", "")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.True(t, res.LinkWritten)
	assert.True(t, h.setups(t)[0].LinkWritten)
	assert.Equal(t, 1, h.api.creates, "link never creates")
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepWriteLink, StateRunning}, {StepWriteLink, StateDone},
	}, h.steps)
}

func TestAppSetup_LinkResults(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.Link(context.Background(), cfgToken, "")
	require.NoError(t, err)
	assert.Equal(t, KindNoRecord, res.Kind)
	res, err = h.r.Link(context.Background(), cfgToken, "T0OTHER")
	require.NoError(t, err)
	assert.Equal(t, KindWrongTeam, res.Kind)
	assert.Zero(t, h.api.updates)
}

func TestAppSetup_ResumeAfterCreate(t *testing.T) {
	h := newHarness(t)
	require.NoError(t, h.db.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0ACME", TeamName: "Acme", AppID: "A0OLD", ClientID: "1111.2222"}))
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindExists, res.Kind)
	assert.Equal(t, "A0OLD", res.AppID)
	assert.Equal(t, "1111.2222", res.ClientID)
	assert.Zero(t, h.api.creates)
	assert.Equal(t, StageInstall, h.stage(t))
}

func TestAppSetup_ConcurrentRunBusy(t *testing.T) {
	h := newHarness(t)
	unlock, ok, err := fsutil.TryLockFile(h.r.LockPath)
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()
	for name, run := range map[string]func() (Result, error){
		"create": func() (Result, error) { return h.r.Create(context.Background(), cfgToken) },
		"adopt":  func() (Result, error) { return h.r.Adopt(context.Background(), cfgToken, "", "", "", true) },
		"link":   func() (Result, error) { return h.r.Link(context.Background(), cfgToken, "") },
	} {
		res, err := run()
		require.NoError(t, err, name)
		assert.Equal(t, KindBusy, res.Kind, name)
	}
	assert.Empty(t, h.api.tokens, "a busy run calls nothing")
}

func TestAppSetup_KilledAfterCreate(t *testing.T) {
	h := newHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	h.api.afterCreate = cancel
	res, err := h.r.Create(ctx, cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindLinkFailed, res.Kind)
	s := h.setups(t)
	require.Len(t, s, 1, "the record is there although the run died")
	assert.False(t, s[0].LinkWritten)
	assert.Equal(t, StageInstall, h.stage(t))
	h.account(t, "T0ACME", "1111.2222", "A0NEW", "ok")
	assert.Equal(t, StageLinkMissing, h.stage(t))

	res, err = h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindExists, res.Kind)
	assert.Equal(t, 1, h.api.creates, "never a second app")
}

func TestAppSetup_StatusApproval(t *testing.T) {
	h := newHarness(t)
	require.NoError(t, h.db.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0ACME", AppID: "A0NEW", ClientID: "1111.2222"}))
	require.NoError(t, h.db.SetSlackAppSetupInstallRequested("T0ACME", time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)))
	assert.Equal(t, StageApproval, h.stage(t))
	h.account(t, "T0ACME", "1111.2222", "", "error")
	assert.Equal(t, StageApproval, h.stage(t), "only an ok row is connected")
}

func TestAdopt_NoSecondApp(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindExistingApp, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", ClientID: "5555.6666"}, res)
	assert.Zero(t, h.api.creates)
	assert.Empty(t, h.setups(t))
}

func TestAdopt_SharedAppIsNotACompanyApp(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "9999.0000", "", "ok") // the retired shared app
	h.account(t, "T0ACME", "", "", "ok")          // not backfilled yet
	h.account(t, "T0ACME", "5555.6666", "", "removed")
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, 1, h.api.creates)
}

// TestAdopt_CompanyTiedRetiredIDIsACompanyApp: on the public build the corp
// app has the retired shared id (one Slack app); once the company bridge has
// tied the row it is the company's app here too (slackmode.SharedApp, ask
// #1644): Create offers adopt instead of a second app, Adopt finds it by row.
func TestAdopt_CompanyTiedRetiredIDIsACompanyApp(t *testing.T) {
	h := newHarness(t)
	id := h.account(t, "T0ACME", "9999.0000", "A0CORP", "ok")
	_, err := h.db.Exec(`UPDATE slack_accounts SET company_slug = 'acme' WHERE id = ?`, id)
	require.NoError(t, err)
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindExistingApp, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", ClientID: "9999.0000"}, res)
	assert.Zero(t, h.api.creates)

	h.api.manifests["A0CORP"] = theirManifest()
	res, err = h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, "9999.0000", res.ClientID)
}

func TestAdopt_OK(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindOK, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", AppName: "Acme Watchtower", ClientID: "5555.6666", LinkWritten: true}, res)
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepUpdateApp, StateRunning}, {StepUpdateApp, StateDone},
	}, h.steps)
	assert.Contains(t, h.api.lastUpdate.LongDescription(), "client=5555.6666")
	assert.Equal(t, true, h.api.lastUpdate["oauth_config"].(map[string]any)["pkce_enabled"],
		"adopt turns PKCE on: the About link it writes needs it (Task 16)")
	s := h.setups(t)
	require.Len(t, s, 1)
	assert.Equal(t, db.SlackAppSetup{TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", ClientID: "5555.6666", LinkWritten: true,
		CreatedAt: s[0].CreatedAt, UpdatedAt: s[0].UpdatedAt}, s[0])
	assert.Equal(t, StageDone, h.stage(t))
	assert.Zero(t, h.api.creates)
}

func TestAdopt_AppIDFlag(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	h.api.manifests["A0FLAG"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0FLAG", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindConfirmApp, res.Kind, "a flag-only App ID is confirmed by name first")
	assert.Equal(t, "A0FLAG", res.AppID)
	assert.Equal(t, "Acme Watchtower", res.AppName)
	assert.Zero(t, h.api.updates, "nothing changed")
	assert.Empty(t, h.setups(t))
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepReadApp, StateRunning}, {StepReadApp, StateDone},
	}, h.steps)

	res, err = h.r.Adopt(context.Background(), cfgToken, "", "A0FLAG", "A0OTHER", true)
	require.NoError(t, err)
	assert.Equal(t, KindConfirmApp, res.Kind, "a confirmation of another id changes nothing")
	assert.Zero(t, h.api.updates)

	h.steps = nil
	res, err = h.r.Adopt(context.Background(), cfgToken, "", "A0FLAG", "A0FLAG", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, "A0FLAG", res.AppID)
	assert.Equal(t, 1, h.api.updates)
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepReadApp, StateRunning}, {StepReadApp, StateDone},
		{StepUpdateApp, StateRunning}, {StepUpdateApp, StateDone},
	}, h.steps)
	require.Len(t, h.setups(t), 1)
}

func TestAdopt_RowAppIDSkipsConfirm(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0CORP", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, 1, h.api.updates)
}

func TestAdopt_ConfirmUnknownApp(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0GONE", "A0GONE", true)
	require.NoError(t, err)
	assert.Equal(t, KindAppNotFound, res.Kind)
	assert.Zero(t, h.api.updates)
}

func TestAdopt_NeedAppID(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindNeedAppID, res.Kind)
	assert.Equal(t, "5555.6666", res.ClientID)
	assert.Zero(t, h.api.exports+h.api.updates, "nothing sent")
	assert.Empty(t, h.setups(t))
}

func TestAdopt_NoApp(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0X", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindNoApp, res.Kind)
	assert.Zero(t, h.api.exports)
}

func TestAdopt_NotCollaborator(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.exportErr = &SlackError{Method: "apps.manifest.export", Code: "no_permission"}
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindNotCollaborator, res.Kind)
	assert.Equal(t, "no_permission", res.Code)
	assert.Zero(t, h.api.updates)
	assert.Empty(t, h.setups(t))
	assert.Equal(t, StateFailed, h.steps[len(h.steps)-1].State)
}

func TestAdopt_AppNotFound(t *testing.T) {
	for _, code := range []string{"invalid_app_id", "app_not_found"} {
		h := newHarness(t)
		h.account(t, "T0ACME", "5555.6666", "A0GONE", "ok")
		h.api.exportErr = &SlackError{Code: code}
		res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
		require.NoError(t, err)
		assert.Equal(t, KindAppNotFound, res.Kind, code)
		assert.Empty(t, h.setups(t))
	}
}

func TestAdopt_UpdateFailsNoRecord(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	h.api.updateErrs = []error{&SlackError{Code: "invalid_manifest"}}
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindRefused, res.Kind)
	assert.Equal(t, "invalid_manifest", res.Code)
	assert.Empty(t, h.setups(t))
}

func TestAdopt_SecretNeverStored(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest() // carries credentials.client_secret
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	require.Equal(t, KindOK, res.Kind)
	_, creds := h.api.lastUpdate["credentials"]
	assert.False(t, creds, "the credentials object is not sent back")
	assert.NotContains(t, fmt.Sprint(h.api.lastUpdate), "their-secret-value")
	assert.NotContains(t, dumpDB(t, h.db), "their-secret-value")
	assert.NotContains(t, fmt.Sprint(res), "their-secret-value")
}

// dumpDB renders every row of every table as text.
func dumpDB(t *testing.T, d *db.DB) string {
	t.Helper()
	var names []string
	func() {
		rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table'`)
		require.NoError(t, err)
		defer rows.Close()
		for rows.Next() {
			var n string
			require.NoError(t, rows.Scan(&n))
			names = append(names, n)
		}
		require.NoError(t, rows.Err())
	}()
	var b strings.Builder
	for _, tbl := range names {
		func() {
			rows, err := d.Query(`SELECT * FROM "` + tbl + `"`)
			require.NoError(t, err)
			defer rows.Close()
			cols, err := rows.Columns()
			require.NoError(t, err)
			for rows.Next() {
				vals := make([]any, len(cols))
				ptrs := make([]any, len(cols))
				for i := range vals {
					ptrs[i] = &vals[i]
				}
				require.NoError(t, rows.Scan(ptrs...))
				for i, v := range vals {
					if raw, ok := v.([]byte); ok {
						vals[i] = string(raw)
					}
				}
				fmt.Fprintf(&b, "%s %v\n", tbl, vals)
			}
			require.NoError(t, rows.Err())
		}()
	}
	return b.String()
}

func TestAppSetup_LostCreateAnswerNeverCreatesTwice(t *testing.T) {
	for name, lost := range map[string]error{
		"timeout":    context.DeadlineExceeded,
		"bad answer": errors.New("slack apps.manifest.create: the answer is not JSON"),
		"cut":        &net.OpError{Op: "read", Net: "tcp", Err: errors.New("connection reset by peer")},
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			h.api.createLost = lost
			res, err := h.r.Create(context.Background(), cfgToken)
			require.NoError(t, err)
			assert.Equal(t, KindPendingCreate, res.Kind)
			assert.Contains(t, res.Error, "api.slack.com/apps")
			assert.Equal(t, StepCreateApp, h.steps[len(h.steps)-1].Name)
			assert.Equal(t, StateFailed, h.steps[len(h.steps)-1].State)
			s := h.setups(t)
			require.Len(t, s, 1, "the pending record stays")
			assert.Empty(t, s[0].AppID)
			assert.Equal(t, StagePendingCreate, h.stage(t))

			h.api.createLost = nil
			res, err = h.r.Create(context.Background(), cfgToken)
			require.NoError(t, err)
			assert.Equal(t, KindPendingCreate, res.Kind)
			assert.Equal(t, 1, h.api.creates, "never a second create")
			res, err = h.r.Link(context.Background(), cfgToken, "")
			require.NoError(t, err)
			assert.Equal(t, KindPendingCreate, res.Kind)
			assert.Zero(t, h.api.updates)
		})
	}
}

func TestAppSetup_RefusedCreateDropsThePendingRecord(t *testing.T) {
	h := newHarness(t)
	h.api.createErr = &SlackError{Code: "invalid_manifest"}
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindRefused, res.Kind)
	assert.Empty(t, h.setups(t))
	h.api.createErr = nil
	res, err = h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "a refused create can be retried")
}

func TestAppSetup_StorageAfterCreate(t *testing.T) {
	h := newHarness(t)
	h.api.afterCreate = func() { _ = h.db.Close() }
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err, "a result line, not a bare error")
	assert.Equal(t, KindStorage, res.Kind)
	assert.Equal(t, "A0NEW", res.AppID, "the created app's ids still reach the owner")
	assert.Equal(t, "1111.2222", res.ClientID)
	assert.Error(t, res.Err)
	assert.Empty(t, res.Error, "the Go detail is not the owner's message")
}

func TestAppSetup_StorageAfterLinkWrite(t *testing.T) {
	h := newHarness(t)
	h.api.afterUpdate = func() { _ = h.db.Close() }
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindStorage, res.Kind, "not network: Slack was reached")
	assert.Error(t, res.Err)
}

func TestAdopt_StorageAfterUpdate(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	h.api.afterUpdate = func() { _ = h.db.Close() }
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindStorage, res.Kind)
	assert.Error(t, res.Err)
}

func TestAdopt_AppIDFlagChecks(t *testing.T) {
	for name, tc := range map[string]struct {
		rowAppID, flag, code string
	}{
		"bad format":           {"", "a0lower", CodeAppIDFormat},
		"client id typed":      {"", "1111.2222", CodeAppIDFormat},
		"differs from the row": {"A0CORP", "A0OTHER", CodeAppIDMismatch},
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			h.account(t, "T0ACME", "5555.6666", tc.rowAppID, "ok")
			h.api.manifests["A0CORP"] = theirManifest()
			h.api.manifests["A0OTHER"] = theirManifest()
			res, err := h.r.Adopt(context.Background(), cfgToken, "", tc.flag, "", true)
			require.NoError(t, err)
			assert.Equal(t, KindNeedAppID, res.Kind)
			assert.Equal(t, tc.code, res.Code)
			assert.NotEmpty(t, res.Error)
			assert.Zero(t, h.api.updates, "nothing written")
			assert.Empty(t, h.setups(t))
		})
	}
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "A0CORP", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "the row's own App ID repeated is fine")
}

func TestAppSetup_UnknownCreateCodeStaysPending(t *testing.T) {
	h := newHarness(t)
	h.api.createErr = &SlackError{Code: "internal_error"}
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindPendingCreate, res.Kind, "an unknown code may have made the app")
	require.Len(t, h.setups(t), 1)
}

// TestAppSetup_CreateCodesThatMayHaveMadeTheApp pins the codes of
// apps.manifest.create's error table that say part of the call may have run:
// each keeps the pending record (no second app), never the not-created path.
func TestAppSetup_CreateCodesThatMayHaveMadeTheApp(t *testing.T) {
	for _, code := range []string{"fatal_error", "internal_error", "failed_adding_collaborator",
		"failed_creating_app", "failed_datastore_operation", "failed_generating_app_token",
		"service_unavailable", "some_future_code"} {
		assert.False(t, notCreated(&SlackError{Code: code}), code)
	}
	for _, code := range []string{"invalid_auth", "invalid_manifest", "invalid_app", "restricted_action",
		"no_permission", "ratelimited", "missing_scope", "not_in_team"} {
		assert.True(t, notCreated(&SlackError{Code: code}), code)
	}
}

// TestAdopt_PKCENeedsConsent: without the owner's opt-in, adopt of an app
// without PKCE reads it and changes nothing (Slack cannot undo PKCE); an app
// that already has PKCE on needs no opt-in.
func TestAdopt_PKCENeedsConsent(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", false)
	require.NoError(t, err)
	assert.Equal(t, KindNeedsPKCEConsent, res.Kind)
	assert.Equal(t, "A0CORP", res.AppID)
	assert.Zero(t, h.api.updates, "nothing updated without consent")
	assert.Empty(t, h.setups(t))
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepUpdateApp, StateRunning}, {StepUpdateApp, StateFailed},
	}, h.steps)

	withPKCE := theirManifest()
	withPKCE.object("oauth_config")["pkce_enabled"] = true
	h.api.manifests["A0CORP"] = withPKCE
	res, err = h.r.Adopt(context.Background(), cfgToken, "", "", "", false)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "PKCE already on: nothing one-way left to agree to")
	assert.Equal(t, 1, h.api.updates)
}

// TestAdopt_CreateOnlyNotAllowedCodes: the create-only not_allowed codes keep
// adopt's own mapping (no_permission = not a collaborator).
func TestAdopt_CreateOnlyNotAllowedCodes(t *testing.T) {
	for code, kind := range map[string]string{
		"no_permission": KindNotCollaborator, "access_denied": KindRefused,
		"feature_not_enabled": KindRefused, "team_access_not_granted": KindRefused,
		"restricted_action": KindNotAllowed,
	} {
		t.Run(code, func(t *testing.T) {
			h := newHarness(t)
			h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
			h.api.manifests["A0CORP"] = theirManifest()
			h.api.updateErrs = []error{&SlackError{Code: code}}
			res, err := h.r.Adopt(context.Background(), cfgToken, "", "", "", true)
			require.NoError(t, err)
			assert.Equal(t, kind, res.Kind)
		})
	}
}

func pendingHarness(t *testing.T) *harness {
	t.Helper()
	h := newHarness(t)
	h.api.createLost = context.DeadlineExceeded
	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	require.Equal(t, KindPendingCreate, res.Kind)
	h.api.createLost = nil
	return h
}

func TestPending_Clear(t *testing.T) {
	h := pendingHarness(t)
	res, err := h.r.ClearPending("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Empty(t, h.setups(t))
	res, err = h.r.ClearPending("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, KindNoPending, res.Kind)

	res, err = h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "cleared: create runs again")
}

func TestPending_Attach(t *testing.T) {
	h := pendingHarness(t)
	for _, tc := range []struct{ app, client, code string }{
		{"a0lower", "1111.2222", CodeAppIDFormat},
		{"A0NEW", "T0ACME", CodeClientIDFormat},
		{"A0NEW", "", CodeClientIDFormat},
	} {
		res, err := h.r.AttachPending("T0ACME", tc.app, tc.client)
		require.NoError(t, err)
		assert.Equal(t, KindBadIDs, res.Kind)
		assert.Equal(t, tc.code, res.Code)
	}
	res, err := h.r.AttachPending("T0ACME", "A0TYPO", "1111.9999")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	res, err = h.r.ClearPending("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, KindNoPending, res.Kind, "a record with ids is never cleared (it may be create's)")
	res, err = h.r.AttachPending("T0ACME", "A0NEW", "1111.2222")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "a mistyped attach is corrected before the link is written")
	assert.Equal(t, "A0NEW", res.AppID)
	assert.Equal(t, "1111.2222", h.setups(t)[0].ClientID)
	assert.Equal(t, StageInstall, h.stage(t))

	res, err = h.r.Link(context.Background(), cfgToken, "")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "the setup continues with link")

	res, err = h.r.AttachPending("T0ACME", "A0OTHER", "1111.3333")
	require.NoError(t, err)
	assert.Equal(t, KindNoPending, res.Kind, "once the link is written the ids stay")
	assert.Equal(t, "A0NEW", h.setups(t)[0].AppID)
	assert.Equal(t, 1, h.api.creates)
}

func TestPending_Busy(t *testing.T) {
	h := pendingHarness(t)
	unlock, ok, err := fsutil.TryLockFile(h.r.LockPath)
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()
	res, err := h.r.ClearPending("T0ACME")
	require.NoError(t, err)
	assert.Equal(t, KindBusy, res.Kind)
	res, err = h.r.AttachPending("T0ACME", "A0NEW", "1111.2222")
	require.NoError(t, err)
	assert.Equal(t, KindBusy, res.Kind)
	require.Len(t, h.setups(t), 1)
}

// TestAdopt_WrongTeam: the sheet names the workspace it offers to update; a
// token of another workspace reads and changes nothing.
func TestAdopt_WrongTeam(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "T0OTHER", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindWrongTeam, TeamID: "T0ACME", TeamName: "Acme"}, res)
	assert.Zero(t, h.api.exports)
	assert.Zero(t, h.api.updates)
	assert.Empty(t, h.setups(t))

	res, err = h.r.Adopt(context.Background(), cfgToken, "T0ACME", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind, "the named team matches: the update runs")
}

// The team's app is the one this build signs in through: adopt refuses even
// with --enable-pkce, and create never offers the adopt (review M1). Turning
// PKCE on would break the build's own sign-in (no PKCE, client secret); the
// build's app switches with a later update.
func TestAdopt_BuiltinAppPKCEDeferred(t *testing.T) {
	h := newHarness(t)
	h.r.BuiltinClientID = "5555.6666"
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()

	for _, enablePKCE := range []bool{true, false} {
		h.steps = nil
		res, err := h.r.Adopt(context.Background(), cfgToken, "T0ACME", "", "", enablePKCE)
		require.NoError(t, err)
		assert.Equal(t, Result{Kind: KindBuiltinPKCEDeferred, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", ClientID: "5555.6666"}, res)
		assert.Equal(t, []Step{{StepCheckToken, StateRunning}, {StepCheckToken, StateDone}}, h.steps, "nothing read or changed")
	}
	assert.Zero(t, h.api.updates)
	assert.Empty(t, h.setups(t))

	res, err := h.r.Create(context.Background(), cfgToken)
	require.NoError(t, err)
	assert.Equal(t, KindBuiltinPKCEDeferred, res.Kind, "create does not offer the adopt")
	assert.Zero(t, h.api.creates)

	// Another company app in a build with its own app adopts as before.
	h.r.BuiltinClientID = "7777.8888"
	res, err = h.r.Adopt(context.Background(), cfgToken, "T0ACME", "", "", true)
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
}
