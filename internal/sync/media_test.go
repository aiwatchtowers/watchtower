package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// mediaRow is one media_items row as the Slack discovery tests read it.
type mediaRow struct {
	Kind, Locator, FetchURL, Name, MediaType, ContentKey, Status, Scope string
	Size                                                                int64
	FromOwner                                                           bool
}

func slackMediaRows(t *testing.T, d *db.DB, channelID, ts string) []mediaRow {
	t.Helper()
	rows, err := d.Query(`SELECT kind, locator, fetch_url, name, media_type, content_key, status, scope, size_bytes, from_owner
		FROM media_items WHERE slack_channel_id = ? AND slack_ts = ? ORDER BY kind, locator`, channelID, ts)
	require.NoError(t, err)
	defer rows.Close()
	var out []mediaRow
	for rows.Next() {
		var r mediaRow
		require.NoError(t, rows.Scan(&r.Kind, &r.Locator, &r.FetchURL, &r.Name, &r.MediaType, &r.ContentKey,
			&r.Status, &r.Scope, &r.Size, &r.FromOwner))
		out = append(out, r)
	}
	require.NoError(t, rows.Err())
	return out
}

func locators(rows []mediaRow) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Locator
	}
	return out
}

// mediaTS is a message time after the media start the tests set.
const (
	mediaTS     = "1700000100.000100"
	mediaOldTS  = "1699999000.000100"
	mediaStartS = 1700000000
)

// newMediaSetup is newTestSetup with media_state.start_at moved before
// mediaTS, so the fixtures' messages count as new content.
func newMediaSetup(t *testing.T, mux *http.ServeMux) *testSetup {
	t.Helper()
	ts := newTestSetup(t, mux)
	require.NoError(t, ts.db.SetMediaStartAt(time.Unix(mediaStartS, 0)))
	return ts
}

func imageFile(id string) goslack.File {
	return goslack.File{
		ID: id, Name: id + ".png", Mimetype: "image/png", Size: 4096, Mode: "hosted",
		URLPrivate:         "https://files.slack.com/files-pri/T1-" + id + "/" + id + ".png",
		URLPrivateDownload: "https://files.slack.com/files-pri/T1-" + id + "/download/" + id + ".png",
	}
}

func TestUpsertMessagePage_RecordsFilesAndLinks(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	ch := ts.ns("C001")
	pdf := goslack.File{ID: "F9", Name: "a.pdf", Mimetype: "application/pdf", Mode: "hosted", URLPrivate: "https://files.slack.com/a.pdf"}
	noDownload := imageFile("F2")
	noDownload.URLPrivateDownload = ""
	var msg goslack.Message
	msg.Timestamp, msg.User = mediaTS, "U001"
	msg.Text = "look <https://example.com/post?utm_source=x|the post> and <https://example.com/post> and <@U002>"
	msg.Files = []goslack.File{imageFile("F1"), noDownload, pdf}

	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)

	rows := slackMediaRows(t, ts.db, ch, mediaTS)
	require.Len(t, rows, 3, "two images and one deduplicated link; the PDF is no image")
	assert.Equal(t, mediaRow{Kind: "image", Locator: "F1", Name: "F1.png", MediaType: "image/png", Size: 4096,
		FetchURL: "https://files.slack.com/files-pri/T1-F1/download/F1.png", Status: "pending",
		Scope: fmt.Sprintf("slack:%d", ts.accountID)}, rows[0])
	assert.Equal(t, "https://files.slack.com/files-pri/T1-F2/F2.png", rows[1].FetchURL, "url_private when there is no download URL")
	assert.Equal(t, "link", rows[2].Kind)
	assert.Equal(t, "url:https://example.com/post", rows[2].Locator)
	assert.Equal(t, rows[2].Locator, rows[2].ContentKey)
	assert.Empty(t, rows[2].FetchURL)

	// An edit that drops the link and one image replaces both kinds.
	msg.Text = "edited, no link"
	msg.Files = []goslack.File{imageFile("F1")}
	msg.Edited = &goslack.Edited{User: "U001", Timestamp: "1700000200.000000"}
	_, err = ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)
	assert.Equal(t, []string{"F1"}, locators(slackMediaRows(t, ts.db, ch, mediaTS)))
}

