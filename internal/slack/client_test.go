package slack

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	goslack "github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestClient creates a Client backed by the given test server.
func newTestClient(t *testing.T, mux *http.ServeMux) *Client {
	t.Helper()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	return NewClientWithAPIURL("xoxp-test-token", srv.URL+"/")
}

func TestGetTeamInfo(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		resp := map[string]any{
			"ok": true,
			"team": map[string]any{
				"id":     "T024BE7LD",
				"name":   "my-company",
				"domain": "my-company",
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	c := newTestClient(t, mux)
	info, err := c.GetTeamInfo(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "T024BE7LD", info.ID)
	assert.Equal(t, "my-company", info.Name)
	assert.Equal(t, "my-company", info.Domain)
}

func TestGetTeamInfoError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "invalid_auth",
		})
	})

	c := newTestClient(t, mux)
	_, err := c.GetTeamInfo(context.Background())
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "invalid_auth")
}

func TestGetUsers(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var members []map[string]any
		nextCursor := ""

		if page == 1 {
			members = []map[string]any{
				{"id": "U001", "name": "alice", "real_name": "Alice Smith"},
				{"id": "U002", "name": "bob", "real_name": "Bob Jones"},
			}
			nextCursor = "page2"
		} else {
			members = []map[string]any{
				{"id": "U003", "name": "carol", "real_name": "Carol White"},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"members": members,
			"response_metadata": map[string]any{
				"next_cursor": nextCursor,
			},
		})
	})

	c := newTestClient(t, mux)
	users, err := c.GetUsers(context.Background())
	require.NoError(t, err)
	assert.Len(t, users, 3)
	assert.Equal(t, "U001", users[0].ID)
	assert.Equal(t, "U003", users[2].ID)
}

func TestGetChannels(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var channels []map[string]any
		nextCursor := ""

		if page == 1 {
			channels = []map[string]any{
				{"id": "C001", "name": "general", "is_channel": true, "is_member": true},
				{"id": "C002", "name": "random", "is_channel": true, "is_member": true},
			}
			nextCursor = "page2"
		} else {
			channels = []map[string]any{
				{"id": "C003", "name": "dev", "is_channel": true, "is_member": false},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"channels": channels,
			"response_metadata": map[string]any{
				"next_cursor": nextCursor,
			},
		})
	})

	c := newTestClient(t, mux)
	channels, err := c.GetChannels(context.Background(), nil)
	require.NoError(t, err)
	assert.Len(t, channels, 3)
	assert.Equal(t, "C001", channels[0].ID)
	assert.Equal(t, "general", channels[0].Name)
	assert.Equal(t, "C003", channels[2].ID)
}

func TestGetConversationHistory(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"has_more": true,
			"messages": []map[string]any{
				{"type": "message", "user": "U001", "text": "Hello", "ts": "1700000001.000000"},
				{"type": "message", "user": "U002", "text": "World", "ts": "1700000002.000000"},
			},
			"response_metadata": map[string]any{
				"next_cursor": "next_page_cursor",
			},
		})
	})

	c := newTestClient(t, mux)
	resp, err := c.GetConversationHistory(context.Background(), HistoryOptions{
		ChannelID: "C001",
		Limit:     100,
	})
	require.NoError(t, err)
	assert.Len(t, resp.Messages, 2)
	assert.True(t, resp.HasMore)
	assert.Equal(t, "next_page_cursor", resp.NextCursor)
	assert.Equal(t, "Hello", resp.Messages[0].Text)
}

func TestGetConversationHistoryDefaultLimit(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"has_more": false,
			"messages": []map[string]any{},
			"response_metadata": map[string]any{
				"next_cursor": "",
			},
		})
	})

	c := newTestClient(t, mux)
	resp, err := c.GetConversationHistory(context.Background(), HistoryOptions{
		ChannelID: "C001",
		// Limit not set - should default to 200
	})
	require.NoError(t, err)
	assert.False(t, resp.HasMore)
}

