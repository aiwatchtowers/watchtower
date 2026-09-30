package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// A real-shaped storage page: a mention (self-closing ri:user, an
// Atlassian account id with a colon), a Jira macro with a macro id, and
// sections under h1/h2 headings.
const (
	cfMentionID = "557058:0a1b2c3d-1111-4222-8333-444455556666"
	cfStorage   = `<h1>Overview</h1><p>Owner: <ac:link><ri:user ri:account-id="` + cfMentionID + `" /></ac:link> leads the rollout.</p>` +
		`<ac:structured-macro ac:name="jira" ac:schema-version="1" ac:macro-id="0f1e2d3c-aaaa-bbbb-cccc-000000000001">` +
		`<ac:parameter ac:name="key">PROJ-7</ac:parameter></ac:structured-macro>` +
		`<h2>План</h2><p>Выкатываем в пятницу.</p><p>Deploy with the canary first.</p><h2>Risks</h2><p>None known.</p>`
	cfPageID = "98765"
	cfURL    = "https://test.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout"
)

type fakePut struct {
	id, kind string
	body     ConfluencePutBody
}

// fakeConfluence is a ConfluencePageClient over in-memory pages. PutPage
// records the call and bumps the stored page's version like Confluence.
type fakeConfluence struct {
	pages       map[string]ConfluencePage
	comments    []ConfluenceComment
	users       map[string]string
	getErr      error
	putErr      error
	commentsErr error
	usersErr    error
	readOnly    bool
	puts        []fakePut
	gets        int
	// onGet runs after each GetPage lookup — the seam a test uses to change
	// the live page between the steps of one call.
	onGet func(n int)
}

func newFakeConfluence() *fakeConfluence {
	return &fakeConfluence{
		pages: map[string]ConfluencePage{cfPageID: {ID: cfPageID, Kind: "page", Title: "Rollout plan", SpaceKey: "ENG",
			URL: cfURL, Version: 7, Storage: cfStorage}},
		users: map[string]string{cfMentionID: "Ann Lee", "557058:reviewer": "Bob Stone"},
	}
}

func (f *fakeConfluence) GetPage(_ context.Context, id string) (ConfluencePage, error) {
	f.gets++
	if f.onGet != nil {
		f.onGet(f.gets)
	}
	if f.getErr != nil {
		return ConfluencePage{}, f.getErr
	}
	p, ok := f.pages[id]
	if !ok {
		return ConfluencePage{}, errConfluencePageNotFound
	}
	return p, nil
}

func (f *fakeConfluence) PutPage(_ context.Context, id, kind string, body ConfluencePutBody) (int, error) {
	f.puts = append(f.puts, fakePut{id: id, kind: kind, body: body})
	if f.putErr != nil {
		return 0, f.putErr
	}
	p := f.pages[id]
	p.Version, p.Storage = body.Version.Number, body.Body.Value
	f.pages[id] = p
	return p.Version, nil
}

func (f *fakeConfluence) Comments(context.Context, string) ([]ConfluenceComment, error) {
	return f.comments, f.commentsErr
}

func (f *fakeConfluence) Users(_ context.Context, ids []string) (map[string]string, error) {
	if f.usersErr != nil {
		return nil, f.usersErr
	}
	out := map[string]string{}
	for _, id := range ids {
		if n, ok := f.users[id]; ok {
			out[id] = n
		}
	}
	return out, nil
}

func (f *fakeConfluence) HasWriteScopes() bool { return !f.readOnly }

func (f *fakeConfluence) setVersion(v int) {
	p := f.pages[cfPageID]
	p.Version = v
	f.pages[cfPageID] = p
}

func confluenceFactory(f *fakeConfluence) ConfluencePageClientFactory {
	return func(db.JiraAccount) (ConfluencePageClient, error) { return f, nil }
}

func readPage(t *testing.T, d *db.DB, f *fakeConfluence, args string) confluencePageView {
	t.Helper()
	out, err := NewGetConfluencePage(confluenceFactory(f)).Execute(context.Background(), d, Call{Args: json.RawMessage(args)})
	require.NoError(t, err)
	view, ok := out.(confluencePageView)
	require.True(t, ok, "got %T", out)
	return view
}