// A Slack tombstone (a deleted thread root Slack still returns, subtype
// tombstone) drops every image and link of the message.
func TestUpsertMessagePage_TombstoneDropsMedia(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	ch := ts.ns("C001")
	var msg goslack.Message
	msg.Timestamp, msg.User, msg.Text = mediaTS, "U001", "see <https://example.com/a>"
	msg.Files = []goslack.File{imageFile("F1")}
	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)
	require.Len(t, slackMediaRows(t, ts.db, ch, mediaTS), 2)

	var tomb goslack.Message
	tomb.Timestamp, tomb.SubType, tomb.Text, tomb.ReplyCount = mediaTS, "tombstone", "This message was deleted.", 2
	tomb.Files = []goslack.File{imageFile("F1")} // whatever Slack sends with it, a tombstone keeps nothing
	_, err = ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{tomb})
	require.NoError(t, err)
	assert.Empty(t, slackMediaRows(t, ts.db, ch, mediaTS))
}

func TestSlackMedia_ExternalFileSkipped(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	ch := ts.ns("C001")
	ext := imageFile("F1")
	ext.IsExternal, ext.ExternalType = true, "gdrive"
	mode := imageFile("F2")
	mode.Mode = "external"
	var msg goslack.Message
	msg.Timestamp, msg.User = mediaTS, "U001"
	msg.Files = []goslack.File{ext, mode}

	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)

	rows := slackMediaRows(t, ts.db, ch, mediaTS)
	require.Len(t, rows, 2)
	for _, r := range rows {
		assert.Equal(t, "skipped_type", r.Status, r.Locator)
		assert.Empty(t, r.FetchURL, "%s: an external file carries no URL to download", r.Locator)
	}
	pending, err := ts.db.ListPendingMedia(context.Background(), true, db.MediaCursor{}, 10)
	require.NoError(t, err)
	assert.Empty(t, pending, "an external file is never listed for the pass")
}

func TestSlackMedia_OldMessageNotRecorded(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	ch := ts.ns("C001")
	var old, fresh goslack.Message
	old.Timestamp, old.User, old.Text = mediaOldTS, "U001", "<https://example.com/old>"
	old.Files = []goslack.File{imageFile("F1")}
	fresh.Timestamp, fresh.User, fresh.Text = mediaTS, "U001", "<https://example.com/new>"

	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{old, fresh})
	require.NoError(t, err)
	assert.Empty(t, slackMediaRows(t, ts.db, ch, mediaOldTS), "content older than media start_at is never recorded")
	assert.Len(t, slackMediaRows(t, ts.db, ch, mediaTS), 1)
}

func TestSlackMedia_SecretAndSyncedLinksNotRecorded(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	_, err := ts.db.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://tracker.example.net", SiteName: "T"})
	require.NoError(t, err)
	ts.orch.config.Knowledge.LinkFetchDenyHosts = []string{"intranet.example.org"}
	ch := ts.ns("C001")
	var msg goslack.Message
	msg.Timestamp, msg.User = mediaTS, "U001"
	msg.Text = "<https://example.com/reset?token=abc123> <https://acme.atlassian.net/browse/AB-1> " +
		"<https://files.slack.com/files-pri/x> <https://tracker.example.net/browse/AB-2> " +
		"<https://wiki.intranet.example.org/page> <http://127.0.0.1/x> <https://example.com:8443/x> " +
		"<mailto:a@example.com> <https://user:pw@example.com/x> <https://example.com/ok|fine>"

	_, err = ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)
	assert.Equal(t, []string{"url:https://example.com/ok"}, locators(slackMediaRows(t, ts.db, ch, mediaTS)))
}

func TestSlackMedia_OwnerMessageFlagged(t *testing.T) {
	ts := newMediaSetup(t, defaultMux())
	ts.orch.account.CurrentUserID = ts.ns("U001")
	ch := ts.ns("C001")
	var own, other goslack.Message
	own.Timestamp, own.User, own.Text = mediaTS, "U001", "<https://example.com/a>"
	other.Timestamp, other.User, other.Text = "1700000101.000100", "U002", "<https://example.com/b>"

	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{own, other})
	require.NoError(t, err)
	ownRows := slackMediaRows(t, ts.db, ch, mediaTS)
	require.Len(t, ownRows, 1)
	assert.True(t, ownRows[0].FromOwner)
	otherRows := slackMediaRows(t, ts.db, ch, "1700000101.000100")
	require.Len(t, otherRows, 1)
	assert.False(t, otherRows[0].FromOwner)
}

// searchMediaMux answers search.messages with the matches stored in matches
// (a []map[string]any, one page) and counts conversations.history calls,
// answering each with history(form).
func searchMediaMux(matchesV *atomic.Value, historyCalls *atomic.Int32, history func(r *http.Request) []map[string]any) *http.ServeMux {
	mux := searchAuditMux(func(w http.ResponseWriter, _ *http.Request) {
		matches, _ := matchesV.Load().([]map[string]any)
		jsonOK(w, map[string]any{"ok": true, "messages": map[string]any{
			"matches": matches,
			"paging":  map[string]any{"count": 100, "total": len(matches), "page": 1, "pages": 1},
			"total":   len(matches),
		}})
	})
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		historyCalls.Add(1)
		var msgs []map[string]any
		if history != nil {
			msgs = history(r)
		}
		jsonOK(w, map[string]any{"ok": true, "messages": msgs, "has_more": false})
	})
	return mux
}