func TestGetConversationReplies(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var msgs []map[string]any
		hasMore := false
		nextCursor := ""

		if page == 1 {
			msgs = []map[string]any{
				{"type": "message", "user": "U001", "text": "Thread parent", "ts": "1700000001.000000", "thread_ts": "1700000001.000000"},
				{"type": "message", "user": "U002", "text": "Reply 1", "ts": "1700000002.000000", "thread_ts": "1700000001.000000"},
			}
			hasMore = true
			nextCursor = "page2"
		} else {
			msgs = []map[string]any{
				{"type": "message", "user": "U003", "text": "Reply 2", "ts": "1700000003.000000", "thread_ts": "1700000001.000000"},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"has_more": hasMore,
			"messages": msgs,
			"response_metadata": map[string]any{
				"next_cursor": nextCursor,
			},
		})
	})

	c := newTestClient(t, mux)
	msgs, err := c.GetConversationReplies(context.Background(), "C001", "1700000001.000000")
	require.NoError(t, err)
	assert.Len(t, msgs, 3)
	assert.Equal(t, "Thread parent", msgs[0].Text)
	assert.Equal(t, "Reply 2", msgs[2].Text)
}

func TestContextCancellationDuringGetUsers(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"members": []map[string]any{},
			"response_metadata": map[string]any{
				"next_cursor": "",
			},
		})
	})

	c := newTestClient(t, mux)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := c.GetUsers(ctx)
	assert.Error(t, err)
}

func TestNewClient(t *testing.T) {
	c := NewClient("xoxp-test")
	assert.NotNil(t, c.api)
	assert.NotNil(t, c.rateLimiter)
}

// newUnlimitedTestClient creates a Client with unlimited rate limiter for fast tests.
func newUnlimitedTestClient(t *testing.T, mux *http.ServeMux) *Client {
	t.Helper()
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	return NewClientWithAPIURLUnlimited("xoxp-test-token", srv.URL+"/")
}

func TestNewClientWithAPIUnlimited(t *testing.T) {
	c := NewClientWithAPIURLUnlimited("xoxp-test", "http://127.0.0.1:0/")
	assert.NotNil(t, c.api)
	assert.NotNil(t, c.rateLimiter)
	assert.Nil(t, c.rateLimiter.gate, "unlimited limiter should have nil gate")
}

func TestAuthTest(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"user_id": "U12345",
			"user":    "testuser",
			"team_id": "T67890",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	resp, err := c.AuthTest(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "U12345", resp.UserID)
	assert.Equal(t, "testuser", resp.User)
	assert.Equal(t, "T67890", resp.TeamID)
}

func TestAuthTestError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "invalid_auth",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	resp, err := c.AuthTest(context.Background())
	assert.Error(t, err)
	assert.Nil(t, resp)
	assert.Contains(t, err.Error(), "invalid_auth")
}

func TestSearchMessages(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"messages": map[string]any{
				"total": 42,
				"paging": map[string]any{
					"page":  1,
					"pages": 2,
					"count": 100,
					"total": 42,
				},
				"matches": []map[string]any{
					{
						"type":    "message",
						"text":    "found message",
						"ts":      "1700000001.000000",
						"channel": map[string]any{"id": "C001", "name": "general"},
					},
				},
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	result, err := c.SearchMessages(context.Background(), "test query", 1)
	require.NoError(t, err)
	assert.Equal(t, 42, result.Total)
	assert.Equal(t, 1, result.Page)
	assert.Equal(t, 2, result.Pages)
	assert.Len(t, result.Messages, 1)
}

func TestSearchMessagesError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "not_authed",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	result, err := c.SearchMessages(context.Background(), "query", 1)
	assert.Error(t, err)
	assert.Nil(t, result)
}

func TestGetUserInfo(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"user": map[string]any{
				"id":        "U12345",
				"name":      "alice",
				"real_name": "Alice Smith",
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	user, err := c.GetUserInfo(context.Background(), "U12345")
	require.NoError(t, err)
	assert.Equal(t, "U12345", user.ID)
	assert.Equal(t, "alice", user.Name)
	assert.Equal(t, "Alice Smith", user.RealName)
}

func TestGetUserInfoError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "user_not_found",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	user, err := c.GetUserInfo(context.Background(), "UBAD")
	assert.Error(t, err)
	assert.Nil(t, user)
	assert.Contains(t, err.Error(), "user_not_found")
}

func TestGetEmoji(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/emoji.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"emoji": map[string]any{
				"shipit":   "https://example.com/shipit.png",
				"thumbsup": "alias:+1",
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	emojis, err := c.GetEmoji(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "https://example.com/shipit.png", emojis["shipit"])
	assert.Equal(t, "alias:+1", emojis["thumbsup"])
}

func TestGetEmojiError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/emoji.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "not_authed",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	emojis, err := c.GetEmoji(context.Background())
	assert.Error(t, err)
	assert.Nil(t, emojis)
}

