package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// get_confluence_page takes account_id — the name its result and
// edit_confluence_page use — as an alias of account; two different ids
// are refused rather than one silently winning.
func TestGetConfluencePage_AccountIDAlias(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	id := strconv.FormatInt(accountID, 10)
	f := newFakeConfluence()
	get := NewGetConfluencePage(confluenceFactory(f))
	run := func(args string) (any, error) {
		return get.Execute(context.Background(), d, Call{Args: json.RawMessage(args)})
	}

	assert.Equal(t, cfPageID, readPage(t, d, f, `{"page":"98765","account_id":`+id+`}`).ID)
	assert.Equal(t, cfPageID, readPage(t, d, f, `{"page":"98765","account":`+id+`,"account_id":`+id+`}`).ID)

	// The alias is honoured, not ignored: it pins the site a URL must match.
	_, err := run(`{"page":"https://other.example.com/wiki/spaces/X/pages/98765","account_id":` + id + `}`)
	assert.Contains(t, verr(t, err), "is not Jira account #"+id+"'s site")

	_, err = run(`{"page":"98765","account":` + id + `,"account_id":999}`)
	assert.Equal(t, "account ("+id+") and account_id (999) name different accounts; pass one of them", verr(t, err))

	_, err = run(`{"page":"98765","acount":1}`)
	require.Error(t, err, "other unknown fields are still refused")
}