func TestConfluencePageTools_Shape(t *testing.T) {
	reg := New(openDB(t))
	f := newFakeConfluence()
	get, edit := NewGetConfluencePage(confluenceFactory(f)), NewEditConfluencePage(confluenceFactory(f))

	assert.Equal(t, AccessRead, get.Access)
	assert.False(t, get.External)
	assert.ElementsMatch(t, []string{"main", "target"}, get.Surfaces)
	assert.Equal(t, AccessWrite, edit.Access)
	assert.True(t, edit.External, "a Confluence write leaves the machine (AGENT-03)")
	assert.ElementsMatch(t, []string{"main", "target"}, edit.Surfaces)
	for _, req := range []string{"page_id", "base_version", "edits", "reason"} {
		assert.Contains(t, edit.InputSchema.Required, req)
	}
	assert.Contains(t, edit.Description, "drops any HTML comments", "carry (f): the tool docs name replace_section's comment loss")
	require.NoError(t, reg.Register(get))
	require.NoError(t, reg.Register(edit))
	assert.ErrorIs(t, reg.SetTrust("edit_confluence_page", TrustExecute), ErrExternalExecute)
	for _, rt := range ReadTools() {
		assert.NotEqual(t, "get_confluence_page", rt.Name, "a live network read is chat-mode only, never dev-mode MCP (DEV-01)")
	}
}

func TestGetConfluencePage_ReadsLiveTextCommentsAndNames(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	created := time.Date(2026, 9, 29, 8, 30, 0, 0, time.FixedZone("CEST", 2*3600))
	f.comments = []ConfluenceComment{
		{ID: "1", AuthorID: "557058:reviewer", Created: created, Kind: "footer", Body: "Looks good, @[~" + cfMentionID + "] please confirm."},
		{ID: "2", ReplyTo: "1", AuthorID: cfMentionID, Created: created, Kind: "footer", Body: "Confirmed."},
		{ID: "3", ReplyTo: "2", AuthorID: "557058:gone", Created: created, Kind: "footer", Body: "Thanks."},
		{ID: "4", AuthorID: "557058:reviewer", Created: created, Kind: "inline", AnchorText: "Выкатываем в пятницу", Resolved: true, Body: "Friday is a freeze day."},
	}

	view := readPage(t, d, f, `{"page":"98765"}`)
	assert.Equal(t, accountID, view.AccountID)
	assert.Equal(t, cfPageID, view.ID)
	assert.Equal(t, "page", view.Kind)
	assert.Equal(t, "Rollout plan", view.Title)
	assert.Equal(t, "ENG", view.Space)
	assert.Equal(t, cfURL, view.URL)
	assert.Equal(t, 7, view.Version)
	assert.Equal(t, "# Overview\n\nOwner: ⟦1:@Ann Lee⟧ leads the rollout.\n\n⟦2:jira PROJ-7⟧\n\n## План\n\n"+
		"Выкатываем в пятницу.\n\nDeploy with the canary first.\n\n## Risks\n\nNone known.", view.Text,
		"R3: a mention marker is labelled with the display name, not the account id")
	assert.False(t, view.Truncated)
	assert.Empty(t, view.Notes)

	require.Len(t, view.Comments, 2, "replies nest under their thread")
	footer := view.Comments[0]
	assert.Equal(t, "Bob Stone", footer.Author)
	assert.Equal(t, "2026-09-29T06:30:00Z", footer.Created)
	assert.Equal(t, "footer", footer.Kind)
	assert.Equal(t, "Looks good, @Ann Lee please confirm.", footer.Body)
	require.Len(t, footer.Replies, 1)
	assert.Equal(t, "Ann Lee", footer.Replies[0].Author)
	require.Len(t, footer.Replies[0].Replies, 1, "a reply to a reply nests one level deeper")
	assert.Equal(t, "557058:gone", footer.Replies[0].Replies[0].Author, "an unresolved author keeps the id")
	inline := view.Comments[1]
	assert.Equal(t, "inline", inline.Kind)
	assert.Equal(t, "Выкатываем в пятницу", inline.AnchorText)
	assert.True(t, inline.Resolved)
	assert.Empty(t, f.puts)
}

// A failed name lookup degrades to ids with a note; failed comments are
// reported, never silently empty.
func TestGetConfluencePage_DegradesVisibly(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	f.usersErr = errors.New("user bulk: 500")
	f.commentsErr = errors.New("comments: 500")
	view := readPage(t, d, f, `{"page":"98765"}`)
	assert.Contains(t, view.Text, "⟦1:@"+cfMentionID+"⟧")
	assert.Len(t, view.Notes, 2)
	assert.Contains(t, view.Notes[0], "comments unavailable")
	assert.Contains(t, view.Notes[1], "user names unavailable")
	assert.Empty(t, view.Comments)
}

