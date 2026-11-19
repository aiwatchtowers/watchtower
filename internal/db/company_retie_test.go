package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// RetieAccounts moves a set of accounts between companies in one
// transaction: a row on a third company (or gone) fails the whole call and
// leaves every row as it was.
func TestRetieAccounts_AllOrNothing(t *testing.T) {
	d := openTestDB(t)
	ids := companyFixture(t, d)
	var refs []CompanyAccountRef
	for _, source := range CompanyAccountSources {
		refs = append(refs, CompanyAccountRef{Source: source, ID: ids[source]})
	}
	tied := func() int {
		got, err := d.AccountsByCompany("acme")
		require.NoError(t, err)
		return len(got)
	}

	// A row already on the target counts as moved.
	require.NoError(t, d.SetAccountCompany("jira", ids["jira"], "acme"))
	require.NoError(t, d.RetieAccounts(refs, "", "acme"))
	assert.Equal(t, len(CompanyAccountSources), tied())

	// The undo puts them back.
	require.NoError(t, d.RetieAccounts(refs, "acme", ""))
	assert.Zero(t, tied())

	// A row on another company fails the call; nothing moved.
	require.NoError(t, d.SetAccountCompany("linear", ids["linear"], "other"))
	assert.Error(t, d.RetieAccounts(refs, "", "acme"))
	assert.Zero(t, tied())

	// A missing row and an unknown source fail too.
	assert.Error(t, d.RetieAccounts([]CompanyAccountRef{{Source: "slack", ID: ids["slack"] + 100}}, "", "acme"))
	assert.Error(t, d.RetieAccounts([]CompanyAccountRef{{Source: "teams", ID: 1}}, "", "acme"))

	// An IMAP mailbox is never moved as an Outlook account.
	imapID, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Host: "imap.example.com", Security: "ssl"})
	require.NoError(t, err)
	assert.Error(t, d.RetieAccounts([]CompanyAccountRef{{Source: "outlook", ID: imapID}}, "", "acme"))
}
