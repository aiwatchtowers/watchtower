package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

func editArgs(baseVersion int, edits string) json.RawMessage {
	return json.RawMessage(`{"page_id":"98765","base_version":` + strconv.Itoa(baseVersion) +
		`,"edits":` + edits + `,"reason":"fix the rollout day"}`)
}

const fridayToMonday = `[{"kind":"replace_text","old":"Выкатываем в пятницу.","new":"Выкатываем в понедельник."}]`

func TestEditConfluencePage_ValidateShapes(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	ctx := context.Background()
	require.NoError(t, tool.Validate(ctx, d, editArgs(7, fridayToMonday)))

	long := strings.Repeat("x", confluenceMaxEditFieldRunes+1)
	half := strings.Repeat("y", confluenceMaxEditFieldRunes)
	twentyOne := "[" + strings.TrimSuffix(strings.Repeat(`{"kind":"replace_text","old":"a","new":"b"},`, 21), ",") + "]"
	for name, c := range map[string]struct {
		raw  json.RawMessage
		want string
	}{
		"no edits":          {editArgs(7, `[]`), "1 to 20 edits"},
		"21 edits":          {editArgs(7, twentyOne), "1 to 20 edits (got 21)"},
		"bad kind":          {editArgs(7, `[{"kind":"append","new":"x"}]`), `edits[0]: kind "append"`},
		"text without old":  {editArgs(7, `[{"kind":"replace_text","new":"x"}]`), "edits[0]: replace_text needs old"},
		"text without new":  {editArgs(7, `[{"kind":"replace_text","old":"x"}]`), "replace_text needs new"},
		"text with heading": {editArgs(7, `[{"kind":"replace_text","old":"x","new":"y","heading":"H"}]`), "takes only old and new"},
		"section no body":   {editArgs(7, `[{"kind":"replace_section","heading":"Risks"}]`), "needs new_body"},
		"section blank":     {editArgs(7, `[{"kind":"replace_section","heading":"  ","new_body":"x"}]`), "needs heading"},
		"field too long":    {editArgs(7, `[{"kind":"replace_text","old":"a","new":"`+long+`"}]`), "at most 60000 per field"},
		"call too long": {editArgs(7, `[{"kind":"replace_text","old":"a","new":"`+half+`"},{"kind":"replace_text","old":"b","new":"`+half+
			`"},{"kind":"replace_text","old":"c","new":"z"}]`), "at most 120000 per call"},
		"bad page id":   {json.RawMessage(`{"page_id":"abc","base_version":7,"edits":` + fridayToMonday + `,"reason":"r"}`), "numeric page id"},
		"no version":    {json.RawMessage(`{"page_id":"98765","edits":` + fridayToMonday + `,"reason":"r"}`), "base_version"},
		"unknown field": {json.RawMessage(`{"page_id":"98765","base_version":7,"edits":` + fridayToMonday + `,"reason":"r","force":true}`), "invalid arguments"},
	} {
		t.Run(name, func(t *testing.T) { assert.Contains(t, verr(t, tool.Validate(ctx, d, c.raw)), c.want) })
	}

	f.readOnly = true
	assert.Equal(t, "Confluence editing not granted — run: watchtower jira login --account "+strconv.FormatInt(accountID, 10)+" --with-confluence-write",
		verr(t, tool.Validate(ctx, d, editArgs(7, fridayToMonday))))
	assert.Zero(t, f.gets, "Validate makes no network call")
}