func TestGetConfluencePage_TruncatesTextAndComments(t *testing.T) {
	d := openDB(t)
	db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	long := strings.Repeat("Ж", 59_990)
	f.pages[cfPageID] = ConfluencePage{ID: cfPageID, Kind: "page", Title: "Big", Version: 3,
		Storage: "<p>" + long + " " + `<ac:link><ri:user ri:account-id="` + cfMentionID + `" /></ac:link>` + " tail text</p><p>Hidden.</p>"}
	for i := range 250 {
		f.comments = append(f.comments, ConfluenceComment{ID: strconv.Itoa(i + 1), Kind: "footer", Body: "c"})
	}
	view := readPage(t, d, f, `{"page":"98765"}`)
	assert.True(t, view.Truncated)
	rawToken := "⟦1:@" + cfMentionID + "⟧"
	assert.Equal(t, len([]rune(long+" "+rawToken+" tail text\n\nHidden.")), view.TotalRunes, "total_runes counts the raw text")
	assert.Equal(t, "Ж ", string([]rune(view.Text)[59_989:59_991]), "the cut backs off before a marker it would split")
	assert.NotContains(t, view.Text, "⟦", "the split marker is not shown half")
	assert.LessOrEqual(t, len([]rune(view.Text)), 60_000)
	assert.Len(t, view.Comments, 200)
	assert.True(t, view.CommentsTruncated)
}

func TestGetConfluencePage_ResolvesURLsAndTitles(t *testing.T) {
	d := openDB(t)
	src := seedConfluenceTask(t, d)
	addTaskPage(t, d, src, cfPageID, "Rollout plan", "How we roll out.", false)
	addTaskPage(t, d, src, "2001", "Incident review", "Review A.", false)
	addTaskPage(t, d, src, "2002", "Incident review", "Review B.", false)
	indexConfluence(t, d)
	f := newFakeConfluence()

	assert.Equal(t, cfPageID, readPage(t, d, f, `{"page":"`+cfURL+`"}`).ID)
	assert.Equal(t, cfPageID, readPage(t, d, f, `{"page":"https://test.atlassian.net/wiki/pages/viewpage.action?pageId=98765"}`).ID)
	assert.Equal(t, cfPageID, readPage(t, d, f, `{"page":"rollout plan"}`).ID, "a unique title resolves")

	gets := f.gets
	out, err := NewGetConfluencePage(confluenceFactory(f)).Execute(context.Background(), d, Call{Args: json.RawMessage(`{"page":"Incident review"}`)})
	require.NoError(t, err)
	amb, ok := out.(confluenceCandidatesView)
	require.True(t, ok, "got %T", out)
	assert.True(t, amb.Ambiguous)
	ids := []string{amb.Candidates[0].PageID, amb.Candidates[1].PageID}
	assert.ElementsMatch(t, []string{"2001", "2002"}, ids, "nothing is guessed")
	assert.Equal(t, gets, f.gets, "an ambiguous title never reads a page")

	_, err = NewGetConfluencePage(confluenceFactory(f)).Execute(context.Background(), d, Call{Args: json.RawMessage(`{"page":"https://other.example.com/wiki/pages/1"}`)})
	assert.Contains(t, verr(t, err), "not on a connected Atlassian site")
	_, err = NewGetConfluencePage(confluenceFactory(f)).Execute(context.Background(), d, Call{Args: json.RawMessage(`{"page":"no such thing anywhere"}`)})
	assert.Contains(t, verr(t, err), "no synced Confluence page matches")
}

func TestGetConfluencePage_ErrorsAreActionable(t *testing.T) {
	d := openDB(t)
	accountID := db.SeedTestJiraAccount(t, d)
	f := newFakeConfluence()
	get := NewGetConfluencePage(confluenceFactory(f))
	run := func(args string) error {
		_, err := get.Execute(context.Background(), d, Call{Args: json.RawMessage(args)})
		return err
	}
	assert.Contains(t, verr(t, run(`{"page":"111"}`)), "was not found")
	f.getErr = &jira.HTTPStatusError{Status: 401, Body: "Unauthorized; scope does not match"}
	assert.Equal(t, "Confluence access not granted — run: watchtower jira login --account "+strconv.FormatInt(accountID, 10)+" --with-confluence",
		verr(t, run(`{"page":"98765"}`)))
	f.getErr = jira.ErrAuthRevoked
	assert.Contains(t, verr(t, run(`{"page":"98765"}`)), "sign-in expired")
	acct, err := d.GetJiraAccount(accountID)
	require.NoError(t, err)
	assert.NotEqual(t, "revoked", acct.Status, "a read tool never writes (AGENT-06)")
}
