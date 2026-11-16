package sources

import (
	"context"
	"fmt"
	"log"

	"watchtower/internal/chatengine"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// The chat_list caps (iPhone chat spec §4.6).
const (
	MaxChatListConversations = chatengine.MaxListConversations
	MaxChatLastLine          = chatengine.MaxLastLine
	// chatListReadFailed is the chat_list error when the read failed
	// ("Couldn't load chats" on the phone, mockup 1h).
	chatListReadFailed = "read_failed"
)

// The chat_list row states, by precedence (ChatPanelRowState).
const (
	ChatStateWaiting   = chatengine.StateWaiting
	ChatStateAnswering = chatengine.StateAnswering
	ChatStateUnread    = chatengine.StateUnread
	ChatStateRead      = chatengine.StateRead
)

// ChatModel is one model the phone's composer offers (chat_list models[]).
type ChatModel = chatengine.ChatModel

// RegistryChatModels is the provider catalog as the composer needs it
// (chatengine.RegistryChatModels).
func RegistryChatModels() []ChatModel { return chatengine.RegistryChatModels() }

// ChatGrant says whether a linked phone holds the chat grant
// (state.Store.AnyChatPhone): every chat source publishes only then.
type ChatGrant func() (bool, error)

// ChatListOptions wires the chat_list source. Grant is required; Models nil
// is RegistryChatModels.
type ChatListOptions struct {
	Grant  ChatGrant
	Models func() []ChatModel
}

// ChatListSource is the `chat_list` slice, one record `chat_list-main`: the
// main chat's conversations (up to 200, not archived; titles and project
// names clipped at 200 characters, within MaxChatFeedBytes), its projects
// and the composer's models (iPhone chat spec §4.6), read from the daemon's
// chat engine. It is rebuilt on every change the engine reports (OnChange)
// or the agent_actions table sees, not urgent, and published only while a phone holds
// the chat grant. A failed read publishes the list with `error` and nothing
// else, so the phone shows "Couldn't load chats" and Retry.
type ChatListSource struct {
	e ChatReader
	o ChatListOptions
}

// ChatListID is the chat_list record's id.
const ChatListID = "main"

// ChatList builds the chat_list source over the engine e (nil = chat off:
// nothing is published).
func ChatList(e ChatReader, o ChatListOptions) *ChatListSource {
	if o.Models == nil {
		o.Models = RegistryChatModels
	}
	return &ChatListSource{e: e, o: o}
}

// Kind is "chat_list".
func (s *ChatListSource) Kind() hubslices.Kind { return hubslices.KindChatList }

// Items is the one chat_list record, or none without a chat phone.
func (s *ChatListSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if s.e == nil {
		return nil, nil
	}
	if ok, err := s.o.Grant(); err != nil || !ok {
		return nil, err
	}
	payload, err := s.e.List(ctx)
	payload.Models = s.o.Models()
	if payload.Models == nil {
		payload.Models = []ChatModel{}
	}
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		log.Printf("hub slices: reading the chat list failed (%s)", errClass(err))
		code := chatListReadFailed
		payload = chatengine.List{Conversations: []chatengine.ListConversation{}, Projects: []chatengine.ListProject{},
			Models: []ChatModel{}, Error: &code}
	}
	b, err := encodeChatList(payload)
	if err != nil {
		return nil, fmt.Errorf("hub slices: encoding the chat list: %w", err)
	}
	return []hubslices.Item{{ID: ChatListID, Payload: b}}, nil
}

// encodeChatList encodes p within MaxChatFeedBytes, always: titles and
// names are already clipped at 200 and last lines at 120, so 200 rows fit;
// should they ever not, the oldest conversations (the list's tail) go.
func encodeChatList(p chatengine.List) ([]byte, error) {
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes || len(p.Conversations) == 0 {
			return b, err
		}
		p.Conversations = p.Conversations[:len(p.Conversations)-1]
	}
}
