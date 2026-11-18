package cmd

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// companySample is a full bundle of made-up ids.
func companySample(name string) companybundle.Bundle {
	return companybundle.Bundle{
		V: 1, Company: name,
		Slack:     &companybundle.Slack{TeamID: "T0000", ClientID: "000.000"},
		Google:    &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret", Domain: "example.com"},
		Atlassian: &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net", Confluence: true},
		Linear:    &companybundle.Linear{ClientID: "acmelinear01"},
		Microsoft: &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"},
	}
}

func companyWire(t *testing.T, b companybundle.Bundle) string {
	t.Helper()
	w, err := companybundle.Encode(b)
	require.NoError(t, err)
	return w
}

// companyAccounts ties one account per source to slug.
func companyAccounts(t *testing.T, d *db.DB, slug string) map[string]int64 {
	t.Helper()
	ids := map[string]int64{}
	var err error
	ids["slack"], err = d.CreateSlackAccount(db.SlackAccount{TeamID: "T0000", TeamName: "Acme", CompanySlug: slug})
	require.NoError(t, err)
	ids["google"], err = d.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: slug})
	require.NoError(t, err)
	ids["jira"], err = d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", CompanySlug: slug})
	require.NoError(t, err)
	ids["linear"], err = d.CreateLinearAccountForCompany("Acme", slug)
	require.NoError(t, err)
	ids["outlook"], err = d.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Security: "ssl", CompanySlug: slug})
	require.NoError(t, err)
	return ids
}

func TestCompanyConfirm_NewIsStoredThenUnchanged(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	w := companyWire(t, companySample("Acme"))
	res, err := confirmCompany(store, d, w, companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, companyConfirmResult{Result: "stored", Slug: "acme", Marked: []companyMarkedJSON{}}, res)
	got, ok, err := store.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, companySample("Acme"), got.Bundle)

	res, err = confirmCompany(store, d, w, companybundle.OriginCode, false, "")
	require.NoError(t, err)
	assert.Equal(t, "unchanged", res.Result)
}

func TestCompanyConfirm_ChangedNeedsReplace(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	require.NoError(t, store.Save("acme", companySample("Acme")))
	ids := companyAccounts(t, d, "acme")
	path := filepath.Join(store.Dir, "acme.json")
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	in := companySample("Acme")
	in.Atlassian.ClientID = "acmeClientId02"
	res, err := confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, companyConfirmResult{Result: "needs_replace", Slug: "acme", Marked: []companyMarkedJSON{}}, res)

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, before, after, "no write without --replace")
	j, err := d.GetJiraAccount(ids["jira"])
	require.NoError(t, err)
	assert.Equal(t, "ok", j.Status)
}

func TestCompanyConfirm_OtherFieldsStoreWithoutReplace(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	require.NoError(t, store.Save("acme", companySample("Acme")))
	in := companySample("Acme")
	in.Google.Domain = "acme.example.com"
	in.LinkDenyHosts = []string{"intranet.example.com"}
	res, err := confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, "stored", res.Result)
	got, _, err := store.Get("acme", "")
	require.NoError(t, err)
	assert.Equal(t, in, got.Bundle)
}

func TestCompanyConfirm_ReplaceMarksChangedVendorsOnly(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	require.NoError(t, store.Save("acme", companySample("Acme")))
	require.NoError(t, store.Save("beta", companySample("Beta")))
	acme := companyAccounts(t, d, "acme")
	companyAccounts(t, d, "beta")

	in := companySample("Acme")
	in.Atlassian.ClientSecret = "rotated-secret"
	in.Microsoft.TenantID = "example.com"
	res, err := confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, true, "")
	require.NoError(t, err)
	assert.Equal(t, "stored", res.Result)
	assert.Equal(t, []companyMarkedJSON{{Source: "jira", ID: acme["jira"]}, {Source: "outlook", ID: acme["outlook"]}}, res.Marked)

	got, _, err := store.Get("acme", "")
	require.NoError(t, err)
	assert.Equal(t, in, got.Bundle)

	refs, err := d.AccountsByCompany("acme")
	require.NoError(t, err)
	for _, r := range refs {
		if r.Source == "jira" || r.Source == "outlook" {
			assert.Equal(t, "error", r.Status, r.Source)
			assert.Equal(t, "company_changed_app", r.Error, r.Source)
		} else {
			assert.Equal(t, "ok", r.Status, r.Source)
		}
	}
	refs, err = d.AccountsByCompany("beta")
	require.NoError(t, err)
	for _, r := range refs {
		assert.Equal(t, "ok", r.Status, "another company's %s account", r.Source)
	}

	// The same bundle again is unchanged, and marks nothing more.
	res, err = confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, true, "")
	require.NoError(t, err)
	assert.Equal(t, companyConfirmResult{Result: "unchanged", Slug: "acme", Marked: []companyMarkedJSON{}}, res)
}