// slackTrue reports a Slack boolean form value (slack-go sends 1).
func slackTrue(v string) bool { return v == "1" || v == "true" }

func fileJSON(id string) map[string]any {
	f := imageFile(id)
	b, _ := json.Marshal(f)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

func TestSearchPage_RecordsLinksKeepsImagesWithoutFiles(t *testing.T) {
	var calls atomic.Int32
	match := func(text string, files ...map[string]any) map[string]any {
		m := map[string]any{"ts": mediaTS, "user": "U001", "text": text, "channel": map[string]any{"id": "C001", "name": "general"}}
		if len(files) > 0 {
			m["files"] = files
		}
		return m
	}
	var matches atomic.Value
	matches.Store([]map[string]any{match("now <https://example.com/new>")})
	ts := newMediaSetup(t, searchMediaMux(&matches, &calls, nil))
	ch := ts.ns("C001")

	var msg goslack.Message
	msg.Timestamp, msg.User, msg.Text = mediaTS, "U001", "was <https://example.com/old>"
	msg.Files = []goslack.File{imageFile("F1")}
	_, err := ts.orch.upsertMessagePage(context.Background(), ch, []goslack.Message{msg})
	require.NoError(t, err)

	require.NoError(t, ts.orch.syncViaSearch(context.Background()))
	assert.Equal(t, []string{"F1", "url:https://example.com/new"}, locators(slackMediaRows(t, ts.db, ch, mediaTS)),
		"a match without files replaces the links and keeps the images")
	assert.Zero(t, calls.Load(), "a plain match is not looked up")

	// A match that carries files replaces the images too.
	matches.Store([]map[string]any{match("now <https://example.com/new>", fileJSON("F2"))})
	require.NoError(t, ts.orch.syncViaSearch(context.Background()))
	assert.Equal(t, []string{"F2", "url:https://example.com/new"}, locators(slackMediaRows(t, ts.db, ch, mediaTS)))

	// A tombstone match drops both kinds.
	tomb := match("This message was deleted.")
	tomb["subtype"] = "tombstone"
	matches.Store([]map[string]any{tomb})
	require.NoError(t, ts.orch.syncViaSearch(context.Background()))
	assert.Empty(t, slackMediaRows(t, ts.db, ch, mediaTS))
}

func TestSearchPage_FileShareFallbackCapped(t *testing.T) {
	// An old file share, first in the page, is never looked up.
	list := []map[string]any{{"ts": mediaOldTS, "user": "U001", "upload": true,
		"channel": map[string]any{"id": "C001", "name": "general"}}}
	for i := range 25 {
		list = append(list, map[string]any{
			"ts": fmt.Sprintf("17000001%02d.000100", i), "user": "U001", "text": "",
			"channel": map[string]any{"id": "C001", "name": "general"},
			"subtype": "file_share", "upload": i%2 == 0,
		})
	}
	var calls atomic.Int32
	var bad atomic.Value
	history := func(r *http.Request) []map[string]any {
		ts := r.Form.Get("oldest")
		if r.Form.Get("latest") != ts || !slackTrue(r.Form.Get("inclusive")) || r.Form.Get("limit") != "1" || r.Form.Get("channel") != "C001" {
			bad.Store(r.Form.Encode())
		}
		return []map[string]any{{"ts": ts, "user": "U001", "type": "message", "subtype": "file_share", "files": []map[string]any{fileJSON("F" + ts)}}}
	}
	var matches atomic.Value
	matches.Store(list)
	ts := newMediaSetup(t, searchMediaMux(&matches, &calls, history))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.EqualValues(t, maxSlackFileLookups, calls.Load(), "at most 20 lookups per account per cycle")
	assert.Nil(t, bad.Load(), "each lookup asks for exactly that message")

	ch := ts.ns("C001")
	withImage := 0
	for i := range 25 {
		for _, r := range slackMediaRows(t, ts.db, ch, fmt.Sprintf("17000001%02d.000100", i)) {
			if r.Kind == "image" {
				withImage++
			}
		}
	}
	assert.Equal(t, maxSlackFileLookups, withImage, "each looked-up message records its image")

	// The next cycle has a fresh budget.
	calls.Store(0)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.EqualValues(t, maxSlackFileLookups, calls.Load())
}

// A file-share thread reply is looked up in its thread (conversations.replies
// matched by ts), not in channel history, inside the same per-cycle cap.
func TestSearchPage_FileShareReplyLookedUpInThread(t *testing.T) {
	const parentTS = "1700000050.000100"
	var list []map[string]any
	for i := range 25 {
		m := map[string]any{
			"ts": fmt.Sprintf("17000001%02d.000100", i), "user": "U001", "text": "",
			"channel": map[string]any{"id": "C001", "name": "general"}, "subtype": "file_share",
			"permalink": fmt.Sprintf("https://acme.slack.com/archives/C001/p17000001%02d000100", i),
		}
		if i%2 == 0 { // a thread reply
			m["permalink"] = m["permalink"].(string) + "?thread_ts=" + parentTS + "&cid=C001"
		}
		list = append(list, m)
	}
	var historyCalls, replyCalls atomic.Int32
	var bad atomic.Value
	history := func(r *http.Request) []map[string]any {
		ts := r.Form.Get("oldest")
		return []map[string]any{{"ts": ts, "user": "U001", "type": "message", "subtype": "file_share", "files": []map[string]any{fileJSON("F" + ts)}}}
	}
	var matches atomic.Value
	matches.Store(list)
	mux := searchMediaMux(&matches, &historyCalls, history)
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		replyCalls.Add(1)
		if r.Form.Get("ts") != parentTS || r.Form.Get("channel") != "C001" {
			bad.Store(r.Form.Encode())
		}
		msgs := []map[string]any{{"ts": parentTS, "user": "U002", "type": "message", "text": "parent", "thread_ts": parentTS}}
		for i := 0; i < 25; i += 2 {
			ts := fmt.Sprintf("17000001%02d.000100", i)
			msgs = append(msgs, map[string]any{"ts": ts, "user": "U001", "type": "message", "subtype": "file_share",
				"thread_ts": parentTS, "files": []map[string]any{fileJSON("F" + ts)}})
		}
		jsonOK(w, map[string]any{"ok": true, "messages": msgs, "has_more": false})
	})
	ts := newMediaSetup(t, mux)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Nil(t, bad.Load(), "a reply is looked up in its own thread")
	assert.EqualValues(t, maxSlackFileLookups, historyCalls.Load()+replyCalls.Load(), "replies count toward the same cap")
	assert.EqualValues(t, 10, replyCalls.Load(), "the first 20 matches hold 10 replies")

	ch := ts.ns("C001")
	for i := range 20 {
		mts := fmt.Sprintf("17000001%02d.000100", i)
		rows := slackMediaRows(t, ts.db, ch, mts)
		require.Len(t, rows, 1, mts)
		assert.Equal(t, "F"+mts, rows[0].Locator)
	}
	assert.Empty(t, slackMediaRows(t, ts.db, ch, parentTS), "only the matched reply is saved")
}

