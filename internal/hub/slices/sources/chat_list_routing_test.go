package sources

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/chatengine"
	"watchtower/internal/providerrouting"
)

// testRoutingCatalog is a catalog as ReadRoutingCatalog returns it.
func testRoutingCatalog() *chatengine.RoutingCatalog {
	return &chatengine.RoutingCatalog{
		Providers: []chatengine.RoutingProvider{
			{ID: "claude", DisplayName: "Claude", ReservePeer: "codex", Images: true, PDFs: true, ReadFolder: true, ClaudeAI: true},
			{ID: "codex", DisplayName: "Codex", ReservePeer: "claude", Images: true, ReadFolder: true},
		},
		Status: &providerrouting.Output{Revision: "r1", PreferredProvider: "claude", Enabled: true,
			Providers: []providerrouting.Status{{Provider: "claude", State: "quota_wait"}}},
	}
}

// TestChatList_CarriesRoutingCatalog: with the option set, the chat_list
// record carries routing.providers and routing.status, and a full list
// still fits MaxChatFeedBytes.
func TestChatList_CarriesRoutingCatalog(t *testing.T) {
	d := openDB(t)
	s := chatSeed{t, d}
	for i := range MaxChatListConversations {
		s.conversation(strings.Repeat("t", MaxChatLastLine+80), float64(1_700_000_000+i), "")
	}
	src := ChatList(chatReaderOf(d, nil), ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil },
		Routing: func(context.Context) *chatengine.RoutingCatalog { return testRoutingCatalog() }})
	items, err := src.Items(context.Background())
	if err != nil || len(items) != 1 {
		t.Fatalf("items %d, err %v", len(items), err)
	}
	if len(items[0].Payload) > MaxChatFeedBytes {
		t.Fatalf("payload %d bytes, over %d", len(items[0].Payload), MaxChatFeedBytes)
	}
	got := decode(t, items[0].Payload)
	routing, ok := got["routing"].(map[string]any)
	if !ok {
		t.Fatalf("no routing in %v", got)
	}
	providers, _ := routing["providers"].([]any)
	if len(providers) != 2 || providers[0].(map[string]any)["reserve_peer"] != "codex" {
		t.Errorf("providers = %v", providers)
	}
	status, _ := routing["status"].(map[string]any)
	if status["preferred_provider"] != "claude" || status["application"] != nil {
		t.Errorf("status = %v", status)
	}
}

// TestChatList_RoutingNilOmitted: without the option the record has no
// routing key, as an older daemon's.
func TestChatList_RoutingNilOmitted(t *testing.T) {
	d := openDB(t)
	got := chatRecords(t, ChatList(chatReaderOf(d, nil), ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil }}))[ChatListID]
	if _, ok := got["routing"]; ok {
		t.Fatalf("routing key present: %v", got)
	}
}

// TestChatList_RoutingStatusReadOnEveryBuild: each build reads the catalog
// again, so the status is never older than the record.
func TestChatList_RoutingStatusReadOnEveryBuild(t *testing.T) {
	d := openDB(t)
	calls := 0
	src := ChatList(chatReaderOf(d, nil), ChatListOptions{Grant: chatGranted, Models: func() []ChatModel { return nil },
		Routing: func(context.Context) *chatengine.RoutingCatalog { calls++; return testRoutingCatalog() }})
	chatRecords(t, src)
	chatRecords(t, src)
	if calls != 2 {
		t.Fatalf("read %d times over two builds", calls)
	}
}