func TestAPIStatsAndReset(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"user_id": "U001",
			"user":    "u",
			"team_id": "T001",
		})
	})
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":   true,
			"user": map[string]any{"id": "U001", "name": "a"},
		})
	})

	c := newUnlimitedTestClient(t, mux)

	// Make some requests across different tiers
	_, _ = c.AuthTest(context.Background())            // Tier2
	_, _ = c.AuthTest(context.Background())            // Tier2
	_, _ = c.GetUserInfo(context.Background(), "U001") // Tier4

	counts, retries := c.APIStats()
	assert.Equal(t, 2, counts[Tier2])
	assert.Equal(t, 1, counts[Tier4])
	assert.Equal(t, 0, retries)

	// Reset and verify
	c.ResetAPIStats()
	counts, retries = c.APIStats()
	assert.Equal(t, 0, counts[Tier2])
	assert.Equal(t, 0, counts[Tier4])
	assert.Equal(t, 0, retries)
}

func TestSetLogger(t *testing.T) {
	var buf bytes.Buffer
	logger := log.New(&buf, "test: ", 0)

	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"user_id": "U001",
			"user":    "u",
			"team_id": "T001",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	c.SetLogger(logger)
	assert.Equal(t, logger, c.logger)
	assert.Equal(t, logger, c.rateLimiter.logger)

	_, err := c.AuthTest(context.Background())
	require.NoError(t, err)
	assert.Contains(t, buf.String(), "auth.test")
}

func TestLogfNoLogger(t *testing.T) {
	c := &Client{}
	// Should not panic when logger is nil
	c.logf("test %s", "message")
}

func TestGetUsersWithOnPageCallback(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/users.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var members []map[string]any
		nextCursor := ""

		if page == 1 {
			members = []map[string]any{
				{"id": "U001", "name": "alice"},
				{"id": "U002", "name": "bob"},
			}
			nextCursor = "page2"
		} else {
			members = []map[string]any{
				{"id": "U003", "name": "carol"},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"members": members,
			"response_metadata": map[string]any{
				"next_cursor": nextCursor,
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	var pageCounts []int
	users, err := c.GetUsers(context.Background(), func(fetched int) {
		pageCounts = append(pageCounts, fetched)
	})
	require.NoError(t, err)
	assert.Len(t, users, 3)
	assert.Equal(t, []int{2, 3}, pageCounts)
}

func TestGetChannelsWithOnPageCallback(t *testing.T) {
	callCount := atomic.Int32{}
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		page := callCount.Add(1)

		var channels []map[string]any
		nextCursor := ""

		if page == 1 {
			channels = []map[string]any{
				{"id": "C001", "name": "general", "is_channel": true},
			}
			nextCursor = "page2"
		} else {
			channels = []map[string]any{
				{"id": "C002", "name": "random", "is_channel": true},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"channels": channels,
			"response_metadata": map[string]any{
				"next_cursor": nextCursor,
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	var pageCounts []int
	channels, err := c.GetChannels(context.Background(), []string{"public_channel"}, func(fetched int) {
		pageCounts = append(pageCounts, fetched)
	})
	require.NoError(t, err)
	assert.Len(t, channels, 2)
	assert.Equal(t, []int{1, 2}, pageCounts)
}

func TestGetChannelsDefaultTypes(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"channels": []map[string]any{},
			"response_metadata": map[string]any{
				"next_cursor": "",
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	// Pass empty types — should default to public_channel, private_channel
	channels, err := c.GetChannels(context.Background(), []string{})
	require.NoError(t, err)
	assert.Empty(t, channels)
}

func TestGetConversationHistoryError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "channel_not_found",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	resp, err := c.GetConversationHistory(context.Background(), HistoryOptions{ChannelID: "CBAD"})
	assert.Error(t, err)
	assert.Nil(t, resp)
}

func TestGetConversationRepliesError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.replies", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "thread_not_found",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	msgs, err := c.GetConversationReplies(context.Background(), "C001", "1700000001.000000")
	assert.Error(t, err)
	assert.Empty(t, msgs)
}

func TestHandleErrorNilError(t *testing.T) {
	c := &Client{rateLimiter: NewUnlimitedRateLimiter()}
	// Should not panic on nil error
	c.handleError(Tier2, nil)
}

func TestGetChannelReadCursor(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"channel": map[string]any{
				"id":        "C001",
				"name":      "general",
				"last_read": "1700000009.000100",
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	cursor, err := c.GetChannelReadCursor(context.Background(), "C001")
	require.NoError(t, err)
	assert.Equal(t, "1700000009.000100", cursor)
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

	c := newUnlimitedTestClient(t, mux)
	cursor, err := c.GetChannelReadCursor(context.Background(), "CBAD")
	assert.Error(t, err)
	assert.Empty(t, cursor)
	assert.Contains(t, err.Error(), "channel_not_found")
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
						"type":      "message",
						"ts":        "1700000001.000000",
						"reactions": []map[string]any{{"name": "thumbsup", "count": 1, "users": []string{"U001"}}},
					},
				},
			}
		} else {
			items = []map[string]any{
				{
					"type":    "message",
					"channel": "C002",
					"message": map[string]any{
						"type":      "message",
						"ts":        "1700000002.000000",
						"reactions": []map[string]any{{"name": "eyes", "count": 1, "users": []string{"U001"}}},
					},
				},
			}
		}

		json.NewEncoder(w).Encode(map[string]any{
			"ok":    true,
			"items": items,
			"paging": map[string]any{
				"count": 100,
				"total": 2,
				"page":  int(page),
				"pages": 2,
			},
		})
	})

	c := newUnlimitedTestClient(t, mux)
	items, err := c.ListUserReactions(context.Background(), "U001")
	require.NoError(t, err)
	require.Len(t, items, 2)
	assert.Equal(t, "C001", items[0].Channel)
	assert.Equal(t, "1700000001.000000", items[0].Message.Timestamp)
	require.Len(t, items[0].Reactions, 1)
	assert.Equal(t, "thumbsup", items[0].Reactions[0].Name)
	assert.Equal(t, "C002", items[1].Channel)
	assert.Equal(t, int32(2), callCount.Load())
}

