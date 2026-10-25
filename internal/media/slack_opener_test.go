package media

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/issuekey"
	"watchtower/internal/slack"
)

// fakeSlackFiles is one account's Slack client as SlackOpener uses it.
type fakeSlackFiles struct {
	body    string
	err     error
	readErr error
	urls    []string
}

func (f *fakeSlackFiles) DownloadFile(_ context.Context, u string, _ int64) (io.ReadCloser, string, error) {
	f.urls = append(f.urls, u)
	if f.err != nil {
		return nil, "", f.err
	}
	var r io.Reader = strings.NewReader(f.body)
	if f.readErr != nil {
		r = io.MultiReader(r, failReader{f.readErr})
	}
	return io.NopCloser(r), "image/png", nil
}

type failReader struct{ err error }

func (e failReader) Read([]byte) (int, error) { return 0, e.err }

func slackItem(ch, fetchURL string) db.MediaItem {
	return db.MediaItem{Kind: "image", ParentKind: "slack", SlackChannelID: ch, SlackTS: "1.0", Locator: "F1", FetchURL: fetchURL}
}

func TestSlackOpener_DownloadsWithAccountClient(t *testing.T) {
	one, two := &fakeSlackFiles{body: "one"}, &fakeSlackFiles{body: "two"}
	op := SlackOpener{Clients: map[int64]SlackFileDownloader{1: one, 2: two}}

	rc, typ, err := op.Open(context.Background(), slackItem("2:C1", "https://files.slack.com/f"), 100)
	require.NoError(t, err)
	b, err := io.ReadAll(rc)
	require.NoError(t, err)
	require.NoError(t, rc.Close())
	assert.Equal(t, "two", string(b), "the item's own account downloads it")
	assert.Equal(t, "image/png", typ)
	assert.Empty(t, one.urls)
	assert.Equal(t, []string{"https://files.slack.com/f"}, two.urls)

	// No URL (an external file) and the client's refusals end the item gone.
	_, _, err = op.Open(context.Background(), slackItem("1:C1", ""), 100)
	require.ErrorIs(t, err, ErrGone)
	assert.Empty(t, one.urls, "an item without a URL is never downloaded")
	for _, e := range []error{slack.ErrFileGone, slack.ErrFileURLRefused} {
		one.err = e
		_, _, err = op.Open(context.Background(), slackItem("1:C1", "https://files.slack.com/f"), 100)
		require.ErrorIs(t, err, ErrGone, e.Error())
	}
	one.err = slack.ErrTooLarge
	_, _, err = op.Open(context.Background(), slackItem("1:C1", "https://files.slack.com/f"), 100)
	require.ErrorIs(t, err, ErrTooLarge)

	// Too large while reading becomes the pass's ErrTooLarge too.
	one.err, one.readErr = nil, slack.ErrTooLarge
	rc, _, err = op.Open(context.Background(), slackItem("1:C1", "https://files.slack.com/f"), 100)
	require.NoError(t, err)
	_, err = io.ReadAll(rc)
	require.ErrorIs(t, err, ErrTooLarge)

	// Another error is a failed attempt, and so is an account without a client.
	one.readErr, one.err = nil, errors.New("connection reset")
	_, _, err = op.Open(context.Background(), slackItem("1:C1", "https://files.slack.com/f"), 100)
	require.Error(t, err)
	require.NotErrorIs(t, err, ErrGone)
	_, _, err = op.Open(context.Background(), slackItem("3:C1", "https://files.slack.com/f"), 100)
	require.Error(t, err)
	require.NotErrorIs(t, err, ErrGone)
}

// keyEnv is a database with one known Jira project and a Slack message.
func keyEnv(t *testing.T) (*db.DB, func(context.Context, db.MediaItem) error) {
	t.Helper()
	d := db.OpenTestDB(t)
	db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1, Key: "ABC-1", ProjectKey: "ABC", Summary: "S", Status: "O", StatusCategory: "todo",
		CreatedAt: "now", UpdatedAt: "now", SyncedAt: "now",
	}))
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1.0', '1:U1', 'see the screenshot')`)
	require.NoError(t, err)
	return d, SlackAfterDescribed(issuekey.NewKeyDetector(d))
}

func TestSlackAfterDescribed_LinksJiraKeyOnScreenshot(t *testing.T) {
	d, hook := keyEnv(t)
	it := db.MediaItem{Kind: "image", ParentKind: "slack", SlackChannelID: "1:C1", SlackTS: "1.0", Status: "ok",
		Title: "Error dialog", Body: "A dialog shows an error.", ImageText: "Failed: ABC-17 is blocked"}

	require.NoError(t, hook(context.Background(), it))
	links, err := d.GetJiraSlackLinksByIssue("ABC-17")
	require.NoError(t, err)
	require.Len(t, links, 1)
	assert.Equal(t, "1:C1", links[0].ChannelID)
	assert.Equal(t, "1.0", links[0].MessageTS)
	assert.Equal(t, "mention", links[0].LinkType)
}

func TestSlackAfterDescribed_SkipsLinkRows(t *testing.T) {
	d, hook := keyEnv(t)
	link := db.MediaItem{Kind: "link", ParentKind: "slack", SlackChannelID: "1:C1", SlackTS: "1.0", Status: "ok",
		Locator: "url:https://example.com/a", Title: "ABC-1 page", Body: "The page says ABC-1 is done."}
	require.NoError(t, hook(context.Background(), link))
	other := db.MediaItem{Kind: "image", ParentKind: "confluence", ExtSourceID: 1, ExtID: "p1", Status: "ok", ImageText: "ABC-1"}
	require.NoError(t, hook(context.Background(), other))

	links, err := d.GetJiraSlackLinksByIssue("ABC-1")
	require.NoError(t, err)
	assert.Empty(t, links, "a link summary and a non-Slack image never feed the key detector")
}
