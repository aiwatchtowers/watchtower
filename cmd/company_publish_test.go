package cmd

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/slackapp"
	"watchtower/internal/slackmanifest"
)

const publishTestToken = "xoxe.xoxp-1-publish-config-token"

// publishFakeSlack is Slack's auth.test and apps.manifest.export/update for
// the app A0ACME in T0ACME.
type publishFakeSlack struct {
	teamID      string
	manifest    slackapp.Manifest
	updateErr   error
	teamErr     error
	creates     int
	updates     int
	calls       int
	lastLong    string
	seenTokens  []string
	afterUpdate func()
}

func (f *publishFakeSlack) Team(_ context.Context, tok string) (string, string, error) {
	f.calls++
	f.seenTokens = append(f.seenTokens, tok)
	if f.teamErr != nil {
		return "", "", f.teamErr
	}
	return f.teamID, "Acme", nil
}

func (f *publishFakeSlack) Create(context.Context, string, slackapp.Manifest) (string, string, error) {
	f.calls++
	f.creates++
	return "", "", errors.New("publish never creates an app")
}

func (f *publishFakeSlack) Update(_ context.Context, _, _ string, m slackapp.Manifest) error {
	f.calls++
	f.updates++
	if f.updateErr != nil {
		return f.updateErr
	}
	f.manifest = m
	f.lastLong = m.LongDescription()
	if f.afterUpdate != nil {
		f.afterUpdate()
	}
	return nil
}

// A draft saved while Slack was being updated is not the one published:
// it is kept.
func TestPublish_NewerDraftIsKept(t *testing.T) {
	h := newPublishHarness(t)
	h.draft(t, nil)
	h.api.afterUpdate = func() {
		h.draft(t, func(d *company.Draft) { d.DenyHosts = []string{"later.example.com"} })
	}
	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result)
	assert.NotEmpty(t, res.DraftError)
	d, st, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	require.Equal(t, company.DraftOK, st)
	assert.Equal(t, []string{"later.example.com"}, d.DenyHosts)
}

func TestPublish_InputRefusals(t *testing.T) {
	for _, in := range []string{"null", "", "[]", `{"company":"Acme"} {"company":"B"}`, `{"company":"Acme","token":"x"}`} {
		_, err := readPublishInput(strings.NewReader(in))
		assert.Error(t, err, in)
	}
	in, err := readPublishInput(strings.NewReader(" {\"company\":\" Acme \"}\n"))
	require.NoError(t, err)
	assert.Equal(t, "Acme", in.Company)

	h := newPublishHarness(t)
	h.draft(t, func(d *company.Draft) { d.Services = []string{"linear"} })
	res := h.publish(t, companyPublishInput{Company: publishTestToken})
	assert.Equal(t, publishRefused, res.Result)
	assert.Equal(t, publishReasonNoCompany, res.Reason)
	_, ok := h.stored(t)
	assert.False(t, ok)
}

func (f *publishFakeSlack) Export(_ context.Context, _, appID string) (slackapp.Manifest, error) {
	f.calls++
	if appID != "A0ACME" {
		return nil, &slackapp.SlackError{Method: "apps.manifest.export", Code: "invalid_app_id"}
	}
	return f.manifest, nil
}

type publishHarness struct {
	store company.Store
	db    *db.DB
	api   *publishFakeSlack
	steps []slackapp.Step
	warn  bytes.Buffer
}

func newPublishHarness(t *testing.T) *publishHarness {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	h := &publishHarness{
		store: company.NewStore(filepath.Join(t.TempDir(), "company")),
		db:    d,
		api: &publishFakeSlack{teamID: "T0ACME", manifest: slackapp.Manifest{
			"display_information": map[string]any{"name": "Acme Watchtower", "long_description": "theirs"},
			"oauth_config":        map[string]any{"pkce_enabled": true},
		}},
	}
	require.NoError(t, d.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0ACME", TeamName: "Acme",
		AppID: "A0ACME", ClientID: "1111.2222", LinkWritten: true}))
	return h
}

