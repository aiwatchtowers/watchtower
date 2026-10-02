package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	watchtowerslack "watchtower/internal/slack"
)

// stubSlackAPI points the Slack client seam at mux for the test.
func stubSlackAPI(t *testing.T, mux *http.ServeMux) slackSender {
	t.Helper()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return slackSender{watchtowerslack.NewClientWithAPIUnlimited(goslack.New("xoxp-test", goslack.OptionAPIURL(srv.URL+"/")))}
}

func writeSlackJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// The retry's landed-message check (send_slack_message) reads history from
// `oldest`, follows the cursor a bounded number of pages, and reports "more"
// when it stopped short — the caller then refuses rather than re-posting.
func TestSlackSender_RecentMessagesHistoryPagesAndReportsMore(t *testing.T) {
	var oldest []string
	pages := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		oldest = append(oldest, r.FormValue("oldest"))
		pages++
		writeSlackJSON(w, map[string]any{"ok": true, "has_more": true,
			"messages":          []map[string]any{{"user": "U1", "text": "hi", "ts": fmt.Sprintf("1800000000.%06d", pages)}},
			"response_metadata": map[string]any{"next_cursor": "c"}})
	})
	s := stubSlackAPI(t, mux)

	msgs, more, err := s.RecentMessages(context.Background(), "C1", "", "1700000000.000000")
	require.NoError(t, err)
	assert.True(t, more, "a capped read must say there may be more")
	assert.Len(t, msgs, slackLandedCheckPages)
	assert.Equal(t, slackLandedCheckPages, pages)
	for _, o := range oldest {
		assert.Equal(t, "1700000000.000000", o)
	}
}

func TestSlackSender_RecentMessagesHistoryLastPage(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, _ *http.Request) {
		writeSlackJSON(w, map[string]any{"ok": true, "has_more": false,
			"messages": []map[string]any{{"user": "U1", "text": "hi", "ts": "1800000000.000001"}}})
	})
	msgs, more, err := stubSlackAPI(t, mux).RecentMessages(context.Background(), "C1", "", "1700000000.000000")
	require.NoError(t, err)
	assert.False(t, more)
	assert.Equal(t, "U1", msgs[0].User)
}

// In a thread the replies are filtered to those after `oldest`; the parent
// is kept (the tool skips it by ts).
func TestSlackSender_RecentMessagesThreadFiltersByOldest(t *testing.T) {
	var ts string
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		ts = r.FormValue("ts")
		writeSlackJSON(w, map[string]any{"ok": true, "has_more": false, "messages": []map[string]any{
			{"user": "U1", "text": "parent", "ts": "1800000000.000001"},
			{"user": "U1", "text": "old", "ts": "1699999999.000001"},
			{"user": "U1", "text": "new", "ts": "1800000000.000002"},
		}})
	})
	msgs, more, err := stubSlackAPI(t, mux).RecentMessages(context.Background(), "C1", "1800000000.000001", "1700000000.000000")
	require.NoError(t, err)
	assert.False(t, more)
	assert.Equal(t, "1800000000.000001", ts)
	var texts []string
	for _, m := range msgs {
		texts = append(texts, m.Text)
	}
	assert.Equal(t, []string{"parent", "new"}, texts)
}
