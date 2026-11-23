package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/slackapp"
)

const (
	slackAppTestToken  = "xoxe.xoxp-1-test-config-token"
	slackAppTestSecret = "f4k3-client-secret-0123456789"
)

// fakeSlackAppServer is Slack's auth.test and apps.manifest.* over HTTP; its
// create answer carries a client secret, signing secret and verification token.
type fakeSlackAppServer struct {
	mu       sync.Mutex
	garbled  bool // the create answer is unreadable (made the app, answer lost)
	manifest string
	calls    []string
}

func (f *fakeSlackAppServer) serve(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		defer f.mu.Unlock()
		method := strings.TrimPrefix(r.URL.Path, "/")
		f.calls = append(f.calls, method)
		if r.Header.Get("Authorization") != "Bearer "+slackAppTestToken {
			_, _ = w.Write([]byte(`{"ok":false,"error":"invalid_auth"}`))
			return
		}
		switch method {
		case "auth.test":
			_, _ = w.Write([]byte(`{"ok":true,"team_id":"T0ACME","team":"Acme","expires_in":43200}`))
		case "apps.manifest.create":
			f.manifest = r.PostForm.Get("manifest")
			if f.garbled {
				_, _ = w.Write([]byte(`{"ok":true,"app_id":"A0NEW","credentials":{"client_secret":"` + slackAppTestSecret))
				return
			}
			_, _ = fmt.Fprintf(w, `{"ok":true,"app_id":"A0NEW","credentials":{"client_id":"1111.2222","client_secret":%q,"verification_token":"vt-%s","signing_secret":"ss-%s"},"oauth_authorize_url":"https://slack.com/oauth/v2/authorize?client_id=1111.2222","team_id":"T0ACME","team_domain":"acme"}`,
				slackAppTestSecret, slackAppTestSecret, slackAppTestSecret)
		case "apps.manifest.export":
			_, _ = fmt.Fprintf(w, `{"ok":true,"manifest":%s}`, f.manifest)
		case "apps.manifest.update":
			f.manifest = r.PostForm.Get("manifest")
			_, _ = w.Write([]byte(`{"ok":true,"app_id":"A0NEW","permissions_updated":false}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	old := slackAppAPI
	slackAppAPI = func() slackapp.API { return slackapp.NewClient(srv.URL) }
	t.Cleanup(func() { slackAppAPI = old })
}

func setupSlackAppWorkspace(t *testing.T) (*config.Config, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	require.NoError(t, database.Close())
	return cfg, home
}

func slackAppTestCmd(stdin string, flags map[string]string) (*cobra.Command, *bytes.Buffer, *bytes.Buffer) {
	c := &cobra.Command{}
	c.Flags().Bool("json", false, "")
	c.Flags().String("app-id", "", "")
	c.Flags().String("confirm-app-id", "", "")
	c.Flags().String("team", "", "")
	c.Flags().Bool("clear", false, "")
	c.Flags().Bool("attach", false, "")
	c.Flags().String("client-id", "", "")
	c.Flags().Bool("enable-pkce", false, "")
	c.Flags().Bool("dry-run", false, "")
	c.Flags().Bool("new-app", false, "")
	for k, v := range flags {
		_ = c.Flags().Set(k, v)
	}
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	c.SetIn(strings.NewReader(stdin))
	c.SetOut(out)
	c.SetErr(errOut)
	return c, out, errOut
}

// jsonLines decodes each line of out.
func jsonLines(t *testing.T, out string) []map[string]any {
	t.Helper()
	var lines []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		var m map[string]any
		require.NoError(t, json.Unmarshal([]byte(l), &m), l)
		lines = append(lines, m)
	}
	return lines
}

func TestAppSetup_CreateJSONLines(t *testing.T) {
	setupSlackAppWorkspace(t)
	(&fakeSlackAppServer{}).serve(t)
	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	lines := jsonLines(t, out.String())
	require.Len(t, lines, 7)
	assert.Equal(t, map[string]any{"step": "check_token", "state": "running"}, lines[0])
	assert.Equal(t, map[string]any{"step": "write_link", "state": "done"}, lines[5])
	assert.Equal(t, map[string]any{"result": "ok", "team_id": "T0ACME", "team_name": "Acme", "app_id": "A0NEW",
		"client_id": "1111.2222", "link_written": true}, lines[6])

	sc, sout, _ := slackAppTestCmd("", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppStatus(sc, nil))
	assert.JSONEq(t, `{"setups":[{"team_id":"T0ACME","team_name":"Acme","app_id":"A0NEW","client_id":"1111.2222",
		"connected":false,"link_written":true,"install_requested":false,"stage":"install"}]}`, sout.String())
}

func TestAppSetup_SecretNeverStored(t *testing.T) {
	cfg, home := setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{}
	fake.serve(t)
	c, out, errOut := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	require.Contains(t, out.String(), `"result":"ok"`)
	require.Contains(t, fake.calls, "apps.manifest.create")

	for _, secret := range []string{slackAppTestSecret, slackAppTestToken} {
		assert.NotContains(t, out.String(), secret)
		assert.NotContains(t, errOut.String(), secret)
	}
	root, err := os.OpenRoot(home)
	require.NoError(t, err)
	defer func() { _ = root.Close() }()
	require.NoError(t, fs.WalkDir(root.FS(), ".", func(path string, d fs.DirEntry, err error) error {
		require.NoError(t, err)
		if d.IsDir() {
			return nil
		}
		b, err := fs.ReadFile(root.FS(), path)
		require.NoError(t, err)
		assert.NotContains(t, string(b), slackAppTestSecret, path)
		assert.NotContains(t, string(b), slackAppTestToken, path)
		return nil
	}))
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	dump := dumpEveryTable(t, database)
	assert.Contains(t, dump, "1111.2222", "the dump does reach the setup record")
	assert.NotContains(t, dump, slackAppTestSecret)
	assert.NotContains(t, dump, slackAppTestToken)
}

// dumpEveryTable renders every row of every table as text.
func dumpEveryTable(t *testing.T, d *db.DB) string {
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

func TestAppSetup_TokenNeverInArgv(t *testing.T) {
	for _, c := range []*cobra.Command{slackAppCreateCmd, slackAppAdoptCmd, slackAppLinkCmd} {
		c.Flags().VisitAll(func(f *pflag.Flag) {
			assert.NotContains(t, strings.ToLower(f.Name), "token", c.Name())
		})
		err := c.Args(c, []string{slackAppTestToken})
		require.Error(t, err, c.Name())
		assert.NotContains(t, err.Error(), slackAppTestToken, "the refusal does not echo the token")
		require.NoError(t, c.Args(c, nil))
	}
}

func TestAppSetup_EmptyStdinRefused(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{}
	fake.serve(t)
	c, _, _ := slackAppTestCmd("\n", map[string]string{"json": "true"})
	err := runSlackAppCreate(c, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "stdin")
	assert.Empty(t, fake.calls)
}

func TestAppSetup_BadTokenCLI(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{}
	fake.serve(t)
	c, out, _ := slackAppTestCmd("xoxe.wrong\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "bad_token", lines[len(lines)-1]["result"])
	assert.Equal(t, []string{"auth.test"}, fake.calls)

	h, _, _ := slackAppTestCmd("xoxe.wrong\n", nil)
	err := runSlackAppCreate(h, nil)
	require.Error(t, err, "without --json a failed setup exits non-zero")
	assert.Contains(t, err.Error(), "bad_token")
}

func TestAppSetup_LostCreateAnswerCLI(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{garbled: true}
	fake.serve(t)
	for range 2 {
		c, out, errOut := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
		require.NoError(t, runSlackAppCreate(c, nil))
		lines := jsonLines(t, out.String())
		assert.Equal(t, "pending_create", lines[len(lines)-1]["result"])
		assert.NotContains(t, out.String()+errOut.String(), slackAppTestSecret)
	}
	creates := 0
	for _, m := range fake.calls {
		if m == "apps.manifest.create" {
			creates++
		}
	}
	assert.Equal(t, 1, creates, "the second run never creates")

	sc, sout, _ := slackAppTestCmd("", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppStatus(sc, nil))
	assert.Contains(t, sout.String(), `"stage":"pending_create"`)
}

func TestAppSetup_RetiredAndBuiltinIDsWired(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	setSlackBuild(t, "5555.6666", "test-secret", "9999.0000")
	c, _, _ := slackAppTestCmd("", nil)
	r, _ := newSlackAppRunner(c, cfg, nil, false)
	assert.Equal(t, "9999.0000", r.RetiredClientID)
	assert.Equal(t, "5555.6666", r.BuiltinClientID)
	setSlackBuild(t, "5555.6666", "", "")
	r, _ = newSlackAppRunner(c, cfg, nil, false)
	assert.Empty(t, r.BuiltinClientID, "an id without a secret is no built-in app")
}

// A corp build adopting its own baked app (review M1): refused with the
// builtin_app_pkce_deferred kind even with --enable-pkce; nothing is read
// or changed on Slack's side.
func TestAppSetup_AdoptBuiltinAppDeferredCLI(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	setSlackBuild(t, "5555.6666", "test-secret", "")
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE slack_accounts SET client_id = '5555.6666', app_id = 'A0CORP', status = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	fake := &fakeSlackAppServer{manifest: `{"display_information":{"name":"Acme Watchtower"},"oauth_config":{"scopes":{"user":[]}}}`}
	fake.serve(t)

	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "team": "T0ACME", "enable-pkce": "true"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "builtin_app_pkce_deferred", lines[len(lines)-1]["result"])
	assert.Equal(t, []string{"auth.test"}, fake.calls, "nothing exported or updated")

	c, _, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"team": "T0ACME", "enable-pkce": "true"})
	err = runSlackAppAdopt(c, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "later Watchtower update")
}

// The one-release Task 18 corp build (ask #1632) keeps the corp app's client
// id without its secret: no built-in app, so create offers the adopt and
// TestAppSetup_CreateNewAppCLI: --new-app creates a second app where the
// workspace's company app answers existing_app.
func TestAppSetup_CreateNewAppCLI(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE slack_accounts SET client_id = '5555.6666', status = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	fake := &fakeSlackAppServer{}
	fake.serve(t)

	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "existing_app", lines[len(lines)-1]["result"])

	c, out, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "new-app": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	lines = jsonLines(t, out.String())
	assert.Equal(t, "ok", lines[len(lines)-1]["result"], "--new-app creates the second app")
}

// adopt with --enable-pkce turns PKCE on instead of answering
// builtin_app_pkce_deferred.
func TestAppSetup_CorpIDWithoutSecretNotDeferredCLI(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	setSlackBuild(t, "5555.6666", "", "")
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE slack_accounts SET client_id = '5555.6666', app_id = 'A0CORP', status = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	fake := &fakeSlackAppServer{manifest: `{"display_information":{"name":"Acme Watchtower"},"oauth_config":{"scopes":{"user":[]}}}`}
	fake.serve(t)

	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "existing_app", lines[len(lines)-1]["result"], "create offers the adopt")

	c, out, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "team": "T0ACME", "enable-pkce": "true"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines = jsonLines(t, out.String())
	assert.Equal(t, "ok", lines[len(lines)-1]["result"])
	assert.Contains(t, fake.calls, "apps.manifest.update")
	assert.Contains(t, fake.manifest, `"pkce_enabled":true`)
}

func TestAppSetup_PendingCLI(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{garbled: true}
	fake.serve(t)
	c, _, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))

	for _, flags := range []map[string]string{
		{"clear": "true"},
		{"team": "T0ACME"},
		{"team": "T0ACME", "clear": "true", "attach": "true"},
		{"team": "T0ACME", "clear": "true", "app-id": "A0NEW"},
	} {
		pc, _, _ := slackAppTestCmd("", flags)
		require.Error(t, runSlackAppPending(pc, nil), "%v", flags)
	}

	pc, out, _ := slackAppTestCmd("", map[string]string{"json": "true", "team": "T0ACME", "attach": "true", "app-id": "A0NEW", "client-id": "bad"})
	require.NoError(t, runSlackAppPending(pc, nil))
	assert.Equal(t, "bad_ids", jsonLines(t, out.String())[0]["result"])

	pc, out, _ = slackAppTestCmd("", map[string]string{"json": "true", "team": "T0ACME", "attach": "true", "app-id": "A0NEW", "client-id": "1111.2222"})
	require.NoError(t, runSlackAppPending(pc, nil))
	last := jsonLines(t, out.String())[0]
	assert.Equal(t, "ok", last["result"])
	assert.Equal(t, "A0NEW", last["app_id"])

	sc, sout, _ := slackAppTestCmd("", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppStatus(sc, nil))
	assert.Contains(t, sout.String(), `"stage":"install"`)

	pc, out, _ = slackAppTestCmd("", map[string]string{"json": "true", "team": "T0ACME", "clear": "true"})
	require.NoError(t, runSlackAppPending(pc, nil))
	assert.Equal(t, "no_pending", jsonLines(t, out.String())[0]["result"])
}

func TestAppSetup_PendingAttachHumanNextStep(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{garbled: true}
	fake.serve(t)
	c, _, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true"})
	require.NoError(t, runSlackAppCreate(c, nil))
	pc, out, _ := slackAppTestCmd("", map[string]string{"team": "T0ACME", "attach": "true", "app-id": "A0NEW", "client-id": "1111.2222"})
	require.NoError(t, runSlackAppPending(pc, nil))
	assert.Contains(t, out.String(), "slack app link")
	assert.NotContains(t, out.String(), "ready")
}

func TestAppSetup_AdoptWrongTeamCLI(t *testing.T) {
	setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{}
	fake.serve(t)
	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "team": "T0OTHER"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "wrong_team", lines[len(lines)-1]["result"])
	assert.Equal(t, []string{"auth.test"}, fake.calls, "nothing exported or updated")
	require.NotNil(t, slackAppAdoptCmd.Flags().Lookup("team"), "the Desktop passes --team to adopt")
}

// TestAppSetup_AdoptPKCEConsentCLI: adopt without --enable-pkce changes
// nothing on an app without PKCE and says so; with it, PKCE is turned on.
func TestAppSetup_AdoptPKCEConsentCLI(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE slack_accounts SET client_id = '5555.6666', app_id = 'A0CORP', status = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	fake := &fakeSlackAppServer{manifest: `{"display_information":{"name":"Acme Watchtower"},"oauth_config":{"scopes":{"user":[]}}}`}
	fake.serve(t)

	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "team": "T0ACME"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "needs_pkce_consent", lines[len(lines)-1]["result"])
	assert.NotContains(t, fake.calls, "apps.manifest.update", "nothing changed without --enable-pkce")

	c, _, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"team": "T0ACME"})
	err = runSlackAppAdopt(c, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--enable-pkce")

	c, out, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "team": "T0ACME", "enable-pkce": "true"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines = jsonLines(t, out.String())
	assert.Equal(t, "ok", lines[len(lines)-1]["result"])
	assert.Contains(t, fake.manifest, `"pkce_enabled":true`)
	require.NotNil(t, slackAppAdoptCmd.Flags().Lookup("enable-pkce"))
	assert.Contains(t, slackAppAdoptCmd.Long, "only Slack support can turn it off")
}