func TestListUserReactionsError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/reactions.list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":    false,
			"error": "user_not_found",
		})
	})

	c := newUnlimitedTestClient(t, mux)
	items, err := c.ListUserReactions(context.Background(), "UBAD")
	assert.Error(t, err)
	assert.Nil(t, items)
	assert.Contains(t, err.Error(), "user_not_found")
}

// TestNewHTTPClientBounds pins the timeouts that keep a sleep-killed socket
// from stalling a sync cycle. The h2 assertion is the load-bearing one:
// slack.com negotiates HTTP/2, where ResponseHeaderTimeout does not apply, so
// a transport that silently failed to be h2-configured would leave a dead
// connection hanging until the OS TCP timeout (~24 min) all over again.
func TestNewHTTPClientBounds(t *testing.T) {
	c := newHTTPClient()
	assert.Equal(t, httpTimeout, c.Timeout, "whole-request ceiling")

	tr, ok := c.Transport.(*http.Transport)
	require.True(t, ok, "transport should be an *http.Transport")
	assert.Equal(t, responseHeaderTimeout, tr.ResponseHeaderTimeout, "HTTP/1.1 header wait")
	assert.True(t, tr.ForceAttemptHTTP2, "HTTP/2 must stay negotiable")
	require.NotNil(t, tr.HTTP2, "HTTP/2 keepalive must be configured")
	assert.Equal(t, h2ReadIdleTimeout, tr.HTTP2.SendPingTimeout, "HTTP/2 idle ping")
	assert.Equal(t, h2PingTimeout, tr.HTTP2.PingTimeout, "HTTP/2 ping deadline")
}

