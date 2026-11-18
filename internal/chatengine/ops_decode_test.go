package chatengine

import (
	"errors"
	"testing"

	"watchtower/internal/chatstore"
)

// TestDecodeTurn_ReadsEveryFieldAndChecksTheShape: chat_turn's one decoder
// (chat.sock and the relay, final review I2) reads every field and refuses a
// turn the store would refuse for its shape before the engine runs it.
func TestDecodeTurn_ReadsEveryFieldAndChecksTheShape(t *testing.T) {
	req, err := DecodeTurn([]byte(`{"conversation_id": 7, "mode": "edit", "message_id": 3, "text": "hi",
		"attachment_ids": [4], "routing": {"mode": "pinned", "provider": "claude", "model": "opus"},
		"client_key": "K", "compose": {"skill": "triage", "mentions": [], "quotes": []},
		"screen_context": "<screen/>", "artifact_comment_ids": [5, 6], "unknown": true}`))
	if err != nil {
		t.Fatal(err)
	}
	if req.ConversationID != 7 || req.Mode != chatstore.ModeEdit || req.MessageID != 3 || req.Text != "hi" ||
		len(req.AttachmentIDs) != 1 || req.Routing == nil || req.Routing.Provider != "claude" || req.Routing.Model != "opus" ||
		req.ClientKey != "K" || req.StartRequest.ClientKey != "K" || req.Compose == nil || req.Compose.Skill != "triage" ||
		req.ScreenContext != "<screen/>" || len(req.ArtifactCommentIDs) != 2 {
		t.Fatalf("decoded %+v", req)
	}
	for name, params := range map[string]string{
		"not json":       `[`,
		"no id":          `{"mode": "send", "text": "x"}`,
		"unknown mode":   `{"conversation_id": 7, "mode": "shout", "text": "x"}`,
		"bad routing":    `{"conversation_id": 7, "mode": "send", "routing": {"mode": "pinned"}}`,
		"bad compose":    `{"conversation_id": 7, "mode": "send", "compose": {"mentions": [{"kind": "planet", "id": "x"}]}}`,
		"key not a text": `{"conversation_id": 7, "mode": "send", "client_key": 7}`,
	} {
		if _, err := DecodeTurn([]byte(params)); !errors.Is(err, errBadParams) || ErrorCode(err) != "invalid" {
			t.Errorf("%s: %v", name, err)
		}
	}
}