// Normalize applies the edits to the live page at propose time and pins
// exactly what Execute will write, with the card's changes in the names the
// model saw (R3).
func TestEditConfluencePage_NormalizePinsResolvedEdit(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	raw := editArgs(7, `[`+
		`{"kind":"replace_text","old":"Выкатываем в пятницу.","new":"Выкатываем в понедельник."},`+
		`{"kind":"replace_text","old":"Owner: ⟦1:@Ann Lee⟧ leads","new":"Owner: ⟦1:@Ann Lee⟧ runs"},`+
		`{"kind":"replace_section","heading":"Risks","new_body":"- Freeze on **Friday**\n- Canary may slip"}]`)
	pinned := normalized(t, tool, d, raw)

	var got map[string]any
	require.NoError(t, json.Unmarshal(pinned, &got))
	assert.Equal(t, float64(accountID), got["account_id"])
	assert.Equal(t, cfPageID, got["page_id"])
	assert.Equal(t, "page", got["kind"])
	assert.Equal(t, "Rollout plan", got["title"])
	assert.Equal(t, cfURL, got["url"])
	assert.Equal(t, float64(7), got["base_version"])
	assert.Equal(t, "fix the rollout day", got["reason"], "the owner's args survive the pin")
	assert.NotNil(t, got["edits"])
	storage := got["new_storage"].(string)
	assert.Contains(t, storage, `<p>Owner: <ac:link><ri:user ri:account-id="`+cfMentionID+`" /></ac:link> runs the rollout.</p>`,
		"the display-named marker is written back as the original mention bytes")
	assert.Contains(t, storage, "<p>Выкатываем в понедельник.</p>")
	assert.Contains(t, storage, `<li>Freeze on <strong>Friday</strong></li>`)
	assert.Contains(t, storage, `ac:macro-id="0f1e2d3c-aaaa-bbbb-cccc-000000000001"`, "an untouched macro keeps its bytes")
	assert.NotContains(t, storage, "None known.")

	var p editConfluencePinned
	require.NoError(t, json.Unmarshal(pinned, &p))
	require.Len(t, p.Changes, 3)
	assert.Equal(t, confluenceChangeView{Kind: "replace_text", Locator: "text in План", Before: "Выкатываем в пятницу.",
		After: "Выкатываем в понедельник.", Removed: []string{}}, p.Changes[0])
	assert.Equal(t, "Owner: ⟦1:@Ann Lee⟧ leads the rollout.", p.Changes[1].Before, "the card shows names, not account ids")
	assert.Equal(t, "Risks", p.Changes[2].Locator)
	assert.Empty(t, f.puts, "propose never writes")
}

func TestEditConfluencePage_RemovedMarkersAndRefusals(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	pinned := normalized(t, tool, d, editArgs(7, `[{"kind":"replace_text","old":"Owner: ⟦1:@Ann Lee⟧ leads","new":"The team leads"}]`))
	var p editConfluencePinned
	require.NoError(t, json.Unmarshal(pinned, &p))
	assert.Equal(t, []string{"⟦1:@Ann Lee⟧"}, p.Changes[0].Removed, "a deleted marker is listed, by name")

	for name, c := range map[string]struct{ edits, want string }{
		"not found":      {`[{"kind":"replace_text","old":"Ship on Sunday","new":"x"}]`, "edits[0]"},
		"invented":       {`[{"kind":"replace_text","old":"None known.","new":"⟦9:@Zed⟧"}]`, "never invented"},
		"wrong name":     {`[{"kind":"replace_text","old":"None known.","new":"⟦1:@Someone Else⟧ again"}]`, "⟦1:@Ann Lee⟧"},
		"duplicate kept": {`[{"kind":"replace_text","old":"None known.","new":"⟦2:jira PROJ-7⟧"}]`, "duplicate marker ⟦2:jira PROJ-7⟧"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := tool.Normalize(context.Background(), d, editArgs(7, c.edits))
			assert.Contains(t, verr(t, err), c.want)
		})
	}
	assert.Empty(t, f.puts)
}