// TestAnsweredCalls_CountsWhatSlackAnswered pins the daemon's Slack progress
// signal: a success and an API error are answers, a request that died on the
// wire or broke off mid-body is not, and ResetAPIStats never moves the count
// back.
func TestAnsweredCalls_CountsWhatSlackAnswered(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "user_id": "U001", "team_id": "T001"})
	})
	mux.HandleFunc("/conversations.info", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "channel_not_found"})
	})
	mux.HandleFunc("/users.info", func(w http.ResponseWriter, _ *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			_ = conn.Close() // no response: the request fails on the wire
		}
	})
	mux.HandleFunc("/users.profile.get", func(w http.ResponseWriter, _ *http.Request) {
		// Headers and part of the body, then the connection drops: slack-go
		// returns the body read error unwrapped.
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", "100")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":tr`))
		w.(http.Flusher).Flush()
		if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
			_ = conn.Close()
		}
	})
	c := newUnlimitedTestClient(t, mux)

	_, err := c.AuthTest(context.Background())
	require.NoError(t, err)
	assert.Equal(t, uint64(1), c.AnsweredCalls(), "a success is an answer")
	c.ResetAPIStats()
	assert.Equal(t, uint64(1), c.AnsweredCalls(), "ResetAPIStats leaves the count alone")

	_, err = c.GetChannelReadCursor(context.Background(), "C001")
	require.Error(t, err)
	assert.Equal(t, uint64(2), c.AnsweredCalls(), "an API error is an answer")

	_, err = c.GetUserInfo(context.Background(), "U001")
	require.Error(t, err)
	assert.Equal(t, uint64(2), c.AnsweredCalls(), "a request that died on the wire is no answer")

	err = c.doRequest(context.Background(), 4, func() error {
		_, err := c.api.GetUserProfileContext(context.Background(), &goslack.GetUserProfileParameters{UserID: "U001"})
		return err
	})
	require.Error(t, err)
	assert.Equal(t, uint64(2), c.AnsweredCalls(), "a response cut off mid-body is no answer")
}

// TestIsSlackAnswer_ErrorKinds pins each answer kind slack-go returns — a
// value or a pointer type, so a wrong errors.As target would never match —
// also when wrapped, and the failures that are no answer.
func TestIsSlackAnswer_ErrorKinds(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"success", nil, true},
		{"API error", goslack.SlackErrorResponse{Err: "channel_not_found"}, true},
		{"429", &goslack.RateLimitedError{RetryAfter: time.Second}, true},
		{"status error", goslack.StatusCodeError{Code: 502, Status: "502 Bad Gateway"}, true},
		{"wrapped API error", fmt.Errorf("conversations.info: %w", goslack.SlackErrorResponse{Err: "x"}), true},
		{"wire error", &url.Error{Op: "Post", URL: "https://slack.com/api/x", Err: errors.New("timeout")}, false},
		{"body cut off", io.ErrUnexpectedEOF, false},
		{"cancelled", context.Canceled, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, isSlackAnswer(tc.err))
		})
	}
}

// TestCloseIdleConnections_ReachesEveryClient pins the wake handling's half
// in this package: every client shares one transport, and
// CloseIdleConnections drops its pooled connections, so the call after it
// dials afresh instead of reusing a socket a sleep may have killed.
func TestCloseIdleConnections_ReachesEveryClient(t *testing.T) {
	a, b := newHTTPClient(), newHTTPClient()
	assert.Same(t, a.Transport, b.Transport, "one pool for every Slack client")

	var dials atomic.Int32
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	srv.Config.ConnState = func(_ net.Conn, st http.ConnState) {
		if st == http.StateNew {
			dials.Add(1)
		}
	}
	srv.Start()
	t.Cleanup(srv.Close)
	t.Cleanup(CloseIdleConnections)

	get := func(c *http.Client) {
		t.Helper()
		resp, err := c.Get(srv.URL)
		require.NoError(t, err)
		_, _ = io.Copy(io.Discard, resp.Body)
		require.NoError(t, resp.Body.Close())
	}
	get(a)
	get(b)
	assert.Equal(t, int32(1), dials.Load(), "the second client reuses the pooled connection")

	CloseIdleConnections()
	get(a)
	assert.Equal(t, int32(2), dials.Load(), "after CloseIdleConnections the next call dials afresh")
}

func TestPostMessage_SendsTextAndThread(t *testing.T) {
	var form map[string]string
	mux := http.NewServeMux()
	mux.HandleFunc("/chat.postMessage", func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		form = map[string]string{"channel": r.FormValue("channel"), "text": r.FormValue("text"), "thread_ts": r.FormValue("thread_ts")}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "channel": "C1", "ts": "1700000000.000200"})
	})
	c := newUnlimitedTestClient(t, mux)
	ts, err := c.PostMessage(context.Background(), "C1", "hello *there*", "1700000000.000100")
	require.NoError(t, err)
	assert.Equal(t, "1700000000.000200", ts)
	assert.Equal(t, map[string]string{"channel": "C1", "text": "hello *there*", "thread_ts": "1700000000.000100"}, form)
}

func TestPostMessage_SurfacesSlackError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/chat.postMessage", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": "missing_scope"})
	})
	c := newUnlimitedTestClient(t, mux)
	_, err := c.PostMessage(context.Background(), "C1", "hi", "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "missing_scope")
}

func TestOpenDM_ReturnsTheIMChannel(t *testing.T) {
	var users string
	mux := http.NewServeMux()
	mux.HandleFunc("/conversations.open", func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		users = r.FormValue("users")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "channel": map[string]any{"id": "D42"}})
	})
	c := newUnlimitedTestClient(t, mux)
	id, err := c.OpenDM(context.Background(), "U7")
	require.NoError(t, err)
	assert.Equal(t, "D42", id)
	assert.Equal(t, "U7", users)
}

// searchMux answers search.messages with handler's body.
func searchMux(handler http.HandlerFunc) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", handler)
	return mux
}

func TestSearchMessages_DecodesFiles(t *testing.T) {
	var form url.Values
	var auth string
	c := newTestClient(t, searchMux(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		form, auth = r.PostForm, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"messages":{"matches":[{
			"ts":"1700000001.000100","user":"U1","text":"see <https://example.com/a>",
			"channel":{"id":"C1","name":"general"},"permalink":"https://acme.slack.com/archives/C1/p1",
			"subtype":"file_share","upload":true,
			"files":[{"id":"F1","name":"shot.png","mimetype":"image/png","size":4096,"mode":"hosted",
				"url_private":"https://files.slack.com/files-pri/T1-F1/shot.png",
				"url_private_download":"https://files.slack.com/files-pri/T1-F1/download/shot.png"}]}],
			"paging":{"count":100,"total":1,"page":1,"pages":1},"total":1}}`))
	}))

	res, err := c.SearchMessages(context.Background(), "after:2026-10-01", 1)
	require.NoError(t, err)
	require.Len(t, res.Messages, 1)
	m := res.Messages[0]
	assert.Equal(t, "1700000001.000100", m.Timestamp)
	assert.Equal(t, "C1", m.Channel.ID)
	assert.Equal(t, "see <https://example.com/a>", m.Text)
	assert.Equal(t, "file_share", m.Subtype)
	assert.True(t, m.Upload)
	require.Len(t, m.Files, 1)
	assert.Equal(t, "F1", m.Files[0].ID)
	assert.Equal(t, "image/png", m.Files[0].Mimetype)
	assert.Equal(t, "hosted", m.Files[0].Mode)
	assert.Equal(t, "https://files.slack.com/files-pri/T1-F1/download/shot.png", m.Files[0].URLPrivateDownload)
	assert.Equal(t, 1, res.Total)
	assert.Equal(t, 1, res.Pages)

	assert.Equal(t, "Bearer xoxp-test-token", auth)
	assert.Equal(t, "after:2026-10-01", form.Get("query"))
	assert.Equal(t, "timestamp", form.Get("sort"))
	assert.Equal(t, "asc", form.Get("sort_dir"))
	assert.Equal(t, "100", form.Get("count"))
	assert.Equal(t, "1", form.Get("page"))
}