func TestCompanyConfirm_DifferentCompanySameSlackTeamIsSeparate(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	_, err := confirmCompany(store, d, companyWire(t, companySample("Acme")), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	other := companySample("Acme Labs")
	other.Slack.ClientID = "111.222"
	res, err := confirmCompany(store, d, companyWire(t, other), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, companyConfirmResult{Result: "stored", Slug: "acme-labs", Marked: []companyMarkedJSON{}}, res)

	entries, errs, err := store.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, errs)
	require.Len(t, entries, 2)
	assert.Equal(t, "000.000", entries[0].Bundle.Slack.ClientID)
	assert.Equal(t, "111.222", entries[1].Bundle.Slack.ClientID)

	// Names that slug alike stay apart too.
	res, err = confirmCompany(store, d, companyWire(t, companySample("ACME")), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, "acme-2", res.Slug)
}

func TestCompanyConfirm_ForcedIsNeverWritten(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	forced := companyWire(t, companySample("Acme"))

	res, err := confirmCompany(store, d, forced, companybundle.OriginMDM, false, forced)
	require.NoError(t, err)
	assert.Equal(t, companyConfirmResult{Result: "unchanged", Slug: "acme", Marked: []companyMarkedJSON{}}, res)
	_, err = os.Stat(store.Dir)
	assert.True(t, os.IsNotExist(err), "MDM never writes a file")

	// A link for the forced company changes nothing: the forced bundle wins.
	in := companySample("Acme")
	in.Atlassian.ClientID = "acmeClientId02"
	for _, replace := range []bool{false, true} {
		res, err = confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, replace, forced)
		require.NoError(t, err)
		assert.Equal(t, "unchanged", res.Result)
	}
	_, err = os.Stat(store.Dir)
	assert.True(t, os.IsNotExist(err))

	// --source mdm with a bundle that is not the forced one is refused.
	_, err = confirmCompany(store, d, companyWire(t, in), companybundle.OriginMDM, false, forced)
	assert.Error(t, err)
	_, err = confirmCompany(store, d, forced, companybundle.OriginMDM, false, "")
	assert.Error(t, err)
}

func TestCompanyConfirm_RefusedBundleIsError(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	_, err := confirmCompany(store, d, "!!!", companybundle.OriginCode, false, "")
	assert.ErrorContains(t, err, "damaged")
}

func TestCompanyInspect_StatesConnectedAndChanges(t *testing.T) {
	policytest.Set(t, nil)
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)

	res, err := inspectCompany(store, d, companyWire(t, companySample("Acme")), "")
	require.NoError(t, err)
	assert.Equal(t, "new", res.State)
	assert.Equal(t, "acme", res.Slug)
	assert.Equal(t, []string{"slack", "google", "atlassian", "microsoft", "linear"}, res.Vendors)
	assert.Empty(t, res.Connected)
	_, err = os.Stat(store.Dir)
	assert.True(t, os.IsNotExist(err), "inspect stores nothing")

	require.NoError(t, store.Save("acme", companySample("Acme")))
	ids := companyAccounts(t, d, "acme")
	require.NoError(t, d.SetLinearAccountRemoved(ids["linear"]))
	res, err = inspectCompany(store, d, companyWire(t, companySample("Acme")), "")
	require.NoError(t, err)
	assert.Equal(t, "same", res.State)
	assert.Equal(t, map[string]bool{"slack": true, "google": true, "atlassian": true, "microsoft": true}, res.Connected)

	in := companySample("Acme")
	in.Atlassian.ClientID = "acmeClientId02"
	in.Google.ClientSecret = "rotated-secret"
	res, err = inspectCompany(store, d, companyWire(t, in), "")
	require.NoError(t, err)
	assert.Equal(t, "changed", res.State)
	assert.Equal(t, []companyChangeJSON{
		{Vendor: "google", Field: "client_secret"},
		{Vendor: "atlassian", Field: "client_id", Old: "acme…d01", New: "acme…d02"},
	}, res.Changes)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), "secret\":\"", "no secret value in the output")
	assert.NotContains(t, string(raw), "rotated-secret")
	assert.NotContains(t, string(raw), "sample-secret")
}

func TestCompanyInspect_ForbiddenVendorListed(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"slack", "google"}})
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	res, err := inspectCompany(store, d, companyWire(t, companySample("Acme")), "")
	require.NoError(t, err)
	assert.Equal(t, []string{"atlassian", "microsoft", "linear"}, res.Forbidden)
}

func TestCompanyInspect_RefusedIsAResult(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	raw := `{"v":2,"company":"Acme"}`
	w := base64.RawURLEncoding.EncodeToString([]byte(raw))
	res, err := inspectCompany(store, d, w, "")
	require.NoError(t, err)
	assert.Equal(t, "newer_version", res.Refused)
}

