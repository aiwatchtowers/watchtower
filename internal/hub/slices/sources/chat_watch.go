package sources

import (
	"slices"
	"sync"
	"time"
)

// The chat requests' lengths (iPhone chat spec §4.5): an `open`
// chat_feed_request watches the feed for 5 minutes (the phone repeats it
// every 60 s while the screen is open), a `prefetch` holds the record for
// 2 minutes, and a chat_page or chat_search record lives 5 minutes after its
// request. A watch's until is the request's time plus its length.
const (
	ChatOpenWatch    = 5 * time.Minute
	ChatPrefetchHold = 2 * time.Minute
	ChatRequestHold  = 5 * time.Minute
)

// The chat_feed_request purposes; a missing purpose reads as open.
const (
	ChatPurposeOpen     = "open"
	ChatPurposePrefetch = "prefetch"
)

// ChatWatches is the in-memory registry of what the phone asked of the AI
// chat (iPhone chat spec §4.5–§4.7): the watched feeds (chat_feed_request),
// the requested pages (chat_page) and searches (chat_search). The handlers
// write it, the chat sources publish only what it holds, and the chat_answer
// push asks Open whether the phone is looking. Nothing in it is written to
// disk; with no phone holding the chat grant the sources drop it all.
type ChatWatches struct {
	// Pages and Searches are the chat_page and chat_search requests.
	Pages    *ChatRequests[ChatPageKey]
	Searches *ChatRequests[string]

	mu    sync.Mutex
	feeds map[int64]feedWatch
}

type feedWatch struct {
	until time.Time
	// opened is when the newest open request was made (zero: none).
	opened time.Time
}

// ChatPageKey is one requested page: the conversation and the message the
// page ends before.
type ChatPageKey struct {
	Conversation, Before int64
}

// NewChatWatches is an empty registry.
func NewChatWatches() *ChatWatches {
	return &ChatWatches{Pages: NewChatRequests[ChatPageKey](), Searches: NewChatRequests[string](), feeds: map[int64]feedWatch{}}
}

// Watch opens or extends the feed watch of conversation conv until until; a
// repeat never shortens a watch. purpose is ChatPurposePrefetch or open (any
// other value, the empty one included, is open): only an open request makes
// Open true, its time taken as until − ChatOpenWatch.
func (w *ChatWatches) Watch(conv int64, purpose string, until time.Time) {
	w.mu.Lock()
	defer w.mu.Unlock()
	cur := w.feeds[conv]
	if until.After(cur.until) {
		cur.until = until
	}
	if purpose != ChatPurposePrefetch {
		if at := until.Add(-ChatOpenWatch); at.After(cur.opened) {
			cur.opened = at
		}
	}
	w.feeds[conv] = cur
}

// Open says whether an open request for conv was made at or after since (a
// prefetch never counts): the phone is looking at that chat.
func (w *ChatWatches) Open(conv int64, since time.Time) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	cur, ok := w.feeds[conv]
	return ok && !cur.opened.IsZero() && !cur.opened.Before(since)
}

// ActiveFeeds is every conversation whose feed watch is open at now, in id
// order (the hub's chat timer notices a watch ending by it).
func (w *ChatWatches) ActiveFeeds(now time.Time) []int64 { return w.activeFeeds(now) }

// activeFeeds is every conversation whose feed watch is open at now, in id
// order; expired watches are dropped.
func (w *ChatWatches) activeFeeds(now time.Time) []int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out []int64
	for conv, f := range w.feeds {
		if !f.until.After(now) {
			delete(w.feeds, conv)
			continue
		}
		out = append(out, conv)
	}
	slices.Sort(out)
	return out
}

// DropAll forgets every watch, page and search (no phone holds the chat
// grant any more).
func (w *ChatWatches) DropAll() {
	w.mu.Lock()
	clear(w.feeds)
	w.mu.Unlock()
	w.Pages.DropAll()
	w.Searches.DropAll()
}

// ChatRequests is one kind of one-shot request (a page, a search): each key
// is held until its until. Every request of a key counts (Gen): a repeat
// within the hold asks for the record again, so its source builds it anew
// rather than serve the copy of the first request.
type ChatRequests[K comparable] struct {
	mu    sync.Mutex
	until map[K]time.Time
	gen   map[K]uint64
}

// NewChatRequests is an empty request set.
func NewChatRequests[K comparable]() *ChatRequests[K] {
	return &ChatRequests[K]{until: map[K]time.Time{}, gen: map[K]uint64{}}
}

// Request holds k until until; a repeat never shortens it, and moves k's Gen
// on.
func (r *ChatRequests[K]) Request(k K, until time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cur, ok := r.until[k]; !ok || until.After(cur) {
		r.until[k] = until
	}
	r.gen[k]++
}

// Gen counts k's requests while it is held (0 = none).
func (r *ChatRequests[K]) Gen(k K) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.gen[k]
}

// Active is every key still held at now; expired ones are dropped.
func (r *ChatRequests[K]) Active(now time.Time) []K {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]K, 0, len(r.until))
	for k, until := range r.until {
		if !until.After(now) {
			delete(r.until, k)
			delete(r.gen, k)
			continue
		}
		out = append(out, k)
	}
	return out
}

// DropAll forgets every request.
func (r *ChatRequests[K]) DropAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	clear(r.until)
	clear(r.gen)
}