func TestSearchMessages_RateLimitedRetries(t *testing.T) {
	var calls atomic.Int32
	c := newTestClient(t, searchMux(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"messages":{"matches":[{"ts":"1.0","text":"hi","channel":{"id":"C1"}}],
			"paging":{"page":1,"pages":1},"total":1}}`))
	}))

	res, err := c.SearchMessages(context.Background(), "q", 1)
	require.NoError(t, err)
	assert.EqualValues(t, 2, calls.Load(), "one retry after the 429")
	require.Len(t, res.Messages, 1)
	assert.Equal(t, "hi", res.Messages[0].Text)
	counts, retries := c.APIStats()
	assert.Equal(t, 2, counts[Tier2], "both requests counted")
	assert.Equal(t, 1, retries)
	assert.EqualValues(t, 2, c.AnsweredCalls())
}

func TestSearchMessages_SlackErrorMapped(t *testing.T) {
	c := newTestClient(t, searchMux(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":false,"error":"invalid_auth"}`))
	}))

	_, err := c.SearchMessages(context.Background(), "q", 1)
	var apiErr goslack.SlackErrorResponse
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, "invalid_auth", apiErr.Err)
}

// fileHosts serves https for the named hosts from local TLS servers: the
// client's download transport dials the server mapped to the request's host
// (an unmapped host fails to dial) and skips verification of the test cert.
func fileHosts(t *testing.T, c *Client, hosts map[string]*httptest.Server) {
	t.Helper()
	tr := transport.Clone()
	tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} // local test servers only
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, _, _ := net.SplitHostPort(addr)
		srv, ok := hosts[host]
		if !ok {
			return nil, fmt.Errorf("test: no server for %s", host)
		}
		var d net.Dialer
		return d.DialContext(ctx, network, srv.Listener.Addr().String())
	}
	tr.DialTLSContext = nil
	c.files.Transport = tr
	t.Cleanup(tr.CloseIdleConnections)
}

