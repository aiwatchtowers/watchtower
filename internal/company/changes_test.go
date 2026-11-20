package company

import (
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
)

func TestChanges_ListsEachChangedID(t *testing.T) {
	stored := sample("Acme")
	in := sample("Acme")
	in.Slack.ClientID = "111.222"
	in.Google.ClientSecret = "other-secret"
	in.Atlassian.ClientID = "acmeClientId02"
	in.Atlassian.Site = "https://acme2.atlassian.net"
	in.Microsoft.TenantID = "example.com"
	in.Linear = nil

	assert.Equal(t, []Change{
		{Vendor: "slack", Field: "client_id", Old: "000.000", New: "111.222"},
		{Vendor: "google", Field: "client_secret"},
		{Vendor: "atlassian", Field: "client_id", Old: "acmeClientId01", New: "acmeClientId02"},
		{Vendor: "atlassian", Field: "site", Old: "https://acme.atlassian.net", New: "https://acme2.atlassian.net"},
		{Vendor: "microsoft", Field: "tenant_id", Old: "00000000-0000-0000-0000-0000000000aa", New: "example.com"},
		{Vendor: "linear", Field: "client_id", Old: "acmelinear01", New: ""},
	}, Changes(stored, in))
}

func TestChanges_AddedVendorAndOtherFieldsAreNoChange(t *testing.T) {
	stored := companybundle.Bundle{V: 1, Company: "Acme", Google: sample("Acme").Google}
	in := sample("Acme")
	in.Google.Domain = "acme.example.com"
	in.Atlassian.Confluence = false
	in.LinkDenyHosts = []string{"intranet.example.com"}
	assert.Empty(t, Changes(stored, in))
	assert.Empty(t, Changes(sample("Acme"), sample("Acme")))
}

func TestChanges_IgnoreNormalizedForm(t *testing.T) {
	stored := sample("Acme")
	raw := `{"v":1,"company":" Acme ","slack":{"team_id":"T0000","client_id":" 000.000 "},` +
		`"google":{"client_id":"1234-abcd.apps.googleusercontent.com ","client_secret":"sample-secret","domain":"example.com"},` +
		`"atlassian":{"client_id":" acmeClientId01","client_secret":"acme-secret","site":"https://Acme.atlassian.net/","confluence":true},` +
		`"linear":{"client_id":"acmelinear01"},` +
		`"microsoft":{"client_id":"00000000-0000-0000-0000-000000000001","tenant_id":"00000000-0000-0000-0000-0000000000AA"}}`
	in, err := companybundle.Parse(base64.RawURLEncoding.EncodeToString([]byte(raw)), companybundle.OriginLink)
	require.NoError(t, err)
	assert.Equal(t, "Acme", in.Company)
	assert.Empty(t, Changes(stored, in))
}

func TestShortID(t *testing.T) {
	assert.Equal(t, "acme…d01", ShortID("acmeClientId01"))
	assert.Equal(t, "1234…com", ShortID("1234-abcd.apps.googleusercontent.com"))
	assert.Equal(t, "1234567", ShortID("1234567"))
	assert.Equal(t, "12345678"[:4]+"…678", ShortID("12345678"))
	assert.Equal(t, "", ShortID(""))
	assert.Equal(t, "Ачме…бвг", ShortID("Ачме-абвг"))
}