// Edits must stay inside the text get_confluence_page showed: on a page
// longer than the cap, the hidden tail is off limits.
func TestEditConfluencePage_TruncatedTailIsOffLimits(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	f.pages[cfPageID] = ConfluencePage{ID: cfPageID, Kind: "page", Title: "Big", Version: 4,
		Storage: `<p>Head <ac:link><ri:user ri:account-id="` + cfMentionID + `" /></ac:link> here.</p><p>` +
			strings.Repeat("ж", confluenceMaxTextRunes) + `</p><p>Hidden tail.</p><p>See <ac:link><ri:user ri:account-id="557058:reviewer" /></ac:link>.</p>`}
	tool := NewEditConfluencePage(confluenceFactory(f))

	_, err := tool.Normalize(context.Background(), d, editArgs(4, `[{"kind":"replace_text","old":"Hidden tail.","new":"Changed."}]`))
	assert.Contains(t, verr(t, err), "did not show")
	// Removing a marker in the visible head renumbers later markers but
	// leaves the tail's text alone.
	normalized(t, tool, d, editArgs(4, `[{"kind":"replace_text","old":"Head ⟦1:@Ann Lee⟧ here.","new":"Head here."}]`))
}

// EXT-05: a write carries the version the owner saw and lands only while
// the live page is still at it — at propose time (a ValidationError, no
// proposal) and at apply time (a failed action, no PUT).
func TestEXT05_WriteRequiresMatchingVersion(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	reg := New(d)
	require.NoError(t, reg.Register(NewEditConfluencePage(confluenceFactory(f))))
	ctx := context.Background()

	// Propose against a stale read: refused, nothing recorded, nothing written.
	_, err := reg.Propose(ctx, "edit_confluence_page", editArgs(6, fridayToMonday), Binding{Surface: "main"})
	assert.Equal(t, "page changed since you read it (now v7) — re-read with get_confluence_page", verr(t, err))

	// Propose at v7, then someone edits the page before Approve.
	rc, err := reg.Propose(ctx, "edit_confluence_page", editArgs(7, fridayToMonday), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status, "External: always behind Approve (AGENT-03)")
	ok, err := d.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	f.setVersion(8)
	row, err := reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "conflict: the page was edited after the preview (now v8); nothing was written", row.Error)
	assert.Empty(t, f.puts, "a live-version mismatch at apply time means no PUT")

	// The page moves on between Execute's re-check and its PUT: Confluence's
	// own 409 is the same conflict.
	f.setVersion(7)
	f.putErr = &jira.HTTPStatusError{Status: 409, Body: `{"message":"Version must be incremented"}`}
	f.onGet = func(n int) {
		if n > 0 && len(f.puts) > 0 {
			f.setVersion(9)
		}
	}
	row, err = reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "conflict: the page was edited after the preview (now v9); nothing was written", row.Error)
}

func TestEditConfluencePage_ExecutePutsTheApprovedStorage(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	p := f.pages[cfPageID]
	p.Kind = "blogpost"
	f.pages[cfPageID] = p
	reg := New(d)
	require.NoError(t, reg.Register(NewEditConfluencePage(confluenceFactory(f))))
	ctx := context.Background()

	rc, err := reg.Propose(ctx, "edit_confluence_page", editArgs(7, fridayToMonday), Binding{Surface: "target"})
	require.NoError(t, err)
	stored, err := d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	var pinned editConfluencePinned
	require.NoError(t, json.Unmarshal([]byte(stored.ArgsJSON), &pinned))
	_, err = d.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)

	row, err := reg.Apply(ctx, rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", row.Status, row.Error)
	require.Len(t, f.puts, 1, "exactly one PUT")
	put := f.puts[0]
	assert.Equal(t, cfPageID, put.id)
	assert.Equal(t, "blogpost", put.kind, "a blog post is written to its own collection")
	assert.Equal(t, ConfluencePutBody{ID: cfPageID, Status: "current", Title: "Rollout plan",
		Body:    ConfluencePutStorage{Representation: "storage", Value: pinned.NewStorage},
		Version: ConfluencePutVersionInfo{Number: 8, Message: "Edited via Watchtower"}}, put.body)
	var result map[string]any
	require.NoError(t, json.Unmarshal([]byte(row.ResultJSON), &result))
	assert.Equal(t, map[string]any{"page_id": cfPageID, "title": "Rollout plan", "url": cfURL, "version": float64(8)}, result)
}