// fileServer records each request's Authorization header and answers with
// handler.
type fileServer struct {
	*httptest.Server
	mu    sync.Mutex
	auths []string
}

func newFileServer(t *testing.T, handler http.HandlerFunc) *fileServer {
	t.Helper()
	fs := &fileServer{}
	fs.Server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fs.mu.Lock()
		fs.auths = append(fs.auths, r.Header.Get("Authorization"))
		fs.mu.Unlock()
		handler(w, r)
	}))
	t.Cleanup(fs.Close)
	return fs
}

func (fs *fileServer) requests() []string {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	return append([]string(nil), fs.auths...)
}

func pngBytes(n int) []byte {
	b := bytes.Repeat([]byte{0}, n)
	copy(b, "\x89PNG\r\n\x1a\n")
	return b
}

func TestDownloadFile_SendsBearerOnlyToSlack(t *testing.T) {
	other := newFileServer(t, func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(pngBytes(100)) })
	slackFiles := newFileServer(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://evil.example/steal", http.StatusFound)
	})
	c := NewClientWithAPIURLUnlimited("xoxp-secret", "http://127.0.0.1:0/")
	fileHosts(t, c, map[string]*httptest.Server{"files.slack.com": slackFiles.Server, "evil.example": other.Server})

	_, _, err := c.DownloadFile(context.Background(), "https://files.slack.com/files-pri/T1-F1/shot.png", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused)
	assert.Equal(t, []string{"Bearer xoxp-secret"}, slackFiles.requests(), "the Slack host gets the token")
	assert.Empty(t, other.requests(), "the redirect target is never contacted, so it never sees the token")
}

func TestDownloadFile_HostAllowlist(t *testing.T) {
	body := pngBytes(3000)
	acme := newFileServer(t, func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(body) })
	slackFiles := newFileServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/hop":
			http.Redirect(w, r, "https://acme.slack.com/files/x.png", http.StatusFound)
			return
		case "/port":
			http.Redirect(w, r, "https://files.slack.com:8443/x.png", http.StatusFound)
			return
		case "/loopback":
			http.Redirect(w, r, "http://127.0.0.1/x.png", http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(body)
	})
	other := newFileServer(t, func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(body) })
	c := NewClientWithAPIURLUnlimited("xoxp-secret", "http://127.0.0.1:0/")
	c.SetTeamDomain("acme")
	fileHosts(t, c, map[string]*httptest.Server{
		"files.slack.com": slackFiles.Server, "acme.slack.com": acme.Server,
		"other.slack.com": other.Server, "evil.example": other.Server,
	})

	for _, u := range []string{"https://files.slack.com/files-pri/T1-F1/a.png", "https://acme.slack.com/files/a.png"} {
		rc, typ, err := c.DownloadFile(context.Background(), u, 1<<20)
		require.NoError(t, err, u)
		got, err := io.ReadAll(rc)
		require.NoError(t, err)
		require.NoError(t, rc.Close())
		assert.Equal(t, body, got, u)
		if strings.HasPrefix(u, "https://files.") {
			assert.Equal(t, "image/png", typ)
		}
	}
	assert.Len(t, acme.requests(), 1)

	for _, u := range []string{
		"https://other.slack.com/files/a.png", "https://evil.example/a.png", "http://files.slack.com/files-pri/a.png",
		"https://files.slack.com:8443/a.png", "https://user@files.slack.com/a.png", "ftp://files.slack.com/a.png", "::bad", // leak-check:allow
		"https://files.slack.com./a.png", "https://files.slack.com.evil.example/a.png", "https://xn--files-slack.com/a.png",
	} {
		_, _, err := c.DownloadFile(context.Background(), u, 1<<20)
		require.ErrorIs(t, err, ErrFileURLRefused, u)
	}
	assert.Empty(t, other.requests(), "a refused URL is refused before any request")

	before := len(acme.requests())
	_, _, err := c.DownloadFile(context.Background(), "https://files.slack.com/hop", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused, "a redirect files.slack.com → acme.slack.com breaks the same-host rule")
	assert.Len(t, acme.requests(), before, "the redirect is not followed")
	served := len(slackFiles.requests())
	_, _, err = c.DownloadFile(context.Background(), "https://files.slack.com/port", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused, "a redirect to another port is off the allowlist")
	assert.Len(t, slackFiles.requests(), served+1, "only the first request was made")
	_, _, err = c.DownloadFile(context.Background(), "https://files.slack.com/loopback", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused, "a redirect to a plain-http loopback address is refused")
	assert.Len(t, slackFiles.requests(), served+2, "the loopback target is never contacted")

	// An account without a team domain downloads from files.slack.com only.
	bare := NewClientWithAPIURLUnlimited("xoxp-secret", "http://127.0.0.1:0/")
	fileHosts(t, bare, map[string]*httptest.Server{"files.slack.com": slackFiles.Server, "acme.slack.com": acme.Server})
	_, _, err = bare.DownloadFile(context.Background(), "https://acme.slack.com/files/a.png", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused)
	bare.SetTeamDomain("evil.com/x")
	_, _, err = bare.DownloadFile(context.Background(), "https://evil.com/x.slack.com/a.png", 1<<20)
	require.ErrorIs(t, err, ErrFileURLRefused, "a domain that is no DNS label allows nothing")
}

