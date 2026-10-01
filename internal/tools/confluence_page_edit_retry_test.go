package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// A first PUT that landed but whose response was lost leaves the page at
// base+1 holding exactly this edit's storage (R12). The Retry writes
// nothing and succeeds, noting the edit was already saved — the page holds
// exactly what the owner approved, so the action is applied, not failed;
// a page two versions on is still the plain conflict.
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
	assert.Equal(t, "applied", row.Status, row.Error)
	assert.Empty(t, row.Error)
	var result map[string]any
	require.NoError(t, json.Unmarshal([]byte(row.ResultJSON), &result))
	assert.Equal(t, map[string]any{"page_id": cfPageID, "title": "Rollout plan", "url": cfURL, "version": float64(8),
		"note": "this edit is already saved (v8); nothing was written now"}, result)
	assert.Len(t, f.puts, 1, "the Retry issues no second PUT")
}

// Once the page moved two versions on, a Retry is the plain conflict.
func TestEditConfluencePage_RetryTwoVersionsOnConflicts(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	f.setVersion(9)
	_, err := tool.Execute(context.Background(), d, Call{Args: args})
	assert.EqualError(t, err, "conflict: the page was edited after the preview (now v9); nothing was written")
	assert.Empty(t, f.puts)
}

// executesAlreadySaved runs Execute and asserts its success result for an
// edit found already saved at v8.
func executesAlreadySaved(t *testing.T, tool *Tool, d *db.DB, args json.RawMessage) {
	t.Helper()
	out, err := tool.Execute(context.Background(), d, Call{Args: args})
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"page_id": cfPageID, "title": "Rollout plan", "url": cfURL, "version": 8,
		"note": "this edit is already saved (v8); nothing was written now"}, out)
}

// A 409 whose re-read finds the page at base+1 tells the two cases apart by
// storage (R12, F5): someone else's v8 is the hedged conflict; a v8 holding
// exactly this edit is "already saved".
func TestEditConfluencePage_Put409AtNextVersion(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	var pinned editConfluencePinned
	require.NoError(t, json.Unmarshal(args, &pinned))
	f.putErr = &jira.HTTPStatusError{Status: 409, Body: `{"message":"Version must be incremented"}`}

	f.onGet = func(int) {
		if len(f.puts) > 0 {
			f.setVersion(8)
		}
	}
	_, err := tool.Execute(context.Background(), d, Call{Args: args})
	assert.EqualError(t, err, "conflict: the page is now v8 (one version after your preview) — this edit may have been saved; re-read with get_confluence_page before retrying; nothing was written now")

	f.setVersion(7)
	f.onGet = func(int) {
		if len(f.puts) > 1 {
			p := f.pages[cfPageID]
			p.Version, p.Storage = 8, pinned.NewStorage
			f.pages[cfPageID] = p
		}
	}
	executesAlreadySaved(t, tool, d, args)
}

// A 409 whose re-read fails cannot tell someone else's edit from this one
// landing: the conflict is hedged and names the read failure.
func TestEditConfluencePage_Put409WithFailedReRead(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	f.putErr = &jira.HTTPStatusError{Status: 409, Body: `{"message":"Version must be incremented"}`}
	f.onGet = func(int) {
		if len(f.puts) > 0 {
			f.getErr = errors.New("read: 503")
		}
	}
	_, err := tool.Execute(context.Background(), d, Call{Args: args})
	assert.EqualError(t, err, "conflict: Confluence refused v8 — the page was edited after the preview, or this edit may already be saved; re-read with get_confluence_page before retrying (re-reading the page failed: read: 503); nothing was written now")
}

