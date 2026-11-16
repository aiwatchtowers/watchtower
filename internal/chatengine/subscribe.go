package chatengine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"slices"
	"sync"
	"time"

	"watchtower/internal/chatstore"
)

// subscriptionQueue bounds the events waiting for a subscriber (spec §5.1).
// A subscriber that falls behind gets one `resync` and then a fresh
// snapshot, never a gap: the end of a turn is always seen.
const subscriptionQueue = 256

// The event types.
const (
	EventSnapshot           = "snapshot"
	EventMessageUpsert      = "message_upsert"
	EventConversationUpdate = "conversation_update"
	EventListUpdate         = "list_update"
	EventResync             = "resync"
)

// Target is what a subscription follows: the list, or one conversation's
// feed (its latest page, or the page before BeforeMessageID).
type Target struct {
	List            bool
	Conversation    int64
	BeforeMessageID int64
}

// Event is one subscription event. A conversation's snapshot with no
// Snapshot means the conversation is gone; a list snapshot carries List.
type Event struct {
	Type               string            `json:"event"` // snapshot|message_upsert|conversation_update|list_update|resync
	Conversation       int64             `json:"conversation_id,omitempty"`
	Snapshot           *Feed             `json:"snapshot,omitempty"`
	Message            *FeedMessage      `json:"message,omitempty"`
	ConversationUpdate *FeedConversation `json:"conversation,omitempty"`
	List               *List             `json:"list,omitempty"`
}

// Subscription is a stream of events: first a snapshot, then the changes,
// coalesced to one batch per FeedCoalesce (a conversation) or ListCoalesce
// (the list). Events is closed once the subscription ended.
type Subscription struct {
	Events <-chan Event

	e    *Engine
	t    Target
	c    Client
	out  chan Event
	kick chan struct{}
	done chan struct{} // closed by Close
	once sync.Once

	// Owned by run: what the subscriber last got.
	gone     bool
	msgs     []int64
	msgJSON  map[int64][]byte
	convJSON []byte
	restJSON []byte
	listJSON []byte
}

// Subscribe starts a subscription for t. c is the subscriber (a later task
// filters parts by it). A closed engine's subscription has no events.
func (e *Engine) Subscribe(t Target, c Client) *Subscription {
	out := make(chan Event, subscriptionQueue)
	s := &Subscription{Events: out, e: e, t: t, c: c, out: out, kick: make(chan struct{}, 1), done: make(chan struct{})}
	e.mu.Lock()
	closed := e.closed
	e.mu.Unlock()
	if closed {
		close(s.done)
		close(out)
		return s
	}
	e.subMu.Lock()
	e.subs[s] = struct{}{}
	e.subMu.Unlock()
	go s.run()
	return s
}

// Close ends the subscription; Events is closed once its goroutine stopped.
func (s *Subscription) Close() {
	s.once.Do(func() {
		select {
		case <-s.done: // a closed engine's subscription
			return
		default:
		}
		s.e.subMu.Lock()
		delete(s.e.subs, s)
		s.e.subMu.Unlock()
		close(s.done)
	})
}

// notify wakes every subscription that follows conv (and the list's).
func (e *Engine) notify(conv int64) {
	e.subMu.Lock()
	defer e.subMu.Unlock()
	for s := range e.subs {
		if s.t.List || s.t.Conversation == conv {
			select {
			case s.kick <- struct{}{}:
			default:
			}
		}
	}
}

func (s *Subscription) window() time.Duration {
	if s.t.List {
		return ListCoalesce
	}
	return FeedCoalesce
}

// run sends the snapshot, then one batch of changes per window after a
// change (the window's first change starts its timer, so at most one batch
// per window); a full queue turns into resync + snapshot.
func (s *Subscription) run() {
	defer close(s.out)
	if !s.snapshot() {
		return
	}
	var timer *time.Timer
	var fire <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		select {
		case <-s.done:
			return
		case <-s.kick:
			if timer == nil {
				timer = time.NewTimer(s.window())
				fire = timer.C
			}
		case <-fire:
			timer, fire = nil, nil
			if !s.update() && !s.resync() {
				return
			}
		}
	}
}

// send queues ev without blocking; false when the queue is full.
func (s *Subscription) send(ev Event) bool {
	select {
	case s.out <- ev:
		return true
	default:
		return false
	}
}

// sendWait queues ev, waiting for room; false once the subscription ended.
func (s *Subscription) sendWait(ev Event) bool {
	select {
	case s.out <- ev:
		return true
	case <-s.done:
		return false
	}
}

