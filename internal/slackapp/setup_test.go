package slackapp

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
		"refused":     {&SlackError{Code: "invalid_manifest", Details: []string{"x at /y"}}, KindRefused},
		"network":     {errors.New("dial tcp: no route"), KindNetwork},
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
		"adopt":  func() (Result, error) { return h.r.Adopt(context.Background(), cfgToken, "") },
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

func TestAdopt_OK(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest()
	res, err := h.r.Adopt(context.Background(), cfgToken, "")
	require.NoError(t, err)
	assert.Equal(t, Result{Kind: KindOK, TeamID: "T0ACME", TeamName: "Acme", AppID: "A0CORP", ClientID: "5555.6666", LinkWritten: true}, res)
	assert.Equal(t, []Step{
		{StepCheckToken, StateRunning}, {StepCheckToken, StateDone},
		{StepUpdateApp, StateRunning}, {StepUpdateApp, StateDone},
	}, h.steps)
	assert.Contains(t, h.api.lastUpdate.LongDescription(), "client=5555.6666")
	_, pkce := h.api.lastUpdate["oauth_config"].(map[string]any)["pkce_enabled"]
	assert.False(t, pkce, "PKCE stays off by default")
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
	res, err := h.r.Adopt(context.Background(), cfgToken, "A0FLAG")
	require.NoError(t, err)
	assert.Equal(t, KindOK, res.Kind)
	assert.Equal(t, "A0FLAG", res.AppID)
}

func TestAdopt_NeedAppID(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "", "ok")
	res, err := h.r.Adopt(context.Background(), cfgToken, "")
	require.NoError(t, err)
	assert.Equal(t, KindNeedAppID, res.Kind)
	assert.Equal(t, "5555.6666", res.ClientID)
	assert.Zero(t, h.api.exports+h.api.updates, "nothing sent")
	assert.Empty(t, h.setups(t))
}

func TestAdopt_NoApp(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.Adopt(context.Background(), cfgToken, "A0X")
	require.NoError(t, err)
	assert.Equal(t, KindNoApp, res.Kind)
	assert.Zero(t, h.api.exports)
}

func TestAdopt_NotCollaborator(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.exportErr = &SlackError{Method: "apps.manifest.export", Code: "no_permission"}
	res, err := h.r.Adopt(context.Background(), cfgToken, "")
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
		res, err := h.r.Adopt(context.Background(), cfgToken, "")
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
	res, err := h.r.Adopt(context.Background(), cfgToken, "")
	require.NoError(t, err)
	assert.Equal(t, KindRefused, res.Kind)
	assert.Equal(t, "invalid_manifest", res.Code)
	assert.Empty(t, h.setups(t))
}

func TestAdopt_SecretNeverStored(t *testing.T) {
	h := newHarness(t)
	h.account(t, "T0ACME", "5555.6666", "A0CORP", "ok")
	h.api.manifests["A0CORP"] = theirManifest() // carries credentials.client_secret
	res, err := h.r.Adopt(context.Background(), cfgToken, "")
	require.NoError(t, err)
	require.Equal(t, KindOK, res.Kind)
	_, creds := h.api.lastUpdate["credentials"]
	assert.False(t, creds, "the credentials object is not sent back")
	assert.NotContains(t, fmt.Sprint(h.api.lastUpdate), "their-secret-value")
	assert.NotContains(t, dumpDB(t, h.db), "their-secret-value")
	assert.NotContains(t, fmt.Sprint(res), "their-secret-value")
}

// dumpDB renders every row of every table.
func dumpDB(t *testing.T, d *db.DB) string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table'`)
	require.NoError(t, err)
	var tables []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		tables = append(tables, n)
	}
	require.NoError(t, rows.Close())
	out := ""
	for _, tbl := range tables {
		r, err := d.Query(`SELECT * FROM "` + tbl + `"`)
		require.NoError(t, err)
		cols, err := r.Columns()
		require.NoError(t, err)
		for r.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			require.NoError(t, r.Scan(ptrs...))
			for i, v := range vals {
				if b, ok := v.([]byte); ok {
					vals[i] = string(b)
				}
			}
			out += fmt.Sprintf("%s %v\n", tbl, vals)
		}
		require.NoError(t, r.Close())
	}
	return out
}