func (h *publishHarness) deps(t *testing.T) companyPublishDeps {
	return companyPublishDeps{store: h.store, database: h.db, api: h.api,
		lockPath: filepath.Join(t.TempDir(), "slack_app_setup.lock"), now: companyDraftT0,
		emit: func(s slackapp.Step) { h.steps = append(h.steps, s) }, warn: &h.warn}
}

// draft saves a draft with services and Slack's app A0ACME.
func (h *publishHarness) draft(t *testing.T, mutate func(*company.Draft)) {
	t.Helper()
	d := company.Draft{Company: "Acme", Services: []string{"slack", "linear"}, Step: "publish",
		Slack:  company.DraftSlack{AppID: "A0ACME"},
		Linear: &companybundle.Linear{ClientID: "acmelinear01"}}
	if mutate != nil {
		mutate(&d)
	}
	require.NoError(t, h.store.SaveDraft(d))
}

func (h *publishHarness) publish(t *testing.T, in companyPublishInput) companyPublishResult {
	t.Helper()
	res, err := publishCompany(context.Background(), h.deps(t), in)
	require.NoError(t, err)
	return res
}

func (h *publishHarness) draftState(t *testing.T) company.DraftState {
	t.Helper()
	_, st, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	return st
}

func (h *publishHarness) stored(t *testing.T) (companybundle.Bundle, bool) {
	t.Helper()
	e, ok, err := h.store.Get("acme", "")
	require.NoError(t, err)
	return e.Bundle, ok
}

func TestPublish_WritesLinkToDescription(t *testing.T) {
	h := newPublishHarness(t)
	h.draft(t, nil)
	// A set-aside draft goes with the draft on success.
	require.NoError(t, os.WriteFile(filepath.Join(h.store.Dir, "draft.json.bad-20261101T000000Z"), []byte("{"), 0o600))

	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result, res.Message)
	assert.Equal(t, "acme", res.Slug)
	assert.Equal(t, company.ConnectLink(res.Code), res.Link)

	b, err := companybundle.Parse(res.Code, companybundle.OriginCode)
	require.NoError(t, err, "the code is the bundle's wire form")
	assert.Equal(t, &companybundle.Slack{TeamID: "T0ACME", ClientID: "1111.2222"}, b.Slack, "Slack ids from the setup record")
	assert.Equal(t, &companybundle.Linear{ClientID: "acmelinear01"}, b.Linear)
	stored, ok := h.stored(t)
	require.True(t, ok)
	assert.Equal(t, b, stored)

	assert.Equal(t, 1, h.api.updates)
	assert.Zero(t, h.api.creates)
	assert.Contains(t, h.api.lastLong, "Watchtower for Acme — connect: "+res.Link)
	assert.Contains(t, h.api.lastLong, "Connect code: "+res.Code)
	assert.Equal(t, "Acme Watchtower", h.api.manifest["display_information"].(map[string]any)["name"], "only the About text changes")
	assert.Equal(t, []slackapp.Step{
		{Name: "pack", State: "running"}, {Name: "pack", State: "done"},
		{Name: "write_link", State: "running"}, {Name: "write_link", State: "done"},
	}, h.steps)

	assert.Equal(t, company.DraftNone, h.draftState(t), "a successful publish deletes the draft")
	matches, err := filepath.Glob(filepath.Join(h.store.Dir, "draft.json.bad-*"))
	require.NoError(t, err)
	assert.Empty(t, matches, "and any set-aside draft")
}

func TestPublishTokenExpiredKeepsSetup(t *testing.T) {
	h := newPublishHarness(t)
	h.draft(t, nil)
	h.api.updateErr = &slackapp.SlackError{Method: "apps.manifest.update", Code: "token_expired"}
	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	assert.Equal(t, publishTokenExpired, res.Result)
	assert.Equal(t, "token_expired", res.Reason)
	assert.NotEmpty(t, res.Link, "the link and code are known: the wizard can show them")
	assert.Equal(t, company.DraftOK, h.draftState(t), "the draft is kept")
	_, ok := h.stored(t)
	assert.True(t, ok, "the bundle is kept")
	assert.Equal(t, slackapp.Step{Name: "write_link", State: "failed"}, h.steps[len(h.steps)-1])

	// A fresh token publishes the same setup; the rerun stores the same bundle.
	before, _ := h.stored(t)
	h.api.updateErr = nil
	h.steps = nil
	res2 := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res2.Result)
	assert.Equal(t, res.Code, res2.Code)
	after, _ := h.stored(t)
	assert.Equal(t, before, after)
	assert.Equal(t, company.DraftNone, h.draftState(t))
}