// F5: two edits proposed off the same read; once the first is applied, the
// second finds the page at base+1 — someone else's version as far as it is
// concerned — and gets the hedged conflict, not "already saved".
func TestEditConfluencePage_SecondProposalOffTheSameReadConflicts(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	reg := New(d)
	require.NoError(t, reg.Register(NewEditConfluencePage(confluenceFactory(f))))
	ctx := context.Background()

	first, err := reg.Propose(ctx, "edit_confluence_page", editArgs(7, fridayToMonday), Binding{Surface: "main"})
	require.NoError(t, err)
	second, err := reg.Propose(ctx, "edit_confluence_page",
		editArgs(7, `[{"kind":"replace_text","old":"None known.","new":"Canary may slip."}]`), Binding{Surface: "main"})
	require.NoError(t, err)
	for _, id := range []int64{first.ActionID, second.ActionID} {
		_, err = d.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
		require.NoError(t, err)
	}
	row, err := reg.Apply(ctx, first.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
	row, err = reg.Apply(ctx, second.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "conflict: the page is now v8 (one version after your preview) — this edit may have been saved; re-read with get_confluence_page before retrying; nothing was written now", row.Error)
	assert.Len(t, f.puts, 1)
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

// N3: Confluence stamps local-id attributes on the elements it saves, so
// our own lost-response PUT at base+1 may differ from new_storage by those
// alone — still "already saved". Any other difference at base+1 is the
// hedged conflict.
func TestEditConfluencePage_AlreadySavedIgnoresLocalIDs(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	var pinned editConfluencePinned
	require.NoError(t, json.Unmarshal(args, &pinned))

	stamped := strings.Replace(pinned.NewStorage, "<p>", `<p local-id="a1b2">`, 1)
	stamped = strings.Replace(stamped, "<h2>", `<h2 ac:local-id='c3'>`, 1)
	stamped = strings.Replace(stamped, `ri:account-id=`, `ri:local-id="u1" ri:account-id=`, 1)
	require.NotEqual(t, pinned.NewStorage, stamped, "fixture stamps a local-id")
	p := f.pages[cfPageID]
	p.Version, p.Storage = 8, stamped
	f.pages[cfPageID] = p
	executesAlreadySaved(t, tool, d, args)
	assert.Empty(t, f.puts)

	p.Storage = strings.Replace(stamped, "понедельник", "вторник", 1)
	require.NotEqual(t, stamped, p.Storage, "fixture changes the text")
	f.pages[cfPageID] = p
	_, err := tool.Execute(context.Background(), d, Call{Args: args})
	assert.EqualError(t, err, "conflict: the page is now v8 (one version after your preview) — this edit may have been saved; re-read with get_confluence_page before retrying; nothing was written now")
	assert.Empty(t, f.puts)
}

// F3: only a start tag's local-id attributes are Confluence's stamps. The
// same text inside CDATA (a code block's body) or in page text is content:
// two storages differing there are different pages, and at base+1 that is
// the hedged conflict, never "already saved".
func TestConfluenceConflict_LocalIDsOnlyInStartTags(t *testing.T) {
	const hedged = "conflict: the page is now v8 (one version after your preview) — this edit may have been saved; re-read with get_confluence_page before retrying; nothing was written now"
	const saved = "this edit is already saved (v8); nothing was written now"
	code := func(id string) string {
		return `<ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[<p local-id="` + id + `">x</p>]]></ac:plain-text-body></ac:structured-macro>`
	}
	for name, tc := range map[string]struct{ ours, live, want string }{
		"start-tag local-id differs":             {`<p>a</p>` + code("1"), `<p local-id="9">a</p>` + code("1"), saved},
		"attribute value holding >":              {`<a href="x>y">a</a>`, `<a href="x>y" ac:local-id='2'>a</a>`, saved},
		"CDATA local-id differs":                 {`<p>a</p>` + code("1"), `<p>a</p>` + code("3"), hedged},
		"page text local-id differs":             {`<p>set local-id="1" here</p>`, `<p>set local-id="3" here</p>`, hedged},
		"unterminated CDATA compared verbatim":   {`<p>a</p><![CDATA[ local-id="1"`, `<p>a</p><![CDATA[ local-id="3"`, hedged},
		"comment local-id differs":               {`<p>a</p><!-- <p local-id="1"> -->`, `<p>a</p><!-- <p local-id="3"> -->`, hedged},
		"start tag after a comment stripped":     {`<!-- x --><p>a</p>`, `<!-- x --><p local-id="9">a</p>`, saved},
		"comment opener inside CDATA":            {`<![CDATA[<!--]]><p>a</p>`, `<![CDATA[<!--]]><p local-id="9">a</p>`, saved},
		"unterminated comment compared verbatim": {`<p>a</p><!-- <p local-id="1">`, `<p>a</p><!-- <p local-id="3">`, hedged},
	} {
		t.Run(name, func(t *testing.T) {
			err := confluenceConflict(ConfluencePage{Version: 8, Storage: tc.live}, editConfluencePinned{BaseVersion: 7, NewStorage: tc.ours})
			assert.EqualError(t, err, tc.want)
		})
	}
}
