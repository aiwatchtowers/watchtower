package slack

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGetMessageReactions(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.get", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"type":    "message",
			"channel": "C001",
			"message": map[string]any{
				"ts":   "1700000001.000000",
				"text": "great work",
				"reactions": []map[string]any{
					{"name": "thumbsup", "count": 2, "users": []string{"U001", "U002"}},
					{"name": "tada", "count": 1, "users": []string{"U003"}},
				},
			},
		})
	})

	c := newTestClient(t, mux)
	reactions, err := c.GetMessageReactions(context.Background(), "C001", "1700000001.000000")
	require.NoError(t, err)
	require.Len(t, reactions, 2)
	assert.Equal(t, "thumbsup", reactions[0].Name)
	assert.Equal(t, 2, reactions[0].Count)
	assert.Equal(t, []string{"U001", "U002"}, reactions[0].Users)
	assert.Equal(t, "tada", reactions[1].Name)
	assert.Equal(t, 1, reactions[1].Count)
}

func TestGetMessageReactionsError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.get", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "message_not_found",
		})
	})

	c := newTestClient(t, mux)
	reactions, err := c.GetMessageReactions(context.Background(), "C001", "1700000001.000000")
	assert.Error(t, err)
	assert.Nil(t, reactions)
	assert.Contains(t, err.Error(), "message_not_found")
}

func TestListUserReactions(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var items []map[string]any
		if page == 1 {
			items = []map[string]any{
				{
					"type":    "message",
					"channel": "C001",
					"message": map[string]any{
						"ts":   "1700000001.000000",
						"text": "first reacted message",
						"reactions": []map[string]any{
							{"name": "white_check_mark", "count": 1, "users": []string{"U001"}},
						},
					},
				},
			}
		} else {
			items = []map[string]any{
				{
					"type":    "message",
					"channel": "C002",
					"message": map[string]any{
						"ts":   "1700000002.000000",
						"text": "second reacted message",
						"reactions": []map[string]any{
							{"name": "ticket", "count": 1, "users": []string{"U001"}},
						},
					},
				},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":    true,
			"items": items,
			"paging": map[string]any{
				"count": 1,
				"total": 2,
				"page":  page,
				"pages": 2,
			},
		})
	})

	c := newTestClient(t, mux)
	items, err := c.ListUserReactions(context.Background(), "U001")
	require.NoError(t, err)
	require.Len(t, items, 2)

	assert.Equal(t, "C001", items[0].Channel)
	require.NotNil(t, items[0].Message)
	assert.Equal(t, "1700000001.000000", items[0].Message.Timestamp)
	require.Len(t, items[0].Reactions, 1)
	assert.Equal(t, "white_check_mark", items[0].Reactions[0].Name)

	assert.Equal(t, "C002", items[1].Channel)
	require.NotNil(t, items[1].Message)
	assert.Equal(t, "1700000002.000000", items[1].Message.Timestamp)
	require.Len(t, items[1].Reactions, 1)
	assert.Equal(t, "ticket", items[1].Reactions[0].Name)

	assert.Equal(t, int32(2), callCount.Load(), "should have fetched exactly two pages")
}

func TestListUserReactionsSinglePage(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		callCount.Add(1)
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"items": []map[string]any{
				{
					"type":    "message",
					"channel": "C001",
					"message": map[string]any{
						"ts":   "1700000001.000000",
						"text": "only reacted message",
						"reactions": []map[string]any{
							{"name": "eyes", "count": 1, "users": []string{"U001"}},
						},
					},
				},
			},
			"paging": map[string]any{
				"count": 1,
				"total": 1,
				"page":  1,
				"pages": 1,
			},
		})
	})

	c := newTestClient(t, mux)
	items, err := c.ListUserReactions(context.Background(), "U001")
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "C001", items[0].Channel)
	assert.Equal(t, int32(1), callCount.Load(), "single page should stop after the first request")
}

func TestListUserReactionsError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "invalid_auth",
		})
	})

	c := newTestClient(t, mux)
	items, err := c.ListUserReactions(context.Background(), "U001")
	assert.Error(t, err)
	assert.Nil(t, items)
	assert.Contains(t, err.Error(), "invalid_auth")
}

func TestGetChannelReadCursor(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"channel": map[string]any{
				"id":        "C001",
				"last_read": "1700000005.000000",
			},
		})
	})

	c := newTestClient(t, mux)
	cursor, err := c.GetChannelReadCursor(context.Background(), "C001")
	require.NoError(t, err)
	assert.Equal(t, "1700000005.000000", cursor)
}

func TestGetChannelReadCursorError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "channel_not_found",
		})
	})

	c := newTestClient(t, mux)
	cursor, err := c.GetChannelReadCursor(context.Background(), "C001")
	assert.Error(t, err)
	assert.Equal(t, "", cursor)
	assert.Contains(t, err.Error(), "channel_not_found")
}