// resync tells a subscriber that fell behind to start over, then sends a
// snapshot read after it made room, so it holds everything up to then.
func (s *Subscription) resync() bool {
	if !s.sendWait(Event{Type: EventResync, Conversation: s.t.Conversation}) {
		return false
	}
	return s.snapshot()
}

// snapshot reads the target anew and sends it whole, waiting for room.
func (s *Subscription) snapshot() bool {
	if s.t.List {
		l, err := s.e.List(context.Background())
		if err != nil {
			s.logFailure(err)
			l = List{Conversations: []ListConversation{}, Projects: []ListProject{}, Models: []ChatModel{}}
		}
		s.listJSON, _ = json.Marshal(l)
		return s.sendWait(Event{Type: EventSnapshot, List: &l})
	}
	f, err := s.e.Feed(context.Background(), s.t.Conversation, s.t.BeforeMessageID)
	ev := Event{Type: EventSnapshot, Conversation: s.t.Conversation}
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
		s.gone = true
	case err != nil:
		s.logFailure(err)
		s.gone = false
		s.remember(Feed{Messages: []FeedMessage{}})
		ev.Snapshot = &Feed{Messages: []FeedMessage{}}
	default:
		s.gone = false
		s.remember(f)
		ev.Snapshot = &f
	}
	return s.sendWait(ev)
}

// update sends what changed since the last batch; false when the queue
// overflowed (the caller resyncs).
func (s *Subscription) update() bool {
	if s.t.List {
		l, err := s.e.List(context.Background())
		if err != nil {
			s.logFailure(err)
			return true
		}
		b, _ := json.Marshal(l)
		if bytes.Equal(b, s.listJSON) {
			return true
		}
		s.listJSON = b
		return s.send(Event{Type: EventListUpdate, List: &l})
	}
	f, err := s.e.Feed(context.Background(), s.t.Conversation, s.t.BeforeMessageID)
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
		if s.gone {
			return true
		}
		s.gone = true
		return s.send(Event{Type: EventSnapshot, Conversation: s.t.Conversation})
	case err != nil:
		s.logFailure(err)
		return true
	}
	ids := make([]int64, len(f.Messages))
	for i, m := range f.Messages {
		ids[i] = m.ID
	}
	rest, _ := json.Marshal(feedRest(f))
	if s.gone || len(ids) < len(s.msgs) || !slices.Equal(ids[:len(s.msgs)], s.msgs) || !bytes.Equal(rest, s.restJSON) {
		// A branch switch, a deletion, new artifacts or actions: whole.
		s.gone = false
		s.remember(f)
		return s.send(Event{Type: EventSnapshot, Conversation: s.t.Conversation, Snapshot: &f})
	}
	var events []Event
	if conv, _ := json.Marshal(f.Conversation); !bytes.Equal(conv, s.convJSON) {
		c := f.Conversation
		events = append(events, Event{Type: EventConversationUpdate, Conversation: s.t.Conversation, ConversationUpdate: &c})
	}
	for i := range f.Messages {
		m := f.Messages[i]
		if b, _ := json.Marshal(m); !bytes.Equal(b, s.msgJSON[m.ID]) {
			events = append(events, Event{Type: EventMessageUpsert, Conversation: s.t.Conversation, Message: &m})
		}
	}
	s.remember(f)
	for _, ev := range events {
		if !s.send(ev) {
			return false
		}
	}
	return true
}

// feedRest is what a feed holds beside its messages and meta: a change of
// it is sent as a snapshot.
func feedRest(f Feed) any {
	return struct {
		HasMore   bool
		Artifacts []FeedArtifact
		Actions   []FeedAction
	}{f.HasMore, f.Artifacts, f.Actions}
}

// remember keeps f as what the subscriber has.
func (s *Subscription) remember(f Feed) {
	s.msgs = s.msgs[:0]
	s.msgJSON = make(map[int64][]byte, len(f.Messages))
	for _, m := range f.Messages {
		s.msgs = append(s.msgs, m.ID)
		s.msgJSON[m.ID], _ = json.Marshal(m)
	}
	s.convJSON, _ = json.Marshal(f.Conversation)
	s.restJSON, _ = json.Marshal(feedRest(f))
}

func (s *Subscription) logFailure(err error) {
	select {
	case <-s.done:
		return
	default:
	}
	log.Printf("chatengine: a subscription's read of chat %d failed (%s)", s.t.Conversation, errClass(err))
}
