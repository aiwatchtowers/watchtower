package chat

import (
	_ "embed"
	"strings"
)

// questionsContract is shared with the Swift side: the embedded chats append
// the same text (ChatQuestionsContract.promptBlock) and a Swift test pins both
// it and the parser to this file (dual path, pinned from both sides).
//
//go:embed questions_contract.md
var questionsContract string

// QuestionsContract teaches the model the question card (spec 2026-10-02):
// a ```watchtower-question JSON block the Desktop renders as a card whose
// answer comes back as the owner's next message.
func QuestionsContract() string {
	return strings.TrimSpace(questionsContract)
}