func TestPublishNetworkFailureKeepsSetup(t *testing.T) {
	h := newPublishHarness(t)
	h.draft(t, nil)
	h.api.updateErr = errors.New("dial tcp: i/o timeout")
	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	assert.Equal(t, publishNetwork, res.Result)
	assert.Contains(t, res.Message, "i/o timeout")
	assert.Equal(t, company.DraftOK, h.draftState(t))
	_, ok := h.stored(t)
	assert.True(t, ok)
}

func TestPublish_NoSlackNeedsNoToken(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*company.Draft)
	}{
		{"not ticked", func(d *company.Draft) { d.Services = []string{"linear"}; d.Slack = company.DraftSlack{} }},
		{"skipped", func(d *company.Draft) { d.Skipped = []string{"slack"} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newPublishHarness(t)
			h.draft(t, tc.mutate)
			res := h.publish(t, companyPublishInput{Company: "Acme"})
			require.Equal(t, publishNoSlack, res.Result, res.Message)
			assert.Zero(t, h.api.calls, "Slack is never called")
			stored, ok := h.stored(t)
			require.True(t, ok)
			assert.Nil(t, stored.Slack)
			assert.NotNil(t, stored.Linear)
			assert.Equal(t, company.DraftNone, h.draftState(t), "published: the draft goes")
			assert.Equal(t, []slackapp.Step{{Name: "pack", State: "running"}, {Name: "pack", State: "done"}}, h.steps)
		})
	}
}

