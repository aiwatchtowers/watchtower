package chatengine

import "watchtower/internal/chatstore"

// The composer's additions to a send (spec §5.2 `compose`); the turn store
// composes them into the stored owner text.
type (
	Mention = chatstore.Mention
	Quote   = chatstore.Quote
	Compose = chatstore.Compose
)

// MaxScreenContextBytes bounds chat_turn's screen_context: the help popup's
// current-screen block, prefixed to the provider text only, never stored.
const MaxScreenContextBytes = 8 << 10

// ComposeOwnerText is the stored owner text of a send with c: the quote
// batch (ChatQuoteReply.compose) and the skill and REFERENCED lines
// (ChatTurnComposer.compose); testdata/compose_cases.json pins it to Swift.
func ComposeOwnerText(text string, c Compose) string { return chatstore.ComposeOwnerText(text, c) }
