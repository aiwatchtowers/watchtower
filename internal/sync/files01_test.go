package sync

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
)

// canaryMux is a Slack API whose every name and text field is a canary.
func canaryMux() *http.ServeMux {
	c := logcanary.Text
	user := func(id string) map[string]any {
		return map[string]any{
			"id": id, "name": c("user.name"), "real_name": c("user.real_name"),
			"profile": map[string]any{"display_name": c("user.display_name"), "email": "u@example.com"},
		}
	}
	msg := func(ts string, extra map[string]any) map[string]any {
		m := map[string]any{"type": "message", "user": "U001", "text": c("message.text"), "ts": ts}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	reply := func(w http.ResponseWriter, v map[string]any) {
		w.Header().Set("Content-Type", "application/json")
		v["ok"] = true
		_ = json.NewEncoder(w).Encode(v)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"team": map[string]any{"id": "T1", "name": c("team.name"), "domain": c("team.domain")}})
	})
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"user": c("auth.user"), "user_id": "U001", "team": c("auth.team"), "team_id": "T1"})
	})
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"members": []any{user("U001")}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		reply(w, map[string]any{"user": user(r.FormValue("user"))})
	})
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"channels": []any{map[string]any{
			"id": "C001", "name": c("channel.name"), "is_channel": true, "is_member": true, "num_members": 3,
			"topic": map[string]any{"value": c("channel.topic")}, "purpose": map[string]any{"value": c("channel.purpose")},
		}}, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"messages": []any{
			msg("1740567600.000100", map[string]any{"reply_count": 1, "thread_ts": "1740567600.000100"}),
		}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, map[string]any{"messages": []any{
			msg("1740567600.000100", map[string]any{"thread_ts": "1740567600.000100", "reply_count": 1}),
			msg("1740567600.000200", map[string]any{"thread_ts": "1740567600.000100"}),
		}, "has_more": false, "response_metadata": map[string]any{"next_cursor": ""}})
	})
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, _ *http.Request) {
		m := msg("1740567600.000300", map[string]any{
			"username": c("search.username"),
			"channel":  map[string]any{"id": "C001", "name": c("search.channel.name")},
		})
		reply(w, map[string]any{"messages": map[string]any{
			"matches": []any{m},
			"paging":  map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
			"total":   1,
		}})
	})
	return mux
}

// TestFILES01_SyncNeverLogsNames runs the full and the search-based sync
// against a Slack whose names and texts are canaries and asserts none of them
// reached the log.
func TestFILES01_SyncNeverLogsNames(t *testing.T) {
	sink := logcanary.Capture(t)
	ts := newTestSetup(t, canaryMux())
	ts.orch.SetLogger(sink.Logger())

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{Full: true}))
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	require.Contains(t, sink.String(), "channel ", "the sync logged nothing; the guard would be vacuous")
	sink.AssertClean(t)
}
