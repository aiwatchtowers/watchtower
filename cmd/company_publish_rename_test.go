package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/slackapp"
)

// renameHarness is a publish harness whose check stored "Acme" under acme
// (the draft carries the slug) and tied a Linear account to it.
func renameHarness(t *testing.T) (*publishHarness, int64) {
	t.Helper()
	h := newPublishHarness(t)
	require.NoError(t, h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme", Linear: &companybundle.Linear{ClientID: "acmelinear01"}}))
	h.draft(t, func(d *company.Draft) { d.Slug = "acme" })
	id, err := h.db.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	return h, id
}

func (h *publishHarness) publishWith(t *testing.T, forced, buildCompany string, in companyPublishInput) companyPublishResult {
	t.Helper()
	deps := h.deps(t)
	deps.forced, deps.buildCompany = forced, buildCompany
	res, err := publishCompany(t.Context(), deps, in)
	require.NoError(t, err)
	return res
}

// assertOnlyAcme: one company file, acme.json, holding name; the Linear
// account still tied to acme.
func assertOnlyAcme(t *testing.T, h *publishHarness, linearID int64, name string) {
	t.Helper()
	entries, errs, err := h.store.LoadAll("")
	require.NoError(t, err)
	require.Empty(t, errs)
	require.Len(t, entries, 1)
	assert.Equal(t, "acme", entries[0].Slug, "the slug and the file name stay")
	assert.Equal(t, name, entries[0].Bundle.Company)
	refs, err := h.db.AccountsByCompany("acme")
	require.NoError(t, err)
	require.Len(t, refs, 1, "the account's company tie stays")
	assert.Equal(t, linearID, refs[0].ID)
}

// Ask #1613: Publish under a name edited after a check stored the setup
// changes only the display name.
func TestPublish_RenameChangesOnlyTheDisplayName(t *testing.T) {
	h, id := renameHarness(t)
	res := h.publish(t, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result, res.Message)
	assert.Equal(t, "acme", res.Slug)
	b, err := companybundle.Parse(res.Code, companybundle.OriginCode)
	require.NoError(t, err)
	assert.Equal(t, "Acme Corp", b.Company, "the link carries the new name")
	assert.Contains(t, h.api.lastLong, "Watchtower for Acme Corp\n\nHow to connect\n1. Open Watchtower.\n2. Click this link: "+res.Link)
	assertOnlyAcme(t, h, id, "Acme Corp")
	assert.Equal(t, company.DraftNone, h.draftState(t), "the published draft is deleted")
	assert.Empty(t, res.DraftError)
}

// A crash after the draft took the new name and before the bundle was
// stored: the rerun (the wizard reopens the draft, so no name is sent)
// renames the bundle.
func TestPublish_RenameRerunAfterCrashBeforeBundle(t *testing.T) {
	h, id := renameHarness(t)
	d, _, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	require.NoError(t, h.store.SetDraftCompany(d, "Acme Corp"))
	res := h.publish(t, companyPublishInput{ConfigToken: publishTestToken})
	require.Equal(t, publishOK, res.Result, res.Message)
	assertOnlyAcme(t, h, id, "Acme Corp")
}

// A failure after the renamed bundle was stored (here Slack's token
// expired; a crash before the Slack write is the same state) keeps the
// renamed bundle and the renamed draft; the rerun stores the same bundle
// and writes the link.
func TestPublish_RenameRerunAfterFailureAfterBundle(t *testing.T) {
	h, id := renameHarness(t)
	h.api.teamErr = &slackapp.SlackError{Method: "auth.test", Code: "invalid_auth"}
	res := h.publish(t, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
	require.Equal(t, publishTokenExpired, res.Result)
	assert.Equal(t, "acme", res.Slug)
	assertOnlyAcme(t, h, id, "Acme Corp")
	d, st, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	require.Equal(t, company.DraftOK, st)
	assert.Equal(t, "Acme Corp", d.Company, "the draft took the name, so a reopened wizard shows it")
	assert.Equal(t, "acme", d.Slug)

	h.api.teamErr = nil
	again := h.publish(t, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
	require.Equal(t, publishOK, again.Result, again.Message)
	assert.Equal(t, res.Code, again.Code, "the rerun publishes the same bundle")
	assertOnlyAcme(t, h, id, "Acme Corp")
	assert.Equal(t, company.DraftNone, h.draftState(t))
}

// A name another company holds is refused before anything is written.
func TestPublish_RenameToATakenNameIsRefused(t *testing.T) {
	otherCorp := companybundle.Bundle{V: 1, Company: "Acme Corp", Linear: &companybundle.Linear{ClientID: "otherlinear01"}}
	for _, tc := range []struct {
		name    string
		setup   func(t *testing.T, h *publishHarness)
		forced  string
		build   string
		reason  string
		message string
	}{
		{name: "another stored company", reason: publishReasonNameTaken, message: "another company",
			setup: func(t *testing.T, h *publishHarness) { require.NoError(t, h.store.Save("acme-corp", otherCorp)) }},
		{name: "a personal Google project", reason: publishReasonNameTaken, message: "own Google project",
			setup: func(t *testing.T, h *publishHarness) {
				require.NoError(t, h.store.Save("acme-corp", companybundle.Bundle{V: 1, Company: "Acme Corp", Personal: true,
					Google: &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "s"}}))
			}},
		{name: "the forced MDM company", reason: publishReasonNameTaken, message: "another company",
			forced: mustEncode(t, otherCorp), setup: func(*testing.T, *publishHarness) {}},
		{name: "the company the MDM bundle forces is renamed", reason: publishReasonForced, message: "organization sets",
			forced: mustEncode(t, companybundle.Bundle{V: 1, Company: "Acme", Linear: &companybundle.Linear{ClientID: "acmelinear01"}}),
			setup:  func(*testing.T, *publishHarness) {}},
		{name: "the corp build's baked company is renamed", reason: publishReasonForced, message: "organization sets",
			build: "Acme", setup: func(*testing.T, *publishHarness) {}},
		{name: "a company forced before pins the name", reason: publishReasonNameTaken, message: "another company",
			setup: func(t *testing.T, h *publishHarness) {
				require.NoError(t, os.WriteFile(filepath.Join(h.store.Dir, ".forced-acme-corp.seen"),
					[]byte(`{"v":1,"company":"Acme Corp","linear":{"client_id":"otherlinear01"}}`), 0o600))
			}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, _ := renameHarness(t)
			tc.setup(t, h)
			res := h.publishWith(t, tc.forced, tc.build, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
			assert.Equal(t, publishRefused, res.Result)
			assert.Equal(t, tc.reason, res.Reason)
			assert.Contains(t, res.Message, tc.message)
			b, ok := h.stored(t)
			require.True(t, ok)
			assert.Equal(t, "Acme", b.Company, "nothing renamed")
			d, _, _, err := h.store.LoadDraft(companyDraftT0)
			require.NoError(t, err)
			assert.Equal(t, "Acme", d.Company, "the draft keeps its name")
			assert.Zero(t, h.api.calls, "nothing reached Slack")
		})
	}
}

// The name check is repeated under the file's lock: a company that took
// the name after the early check (or an MDM bundle that arrived) is
// refused there with its own reason, and nothing is renamed.
func TestPublish_StoreRefusalsUnderTheLock(t *testing.T) {
	h, _ := renameHarness(t)
	stored, ok, err := h.store.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	renamed := stored.Bundle
	renamed.Company = "Acme Corp"

	require.NoError(t, h.store.Save("acme-corp", companybundle.Bundle{V: 1, Company: "Acme Corp", Linear: &companybundle.Linear{ClientID: "otherlinear01"}}))
	r := storePublishedBundle(h.deps(t), "acme", stored, true, renamed)
	require.NotNil(t, r)
	assert.Equal(t, publishReasonNameTaken, r.Reason)

	deps := h.deps(t)
	deps.forced = mustEncode(t, stored.Bundle)
	renamed.Company = "Acme Two"
	r = storePublishedBundle(deps, "acme", stored, true, renamed)
	require.NotNil(t, r)
	assert.Equal(t, publishReasonForced, r.Reason)

	// A check that stored meanwhile wins.
	require.NoError(t, h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme"}))
	r = storePublishedBundle(h.deps(t), "acme", stored, true, renamed)
	require.NotNil(t, r)
	assert.Equal(t, publishReasonStoredChanged, r.Reason)
	b, _ := h.stored(t)
	assert.Equal(t, "Acme", b.Company)
}

// A refusal at the bundle's write, after the draft took the new name,
// gives the draft its old name back: another company taking the name, or a
// check storing the file, between the early check and the locked write.
func TestPublish_RefusedWriteRestoresTheDraftName(t *testing.T) {
	for _, tc := range []struct {
		name   string
		race   func(t *testing.T, h *publishHarness)
		reason string
	}{
		{"name taken meanwhile", func(t *testing.T, h *publishHarness) {
			require.NoError(t, h.store.Save("acme-corp", companybundle.Bundle{V: 1, Company: "Acme Corp", Linear: &companybundle.Linear{ClientID: "otherlinear01"}}))
		}, publishReasonNameTaken},
		{"a check stored meanwhile", func(t *testing.T, h *publishHarness) {
			require.NoError(t, h.store.Save("acme", companybundle.Bundle{V: 1, Company: "Acme", Linear: &companybundle.Linear{ClientID: "acmelinear02"}}))
		}, publishReasonStoredChanged},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, _ := renameHarness(t)
			deps := h.deps(t)
			deps.emit = func(s slackapp.Step) {
				if s.Name == publishStepPack && s.State == slackapp.StateRunning {
					tc.race(t, h)
				}
			}
			res, err := publishCompany(t.Context(), deps, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
			require.NoError(t, err)
			assert.Equal(t, publishRefused, res.Result)
			assert.Equal(t, tc.reason, res.Reason)
			assert.Empty(t, res.Slug, "nothing stored")
			b, _ := h.stored(t)
			assert.Equal(t, "Acme", b.Company)
			d, _, _, err := h.store.LoadDraft(companyDraftT0)
			require.NoError(t, err)
			assert.Equal(t, "Acme", d.Company, "the draft has its name back")
		})
	}
}

// Another publish under the same new name stored the bundle first: this one
// is refused, and the draft keeps the new name the stored bundle has.
func TestPublish_ConcurrentRenameKeepsTheDraftName(t *testing.T) {
	h, _ := renameHarness(t)
	deps := h.deps(t)
	deps.emit = func(s slackapp.Step) {
		if s.Name == publishStepPack && s.State == slackapp.StateRunning {
			require.NoError(t, h.store.SaveRenamed("acme", companybundle.Bundle{V: 1, Company: "Acme", Linear: &companybundle.Linear{ClientID: "acmelinear01"}},
				companybundle.Bundle{V: 1, Company: "Acme Corp", Linear: &companybundle.Linear{ClientID: "acmelinear01"}}, ""))
		}
	}
	res, err := publishCompany(t.Context(), deps, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
	require.NoError(t, err)
	assert.Equal(t, publishReasonStoredChanged, res.Reason)
	d, _, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	assert.Equal(t, "Acme Corp", d.Company)
}

// A draft saved between the publish's read and its rename is not renamed.
func TestPublish_DraftSavedMeanwhileIsNotRenamed(t *testing.T) {
	h, _ := renameHarness(t)
	deps := h.deps(t)
	deps.emit = func(s slackapp.Step) {
		if s.Name == publishStepPack && s.State == slackapp.StateRunning {
			h.draft(t, func(d *company.Draft) { d.Slug = "acme"; d.DenyHosts = []string{"later.example.com"} })
		}
	}
	res, err := publishCompany(t.Context(), deps, companyPublishInput{Company: "Acme Corp", ConfigToken: publishTestToken})
	require.NoError(t, err)
	assert.Equal(t, publishReasonStoredChanged, res.Reason)
	b, _ := h.stored(t)
	assert.Equal(t, "Acme", b.Company)
	d, _, _, err := h.store.LoadDraft(companyDraftT0)
	require.NoError(t, err)
	assert.Equal(t, "Acme", d.Company)
	assert.Equal(t, []string{"later.example.com"}, d.DenyHosts)
}

func mustEncode(t *testing.T, b companybundle.Bundle) string {
	t.Helper()
	w, err := companybundle.Encode(b)
	require.NoError(t, err)
	return w
}