func TestPublish_AtlassianUncheckedRefused(t *testing.T) {
	atl := &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net", Confluence: true}
	h := newPublishHarness(t)
	h.draft(t, func(d *company.Draft) { d.Services = []string{"atlassian"}; d.Atlassian = atl })
	res := h.publish(t, companyPublishInput{Company: "Acme"})
	assert.Equal(t, publishAtlassianUnchecked, res.Result)
	assert.Equal(t, "Publish waits for the Atlassian check: sign in on the Atlassian step, or skip Atlassian.", res.Message)
	_, ok := h.stored(t)
	assert.False(t, ok, "nothing stored")
	assert.Equal(t, company.DraftOK, h.draftState(t))
	assert.Empty(t, h.steps)

	// Checked (the check stored the block): published with the stored block.
	require.NoError(t, h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme", Atlassian: atl}))
	d, _, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	require.NoError(t, h.store.MarkDraftChecked("atlassian", company.CheckHash("atlassian", d)))
	res = h.publish(t, companyPublishInput{Company: "Acme"})
	require.Equal(t, publishNoSlack, res.Result, res.Message)
	stored, _ := h.stored(t)
	assert.Equal(t, atl, stored.Atlassian)

	// Skipped: no check needed, and the block is left out.
	h2 := newPublishHarness(t)
	h2.draft(t, func(d *company.Draft) {
		d.Services = []string{"atlassian", "linear"}
		d.Atlassian = atl
		d.Skipped = []string{"atlassian"}
	})
	res = h2.publish(t, companyPublishInput{Company: "Acme"})
	require.Equal(t, publishNoSlack, res.Result, res.Message)
	stored, _ = h2.stored(t)
	assert.Nil(t, stored.Atlassian)
}

func TestPublish_DeletesDraftOnlyOnOK(t *testing.T) {
	for _, tc := range []struct {
		name   string
		setup  func(h *publishHarness)
		in     companyPublishInput
		result string
		reason string
	}{
		{"bad token", func(h *publishHarness) {
			h.api.teamErr = &slackapp.SlackError{Method: "auth.test", Code: "invalid_auth"}
		}, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishTokenExpired, "invalid_auth"},
		{"not a collaborator", func(h *publishHarness) {
			h.api.updateErr = &slackapp.SlackError{Method: "apps.manifest.update", Code: "no_permission"}
		}, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishRefused, "no_permission"},
		{"another workspace's token", func(h *publishHarness) { h.api.teamID = "T0OTHER" },
			companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishRefused, publishReasonWrongWorkspace},
		{"no token", func(*publishHarness) {}, companyPublishInput{Company: "Acme"}, publishRefused, publishReasonTokenMissing},
		{"slack step unfinished", func(h *publishHarness) {
			_, err := h.db.Exec(`DELETE FROM slack_app_setups`)
			if err != nil {
				panic(err)
			}
		}, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishRefused, publishReasonSlackApp},
		{"Google ticked, never checked", func(h *publishHarness) {
			d, _, _, err := h.store.LoadDraft(companyDraftT0)
			if err != nil {
				panic(err)
			}
			d.Services = append(d.Services, "google")
			d.Google = &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "unchecked"}
			if err := h.store.SaveDraft(d); err != nil {
				panic(err)
			}
		}, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishRefused, publishReasonIncomplete},
		{"Linear ticked without ids", func(h *publishHarness) {
			d, _, _, err := h.store.LoadDraft(companyDraftT0)
			if err != nil {
				panic(err)
			}
			d.Linear = nil
			if err := h.store.SaveDraft(d); err != nil {
				panic(err)
			}
		}, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken}, publishRefused, publishReasonIncomplete},
		{"renamed after a check stored it", func(h *publishHarness) {
			if err := h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme"}); err != nil {
				panic(err)
			}
		}, companyPublishInput{Company: "Acme Inc", ConfigToken: publishTestToken}, publishRefused, publishReasonRenamed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newPublishHarness(t)
			h.draft(t, func(d *company.Draft) { d.Slug = "acme" })
			tc.setup(h)
			res := h.publish(t, tc.in)
			assert.Equal(t, tc.result, res.Result)
			assert.Equal(t, tc.reason, res.Reason)
			assert.Equal(t, company.DraftOK, h.draftState(t), "the draft is kept")
			assert.Zero(t, h.api.creates)
		})
	}

	h := newPublishHarness(t)
	h.draft(t, nil)
	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result)
	assert.Equal(t, company.DraftNone, h.draftState(t))

	// No draft, or an unreadable one: refused, nothing written.
	res = h.publish(t, companyPublishInput{Company: "Acme"})
	assert.Equal(t, companyPublishResult{Result: publishRefused, Reason: publishReasonNoDraft, Message: res.Message}, res)
	require.NoError(t, os.WriteFile(filepath.Join(h.store.Dir, "draft.json"), []byte("{"), 0o600))
	res = h.publish(t, companyPublishInput{Company: "Acme"})
	assert.Equal(t, publishReasonDraftUnreadable, res.Reason)
}

func TestPublish_PacksCheckedBlocksAndDraftRest(t *testing.T) {
	h := newPublishHarness(t)
	checked := &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "checked-secret", Domain: "example.com"}
	require.NoError(t, h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme", Google: checked}))
	h.draft(t, func(d *company.Draft) {
		d.Slug = "acme"
		d.Services = []string{"slack", "google", "linear", "microsoft"}
		// Edited after the check: unchecked, so the stored pair is published.
		d.Google = &companybundle.Google{ClientID: "9999-zzzz.apps.googleusercontent.com", ClientSecret: "edited"}
		d.Microsoft = &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}
		d.Skipped = []string{"linear"}
		d.DenyHosts = []string{"intranet.example.com"}
	})
	res := h.publish(t, companyPublishInput{ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result, res.Message)
	b, _ := h.stored(t)
	assert.Equal(t, "Acme", b.Company, "the draft's name when none is sent")
	assert.Equal(t, checked, b.Google)
	assert.Nil(t, b.Linear, "skipped")
	assert.NotNil(t, b.Microsoft)
	assert.Equal(t, []string{"intranet.example.com"}, b.LinkDenyHosts)
}

