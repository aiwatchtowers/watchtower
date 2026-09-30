package tools

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// A first PUT that landed but whose response was lost leaves the page at
// base+1. The Retry writes nothing and says the edit may already be saved
// instead of blaming someone else's edit; a page two versions on is still
// the plain conflict.
func TestEditConfluencePage_RetryAfterLostResponse(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	reg := New(d)
	require.NoError(t, reg.Register(NewEditConfluencePage(confluenceFactory(f))))
	ctx := context.Background()

	rc, err := reg.Propose(ctx, "edit_confluence_page", editArgs(7, fridayToMonday), Binding{Surface: "main"})
	require.NoError(t, err)
	_, err = d.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)

	f.putErr, f.putLands = errors.New("connection reset by peer"), true
	row, err := reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "failed", row.Status)
	require.Equal(t, 8, f.pages[cfPageID].Version, "the first PUT landed")

	f.putErr, f.putLands = nil, false
	row, err = reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "conflict: the page is already at v8 — possibly this edit was saved; open the page to check. Nothing was written now", row.Error)
	assert.Len(t, f.puts, 1, "the Retry issues no second PUT")

	f.setVersion(9)
	row, err = reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "conflict: the page was edited after the preview (now v9); nothing was written", row.Error)
}

// A 409 whose re-read finds the page at base+1 gets the same hedged text.
func TestEditConfluencePage_Put409AtNextVersion(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	f.putErr = &jira.HTTPStatusError{Status: 409, Body: `{"message":"Version must be incremented"}`}
	f.onGet = func(int) {
		if len(f.puts) > 0 {
			f.setVersion(8)
		}
	}
	_, err := tool.Execute(context.Background(), d, Call{Args: args})
	assert.EqualError(t, err, "conflict: the page is already at v8 — possibly this edit was saved; open the page to check. Nothing was written now")
}

// A grant revoked by the time of the PUT names the write re-login, and
// Execute marks the account revoked.
func TestEditConfluencePage_RevokedAtPutNamesWriteLogin(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	hint := "Atlassian sign-in expired — run: watchtower jira login --account " + strconv.FormatInt(accountID, 10) + " --with-confluence-write"

	for name, putErr := range map[string]error{
		"jira":    fmt.Errorf("refreshing token: %w", jira.ErrAuthRevoked),
		"extsync": fmt.Errorf("fetching: %w", extsync.ErrAuthRevoked),
	} {
		t.Run(name, func(t *testing.T) {
			f.putErr = putErr
			_, err := tool.Execute(context.Background(), d, Call{Args: args})
			require.Error(t, err)
			assert.Contains(t, err.Error(), hint)
			assert.NotContains(t, err.Error(), "updating Confluence page")
		})
	}
	acct, err := d.GetJiraAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acct.Status, "Execute marks a revoked grant")

	// A grant revoked at the pre-PUT re-read names the write re-login too.
	f.putErr, f.getErr = nil, jira.ErrAuthRevoked
	_, err = tool.Execute(context.Background(), d, Call{Args: args})
	assert.Contains(t, err.Error(), hint)
}