func TestDownloadFile_SharesTier4Gate(t *testing.T) {
	srv := newFileServer(t, func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(pngBytes(3000)) })
	c := NewClientWithAPIURL("xoxp-secret", "http://127.0.0.1:0/")
	fileHosts(t, c, map[string]*httptest.Server{"files.slack.com": srv.Server})

	// The limiter's gate full (three API calls in flight): the download waits
	// for it like any other Slack call and never reaches the host.
	for range cap(c.rateLimiter.gate) {
		c.rateLimiter.gate <- struct{}{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	_, _, err := c.DownloadFile(ctx, "https://files.slack.com/a.png", 1<<20)
	cancel()
	require.ErrorIs(t, err, context.DeadlineExceeded)
	assert.Empty(t, srv.requests())
	for range cap(c.rateLimiter.gate) {
		<-c.rateLimiter.gate
	}

	rc, _, err := c.DownloadFile(context.Background(), "https://files.slack.com/a.png", 1<<20)
	require.NoError(t, err)
	_ = rc.Close()
	counts, _ := c.APIStats()
	assert.Equal(t, 1, counts[Tier4], "a download counts as a Tier 4 call")
}

func TestDownloadFile_TooLargeAndGone(t *testing.T) {
	srv := newFileServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/gone":
			w.WriteHeader(http.StatusNotFound)
		case "/big":
			w.Header().Set("Content-Length", "5000") // refused at the headers
			_, _ = w.Write(pngBytes(5000))
		case "/chunked":
			w.(http.Flusher).Flush() // no Content-Length: the cap applies while reading
			_, _ = w.Write(pngBytes(5000))
		default:
			_, _ = w.Write(pngBytes(5000)) // past the response buffer: chunked
		}
	})
	c := NewClientWithAPIURLUnlimited("xoxp-secret", "http://127.0.0.1:0/")
	fileHosts(t, c, map[string]*httptest.Server{"files.slack.com": srv.Server})

	_, _, err := c.DownloadFile(context.Background(), "https://files.slack.com/big", 4000)
	require.ErrorIs(t, err, ErrTooLarge)
	rc, _, err := c.DownloadFile(context.Background(), "https://files.slack.com/chunked", 4000)
	require.NoError(t, err)
	_, err = io.ReadAll(rc)
	require.ErrorIs(t, err, ErrTooLarge)
	_ = rc.Close()
	_, _, err = c.DownloadFile(context.Background(), "https://files.slack.com/gone", 4000)
	require.ErrorIs(t, err, ErrFileGone)
}

// chunkReader returns n bytes per Read, forever.
type chunkReader struct{ n int }

func (r chunkReader) Read(p []byte) (int, error) { return min(r.n, len(p)), nil }

// limitedBody never reports a negative count: past the cap it returns the
// bytes up to the limit with ErrTooLarge, then 0 and ErrTooLarge on every
// later Read.
func TestLimitedBody_LatchesTooLarge(t *testing.T) {
	b := &limitedBody{rc: io.NopCloser(chunkReader{n: 100}), limit: 250}
	buf := make([]byte, 100)
	var total int
	for i := 0; i < 6; i++ {
		n, err := b.Read(buf)
		require.GreaterOrEqual(t, n, 0, "read %d", i)
		total += n
		if i < 2 {
			require.NoError(t, err)
			continue
		}
		require.ErrorIs(t, err, ErrTooLarge, "read %d", i)
		if i > 2 {
			assert.Zero(t, n, "read %d after the cap", i)
		}
	}
	assert.Equal(t, 250, total, "exactly the limit is delivered")
}
