package chatstore

import (
	"watchtower/internal/ideas"
	"watchtower/internal/instructions"
)

// Remember outcomes beyond db.RememberOutcome's (added, already_present,
// too_long): the parse found the prefix
// with nothing after it, or the line is not the owner's own words in a Live
// Slack conversation (LIVE-01), as `instructions remember` reports them.
const (
	RememberEmpty        = "empty"
	RememberNotOwnerText = "not_owner_text"
)

// runPrefixes is the Mac's onOwnerMessageStored for a new owner row
// (RememberCenter + ChatKnowledgeCenter, main chat: knowledge saves): a
// remember prefix runs the code `instructions remember` runs, a knowledge
// prefix writes a chat-born idea. In-process, after the start commit; a
// failure never undoes the turn, it lands in st.PrefixErr.
func (s *Store) runPrefixes(st *Started, text string) {
	if line, ok := instructions.ParseRemember(text); ok {
		st.RememberOutcome, st.PrefixErr = s.remember(line, st.ConversationID, st.UserMessageID)
	}
	if kind, body, ok := ideas.ParseKnowledgePrefix(text); ok && body != "" {
		id, err := s.db.CreateIdeaFromChat(kind, body, st.ConversationID, st.UserMessageID)
		st.IdeaID = id
		if st.PrefixErr == nil {
			st.PrefixErr = err
		}
	}
}

func (s *Store) remember(line string, conv, messageID int64) (string, error) {
	if line == "" {
		return RememberEmpty, nil
	}
	own, err := s.db.LiveSlackOwnerLineOK(conv, messageID, line)
	if err != nil {
		return "", err
	}
	if !own {
		return RememberNotOwnerText, nil
	}
	_, outcome, err := s.db.RememberChatLine(line, conv, messageID, s.now(), instructions.MaxRunes)
	if err != nil {
		return "", err
	}
	return string(outcome), nil
}