// The media plan is read once per Run: a later page or thread of the same
// run reuses it, and the next Run reads it afresh.
func TestMediaPlan_ReadOncePerRun(t *testing.T) {
	var calls atomic.Int32
	var matches atomic.Value
	matches.Store([]map[string]any{{"ts": mediaTS, "user": "U001", "text": "hi",
		"channel": map[string]any{"id": "C001", "name": "general"}}})
	ts := newMediaSetup(t, searchMediaMux(&matches, &calls, nil))
	ctx := context.Background()

	first := ts.orch.mediaPlan(ctx)
	require.NotNil(t, first)
	assert.Equal(t, time.Unix(mediaStartS, 0).UTC(), first.start.UTC())
	require.NoError(t, ts.db.SetMediaStartAt(time.Unix(mediaStartS+50, 0)))
	assert.Same(t, first, ts.orch.mediaPlan(ctx), "the same run reuses its plan")

	require.NoError(t, ts.orch.Run(ctx, SyncOptions{}))
	next := ts.orch.mediaPlan(ctx)
	require.NotNil(t, next)
	assert.Equal(t, time.Unix(mediaStartS+50, 0).UTC(), next.start.UTC(), "a new Run reads the plan afresh")
}

// A message whose ts does not parse records no media and says so.
func TestRecordSlackMedia_LogsUnparseableTS(t *testing.T) {
	ts := newMediaSetup(t, http.NewServeMux())
	var buf bytes.Buffer
	ts.orch.logger = log.New(&buf, "", 0)
	tx, err := ts.db.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	ts.orch.recordSlackMedia(context.Background(), tx, slackMediaWrite{channelID: ts.ns("C001"), ts: "not-a-ts",
		found: []db.MediaFound{{Kind: "link", Locator: "url:https://example.com/", ContentKey: "url:https://example.com/"}}})
	assert.Contains(t, buf.String(), "not-a-ts")
	assert.Equal(t, 1, bytes.Count(buf.Bytes(), []byte("\n")), "one line")
}