func TestEditConfluencePage_ExecuteFailuresAreActionable(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	args := normalized(t, tool, d, editArgs(7, fridayToMonday))
	run := func() error {
		_, err := tool.Execute(context.Background(), d, Call{Args: args})
		return err
	}

	writeHint := "Confluence editing not granted — run: watchtower jira login --account " + strconv.FormatInt(accountID, 10) + " --with-confluence-write"
	f.putErr = &jira.HTTPStatusError{Status: 403, Body: `{"message":"OAuth 2.0 token has insufficient scope"}`}
	assert.Contains(t, run().Error(), writeHint, "a scope 403 is a grant problem")
	f.putErr = &jira.HTTPStatusError{Status: 403, Body: `{"message":"not permitted"}`}
	err403 := run().Error()
	assert.Contains(t, err403, "you don't have permission to edit this page in Confluence", "a restriction 403 is not a re-login")
	assert.NotContains(t, err403, "jira login")

	f.putErr = nil
	f.getErr = jira.ErrAuthRevoked
	assert.Contains(t, run().Error(), "sign-in expired")
	acct, err := d.GetJiraAccount(accountID)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acct.Status, "Execute marks a revoked grant")

	_, err = tool.Execute(context.Background(), d, Call{Args: editArgs(7, fridayToMonday)})
	assert.EqualError(t, err, "the proposal carries no prepared edit; propose it again", "Execute never re-derives an un-normalized edit")
	require.Len(t, f.puts, 2, "only the two 403 attempts reached PUT")
}

// Execute writes the storage pinned at propose time — what the owner
// approved — and never recomputes it from the edits: a tampered stored
// new_storage goes out verbatim.
func TestEditConfluencePage_ExecuteWritesThePinnedStorageVerbatim(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	tool := NewEditConfluencePage(confluenceFactory(f))
	var args map[string]any
	require.NoError(t, json.Unmarshal(normalized(t, tool, d, editArgs(7, fridayToMonday)), &args))
	const pinned = `<p>Exactly what the owner approved.</p>`
	args["new_storage"] = pinned
	raw, err := json.Marshal(args)
	require.NoError(t, err)
	_, err = tool.Execute(context.Background(), d, Call{Args: raw})
	require.NoError(t, err)
	require.Len(t, f.puts, 1)
	assert.Equal(t, pinned, f.puts[0].body.Body.Value)
}

func TestEditConfluencePage_ScopeHints(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	f.noRead = true
	id := strconv.FormatInt(accountID, 10)
	err := NewEditConfluencePage(confluenceFactory(f)).Validate(context.Background(), d, editArgs(7, fridayToMonday))
	assert.Equal(t, "Confluence editing not granted — run: watchtower jira login --account "+id+" --with-confluence-write", verr(t, err),
		"no Confluence scopes at all: the edit asks for the write flag, which implies read")
	_, err = NewGetConfluencePage(confluenceFactory(f)).Execute(context.Background(), d, Call{Args: json.RawMessage(`{"page":"98765"}`)})
	assert.Equal(t, "Confluence access not granted — run: watchtower jira login --account "+id+" --with-confluence", verr(t, err))
	assert.Zero(t, f.gets)
}

// A failed user-name lookup at propose time is named in the refusal of an
// edit that used display-named markers.
func TestEditConfluencePage_NameLookupFailureIsExplained(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	f.usersErr = errors.New("user bulk: 500")
	_, err := NewEditConfluencePage(confluenceFactory(f)).Normalize(context.Background(), d,
		editArgs(7, `[{"kind":"replace_text","old":"Owner: ⟦1:@Ann Lee⟧ leads","new":"Owner: ⟦1:@Ann Lee⟧ runs"}]`))
	msg := verr(t, err)
	assert.Contains(t, msg, "couldn't resolve user names")
	assert.Contains(t, msg, "user bulk: 500")
	assert.Contains(t, msg, "re-read with get_confluence_page and keep the markers as shown")
}