func TestReadCompanyWire_StripsWrappedCode(t *testing.T) {
	w := companyWire(t, companySample("Acme"))
	var wrapped strings.Builder
	for i := 0; i < len(w); i += 60 {
		wrapped.WriteString(w[i:min(i+60, len(w))])
		wrapped.WriteString("\r\n  ")
	}
	got, err := readCompanyWire(strings.NewReader(" \n" + wrapped.String() + "\n"))
	require.NoError(t, err)
	assert.Equal(t, w, got)

	// The pasted, wrapped code confirms like the link.
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	res, err := confirmCompany(store, d, got, companybundle.OriginCode, false, "")
	require.NoError(t, err)
	assert.Equal(t, "stored", res.Result)

	_, err = readCompanyWire(bytes.NewReader(bytes.Repeat([]byte("A"), companyStdinMax+1)))
	assert.ErrorContains(t, err, "too_long")
}

func TestCompanyList_JSONShape(t *testing.T) {
	store := company.NewStore(t.TempDir())
	require.NoError(t, store.Save("acme", companySample("Acme")))
	require.NoError(t, os.WriteFile(filepath.Join(store.Dir, "beta.json"), []byte("{"), 0o600))
	forced := companySample("Gamma")
	forced.Google, forced.Atlassian, forced.Microsoft, forced.Linear = nil, nil, nil, nil

	res, err := listCompanies(store, companyWire(t, forced))
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), "secret")
	var got map[string]any
	require.NoError(t, json.Unmarshal(raw, &got))
	assert.Equal(t, map[string]any{"state": "none"}, got["draft"])
	companies := got["companies"].([]any)
	require.Len(t, companies, 2)
	acme := companies[0].(map[string]any)
	assert.Equal(t, "acme", acme["slug"])
	assert.Equal(t, false, acme["forced"])
	assert.Equal(t, false, acme["personal"])
	assert.Equal(t, map[string]any{"client_id": "1234-abcd.apps.googleusercontent.com", "domain": "example.com"},
		acme["vendors"].(map[string]any)["google"])
	gamma := companies[1].(map[string]any)
	assert.Equal(t, "gamma", gamma["slug"])
	assert.Equal(t, true, gamma["forced"])
	assert.Equal(t, []any{map[string]any{"file": "beta.json", "error": got["errors"].([]any)[0].(map[string]any)["error"]}}, got["errors"])

	empty, err := listCompanies(company.NewStore(t.TempDir()), "")
	require.NoError(t, err)
	raw, err = json.Marshal(empty)
	require.NoError(t, err)
	assert.JSONEq(t, `{"companies":[],"errors":[],"draft":{"state":"none"}}`, string(raw))
}

func TestCompanyCommandsRegistered(t *testing.T) {
	for _, name := range []string{"list", "inspect", "confirm"} {
		c, _, err := companyCmd.Find([]string{name})
		require.NoError(t, err, name)
		assert.Equal(t, name, c.Name())
		assert.NotNil(t, c.Flags().Lookup("json"), name)
	}
	_, err := companyOrigin("mail")
	assert.Error(t, err)
}

func TestCompanyConfirm_StoredPersonalKeepsItsMark(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	p := companybundle.Bundle{V: 1, Company: "Acme", Personal: true, Google: companySample("Acme").Google}
	require.NoError(t, store.Save("acme", p))
	in := companybundle.Bundle{V: 1, Company: "Acme", Google: companySample("Acme").Google}
	in.Google.Domain = "acme.example.com"
	res, err := confirmCompany(store, d, companyWire(t, in), companybundle.OriginLink, false, "")
	require.NoError(t, err)
	assert.Equal(t, "stored", res.Result)
	got, _, err := store.Get("acme", "")
	require.NoError(t, err)
	assert.True(t, got.Bundle.Personal)
	assert.Equal(t, "acme.example.com", got.Bundle.Google.Domain)
}

func TestCompanyInspect_SiteChangeShownWhole(t *testing.T) {
	policytest.Set(t, nil)
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	require.NoError(t, store.Save("acme", companySample("Acme")))
	in := companySample("Acme")
	in.Atlassian.Site = "https://acme2.atlassian.net"
	res, err := inspectCompany(store, d, companyWire(t, in), "")
	require.NoError(t, err)
	assert.Equal(t, []companyChangeJSON{{Vendor: "atlassian", Field: "site", Old: "https://acme.atlassian.net", New: "https://acme2.atlassian.net"}}, res.Changes)
}

func TestCompanyInspect_OversizedStdinIsARefusal(t *testing.T) {
	var out bytes.Buffer
	c := companyInspectCmd
	c.SetIn(bytes.NewReader(bytes.Repeat([]byte("A"), companyStdinMax+1)))
	c.SetOut(&out)
	require.NoError(t, c.Flags().Set("json", "true"))
	t.Cleanup(func() {
		c.SetIn(nil)
		c.SetOut(nil)
		_ = c.Flags().Set("json", "false")
	})
	require.NoError(t, c.RunE(c, nil))
	var got map[string]any
	require.NoError(t, json.Unmarshal(out.Bytes(), &got))
	assert.Equal(t, "too_long", got["refused"])
}