func TestPublish_LongDescriptionUnder4000(t *testing.T) {
	h := newPublishHarness(t)
	hosts := make([]string, 0, 45)
	for i := range 45 {
		hosts = append(hosts, "host"+strings.Repeat("x", 10)+string(rune('a'+i%26))+string(rune('a'+i/26))+".example.com")
	}
	h.draft(t, func(d *company.Draft) {
		d.Services = []string{"slack", "linear", "microsoft"}
		d.Microsoft = &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}
		d.DenyHosts = hosts
	})
	res := h.publish(t, companyPublishInput{Company: "Acme", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result, res.Message)
	require.Greater(t, len(res.Code), 1500, "a bundle big enough that link + code + disclosures pass the cap")
	assert.LessOrEqual(t, utf8.RuneCountInString(h.api.lastLong), slackmanifest.MaxLongDescription)
	assert.Contains(t, h.api.lastLong, res.Link, "the link always fits")
}

func TestPublish_TokenNeverInArgvOrDraft(t *testing.T) {
	assert.Nil(t, companyPublishCmd.Flags().Lookup("config-token"))
	companyPublishCmd.Flags().VisitAll(func(f *pflag.Flag) {
		assert.NotContains(t, strings.ToLower(f.Name), "token", "the token comes on stdin only")
	})
	err := companyPublishCmd.Args(companyPublishCmd, []string{publishTestToken})
	require.Error(t, err)
	assert.NotContains(t, err.Error(), publishTestToken, "a token on argv is refused without echoing it")

	// The CLI end to end, a failing and a succeeding run: the token reaches
	// Slack and nothing else.
	cfg, home := setupSlackAppWorkspace(t)
	fake := &fakeSlackAppServer{manifest: `{"display_information":{"name":"Acme Watchtower"},"oauth_config":{"pkce_enabled":true}}`}
	fake.serve(t)
	d, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	require.NoError(t, d.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0ACME", TeamName: "Acme", AppID: "A0ACME", ClientID: "1111.2222"}))
	require.NoError(t, d.Close())
	store := company.NewStore(cfg.WorkspaceDir())
	require.NoError(t, store.SaveDraft(company.Draft{Company: "Acme", Services: []string{"slack"}, Step: "publish",
		Slack: company.DraftSlack{AppID: "A0ACME"}}))

	run := func(tok string) (string, string) {
		c := &cobra.Command{}
		c.Flags().Bool("json", true, "")
		var out, errOut bytes.Buffer
		c.SetIn(strings.NewReader(`{"company":"Acme","config_token":"` + tok + `"}`))
		c.SetOut(&out)
		c.SetErr(&errOut)
		require.NoError(t, runCompanyPublish(c, nil))
		return out.String(), errOut.String()
	}
	const wrongTok = "xoxe.xoxp-1-wrong-token"
	out, errOut := run(wrongTok)
	assert.Contains(t, out, `"result":"token_expired"`)
	assert.NotContains(t, out+errOut, wrongTok)
	draftRaw, err := os.ReadFile(filepath.Join(store.Dir, "draft.json"))
	require.NoError(t, err)
	assert.NotContains(t, string(draftRaw), wrongTok)

	out, errOut = run(slackAppTestToken)
	lines := jsonLines(t, out)
	assert.Equal(t, "ok", lines[len(lines)-1]["result"], out)
	assert.NotContains(t, out+errOut, slackAppTestToken)
	assert.Contains(t, fake.manifest, "/company/connect?b=")

	require.NoError(t, filepath.WalkDir(home, func(path string, de fs.DirEntry, err error) error {
		if err != nil || de.IsDir() {
			return err
		}
		raw, err := os.ReadFile(path) //nolint:gosec // the test's own temp HOME
		if err != nil {
			return err
		}
		for _, tok := range []string{wrongTok, slackAppTestToken} {
			assert.NotContains(t, string(raw), tok, path)
		}
		return nil
	}))
}

func TestCompanyProfile(t *testing.T) {
	store := company.NewStore(t.TempDir())
	require.NoError(t, store.Save("acme", companySample("Acme")))
	raw, err := companyProfile(store, "acme", func() string { return "00000000-0000-4000-8000-000000000000" })
	require.NoError(t, err)
	assert.Contains(t, string(raw), "<string>"+companyWire(t, companySample("Acme"))+"</string>")
	assert.Contains(t, string(raw), "com.watchtower.company.acme")

	_, err = companyProfile(store, "nobody", company.NewUUID)
	assert.ErrorContains(t, err, "no company is stored")
	require.NoError(t, store.Save("me", companybundle.Bundle{V: 1, Company: "Me", Personal: true,
		Google: &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "s"}}))
	_, err = companyProfile(store, "me", company.NewUUID)
	assert.Error(t, err)
}

func TestCompanyPublishAndProfileCLIText(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	store := company.NewStore(cfg.WorkspaceDir())
	require.NoError(t, store.SaveDraft(company.Draft{Company: "Acme", Services: []string{"linear"}, Step: "publish",
		Linear: &companybundle.Linear{ClientID: "acmelinear01"}}))
	cmdWith := func(stdin string) (*cobra.Command, *bytes.Buffer) {
		c := &cobra.Command{}
		c.Flags().Bool("json", false, "")
		c.Flags().String("slug", "acme", "")
		var out bytes.Buffer
		c.SetIn(strings.NewReader(stdin))
		c.SetOut(&out)
		c.SetErr(&bytes.Buffer{})
		return c, &out
	}
	c, out := cmdWith(`{"company":"Acme"}`)
	require.NoError(t, runCompanyPublish(c, nil))
	assert.Contains(t, out.String(), "Published acme.")
	assert.Contains(t, out.String(), "Connect link: http://127.0.0.1:18551/company/connect?b=")

	c, _ = cmdWith(`{"company":"Acme"}`)
	err := runCompanyPublish(c, nil)
	require.Error(t, err, "nothing left to publish")
	assert.Contains(t, err.Error(), "refused")

	c, _ = cmdWith(`{"company":"Acme","token":"x"}`)
	assert.Error(t, runCompanyPublish(c, nil), "unknown fields are refused")

	c, out = cmdWith("")
	require.NoError(t, runCompanyProfile(c, nil))
	assert.Contains(t, out.String(), "<key>CompanyBundle</key>")
}

func TestCompanyPublishCommandsRegistered(t *testing.T) {
	for _, name := range []string{"publish", "profile"} {
		c, _, err := companyCmd.Find([]string{name})
		require.NoError(t, err)
		assert.Equal(t, name, c.Name())
	}
}

// TestReuse_AdoptTakesSettingsURLCLI: the wizard passes the pasted settings
// URL to adopt; an app known in another workspace is wrong_workspace.
func TestReuse_AdoptTakesSettingsURLCLI(t *testing.T) {
	cfg, _ := setupSlackAppWorkspace(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "Acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE slack_accounts SET client_id = '5555.6666', status = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	require.NoError(t, database.InsertSlackAppSetup(db.SlackAppSetup{TeamID: "T0OTHER", TeamName: "Other", AppID: "A0ELSE", ClientID: "7777.8888"}))
	require.NoError(t, database.Close())
	fake := &fakeSlackAppServer{manifest: `{"display_information":{"name":"Acme Watchtower"},"oauth_config":{"pkce_enabled":true}}`}
	fake.serve(t)

	url := "https://api.slack.com/apps/A0CORP/general"
	c, out, _ := slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "app-id": url, "confirm-app-id": url})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines := jsonLines(t, out.String())
	assert.Equal(t, "ok", lines[len(lines)-1]["result"])
	assert.Equal(t, "A0CORP", lines[len(lines)-1]["app_id"])
	assert.NotContains(t, fake.calls, "apps.manifest.create")

	c, out, _ = slackAppTestCmd(slackAppTestToken+"\n", map[string]string{"json": "true", "app-id": "https://api.slack.com/apps/A0ELSE"})
	require.NoError(t, runSlackAppAdopt(c, nil))
	lines = jsonLines(t, out.String())
	assert.Equal(t, "wrong_workspace", lines[len(lines)-1]["result"])
}
