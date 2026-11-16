package sources

import (
	"bytes"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// The chat_feed, chat_page and chat_search caps (iPhone chat spec §4.6).
const (
	MaxChatFeedBytes     = 600_000
	MaxChatFeedMessages  = chatengine.PageSize
	MaxChatMessageText   = chatengine.MaxMessageText
	MaxChatSearchHits    = chatengine.MaxSearchHits
	MaxChatSearchSnippet = chatengine.MaxSearchSnippet
)

// ChatReader is the daemon's chat engine as the chat sources read it
// (*chatengine.Engine): a feed with the engine's live turn over the last
// flush, a page, the list and the search. Every part carries its payload
// and its fallback (the relay's phone is a nil Client: all kinds, D21).
type ChatReader interface {
	Feed(ctx context.Context, conv, beforeMessageID int64) (chatengine.Feed, error)
	List(ctx context.Context) (chatengine.List, error)
	Search(ctx context.Context, q string) (chatengine.SearchResult, error)
}

// ChatFeedOptions wires the chat_feed, chat_page and chat_search sources.
// Watches and Grant are required; Now nil is time.Now and must be the clock
// the handlers stamp the requests with.
type ChatFeedOptions struct {
	Watches *ChatWatches
	Grant   ChatGrant
	Now     func() time.Time
}

func (o *ChatFeedOptions) fill() {
	if o.Now == nil {
		o.Now = time.Now
	}
}

// granted is the chat sources' gate: without a phone holding the chat
// grant every watch, page and search is dropped (the publisher deletes
// their records), so a phone granted later never sees an old request.
func (o *ChatFeedOptions) granted() (bool, error) {
	ok, err := o.Grant()
	if err != nil {
		return false, err
	}
	if !ok {
		o.Watches.DropAll()
	}
	return ok, nil
}

// ChatFeedSource is the `chat_feed` slice, record `chat_feed-<conversation
// id>`: the watched conversations' last 60 active-branch messages, the
// latest version of each artifact and the actions of those turns, capped at
// 600 000 bytes (iPhone chat spec §4.6). A feed is published while its
// watch lasts (open: 5 min, repeated by the phone; prefetch: 2 min) and is
// read anew on every change the engine reports (OnChange) or the
// agent_actions table sees; a running turn's text and steps come from the
// engine's memory. Urgent. A nil engine (chat off) publishes nothing.
type ChatFeedSource struct {
	e ChatReader
	o ChatFeedOptions
}

// ChatFeed builds the chat_feed source over the engine e.
func ChatFeed(e ChatReader, o ChatFeedOptions) *ChatFeedSource {
	o.fill()
	return &ChatFeedSource{e: e, o: o}
}

// Kind is "chat_feed".
func (s *ChatFeedSource) Kind() hubslices.Kind { return hubslices.KindChatFeed }

// Items is one record per watched conversation that still exists.
func (s *ChatFeedSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if s.e == nil {
		return nil, nil
	}
	if ok, err := s.o.granted(); err != nil || !ok {
		return nil, err
	}
	var items []hubslices.Item
	for _, conv := range s.o.Watches.activeFeeds(s.o.Now()) {
		b, ok, err := s.feed(ctx, conv)
		if err != nil {
			return nil, err
		}
		if ok {
			items = append(items, hubslices.Item{ID: strconv.FormatInt(conv, 10), Payload: b})
		}
	}
	return items, nil
}

// feed is one conversation's payload; ok is false when it is gone.
func (s *ChatFeedSource) feed(ctx context.Context, conv int64) ([]byte, bool, error) {
	f, err := s.e.Feed(ctx, conv, 0)
	if errors.Is(err, chatstore.ErrConversationGone) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	b, err := encodeChatFeed(f)
	return b, err == nil, err
}

// ChatPageSource is the `chat_page` slice, record `chat_page-<conversation
// id>-<before message id>`: the 60 active-branch messages before that
// message, with has_more, in the feed's per-message shape and caps. Built
// once on its request (Watches.Pages) and kept for 5 minutes; a message no
// longer on the active branch gives an empty page.
type ChatPageSource struct {
	e     ChatReader
	o     ChatFeedOptions
	mu    sync.Mutex
	cache map[ChatPageKey]cachedRecord
}

// ChatPage builds the chat_page source.
func ChatPage(e ChatReader, o ChatFeedOptions) *ChatPageSource {
	o.fill()
	return &ChatPageSource{e: e, o: o, cache: map[ChatPageKey]cachedRecord{}}
}

// Kind is "chat_page".
func (s *ChatPageSource) Kind() hubslices.Kind { return hubslices.KindChatPage }

// ChatPageID is a chat_page record's id.
func ChatPageID(k ChatPageKey) string {
	return strconv.FormatInt(k.Conversation, 10) + "-" + strconv.FormatInt(k.Before, 10)
}

// Items is the requested pages.
func (s *ChatPageSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if s.e == nil {
		return nil, nil
	}
	if ok, err := s.o.granted(); err != nil || !ok {
		s.prune(nil)
		return nil, err
	}
	keys := s.o.Watches.Pages.Active(s.o.Now())
	s.prune(keys)
	slices.SortFunc(keys, func(a, b ChatPageKey) int {
		return cmp.Or(cmp.Compare(a.Conversation, b.Conversation), cmp.Compare(a.Before, b.Before))
	})
	items := make([]hubslices.Item, 0, len(keys))
	for _, k := range keys {
		b, err := cached(&s.mu, s.cache, k, s.o.Watches.Pages.Gen(k), func() ([]byte, error) { return s.buildChatPage(ctx, k) })
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: ChatPageID(k), Payload: b})
	}
	return items, nil
}

func (s *ChatPageSource) prune(keep []ChatPageKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.cache {
		if !slices.Contains(keep, k) {
			delete(s.cache, k)
		}
	}
}

func (s *ChatPageSource) buildChatPage(ctx context.Context, k ChatPageKey) ([]byte, error) {
	page := chatPagePayload{Messages: []chatengine.FeedMessage{}}
	f, err := s.e.Feed(ctx, k.Conversation, k.Before)
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
	case err != nil:
		return nil, err
	default:
		page.Messages, page.HasMore = f.Messages, f.HasMore
	}
	return encodeChatPage(page)
}

// ChatSearchSource is the `chat_search` slice, record `chat_search-<query
// hash>` (ChatSearchID): up to 50 hits of the Mac's chat search
// (db.SearchChats) with titles and snippets of at most 200 characters,
// within MaxChatFeedBytes. Built once on
// its request (Watches.Searches) and kept for 5 minutes.
type ChatSearchSource struct {
	e     ChatReader
	o     ChatFeedOptions
	mu    sync.Mutex
	cache map[string]cachedRecord
}

// ChatSearch builds the chat_search source.
func ChatSearch(e ChatReader, o ChatFeedOptions) *ChatSearchSource {
	o.fill()
	return &ChatSearchSource{e: e, o: o, cache: map[string]cachedRecord{}}
}

// Kind is "chat_search".
func (s *ChatSearchSource) Kind() hubslices.Kind { return hubslices.KindChatSearch }

// ChatSearchID is a chat_search record's id: the first 16 hex digits of the
// sha256 of the query's UTF-8 bytes, as the phone sent it (the Kit's
// ChatSearch.recordName).
func ChatSearchID(query string) string {
	sum := sha256.Sum256([]byte(query))
	return hex.EncodeToString(sum[:8])
}

// Items is the requested searches.
func (s *ChatSearchSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	if s.e == nil {
		return nil, nil
	}
	if ok, err := s.o.granted(); err != nil || !ok {
		s.prune(nil)
		return nil, err
	}
	queries := s.o.Watches.Searches.Active(s.o.Now())
	s.prune(queries)
	slices.Sort(queries)
	items := make([]hubslices.Item, 0, len(queries))
	for _, q := range queries {
		b, err := cached(&s.mu, s.cache, q, s.o.Watches.Searches.Gen(q), func() ([]byte, error) { return s.search(ctx, q) })
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: ChatSearchID(q), Payload: b})
	}
	return items, nil
}

func (s *ChatSearchSource) prune(keep []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.cache {
		if !slices.Contains(keep, k) {
			delete(s.cache, k)
		}
	}
}

func (s *ChatSearchSource) search(ctx context.Context, q string) ([]byte, error) {
	payload, err := s.e.Search(ctx, q)
	if err != nil {
		return nil, err
	}
	// Titles and snippets are capped, so 50 hits fit; the weakest hits go
	// should a query's echo ever not leave them room.
	for {
		b, err := wire.Marshal(payload)
		if err != nil || len(b) <= MaxChatFeedBytes || len(payload.Hits) == 0 {
			return b, err
		}
		payload.Hits = payload.Hits[:len(payload.Hits)-1]
	}
}

// cachedRecord is a built page or search and the request (Gen) it answers.
type cachedRecord struct {
	gen uint64
	b   []byte
}

// cached is cache[k] while it answers request gen, else built anew by build:
// the phone asked again (a Retry, a reopened screen), so it gets what the
// database holds now.
func cached[K comparable](mu *sync.Mutex, cache map[K]cachedRecord, k K, gen uint64, build func() ([]byte, error)) ([]byte, error) {
	mu.Lock()
	c, ok := cache[k]
	mu.Unlock()
	if ok && c.gen == gen {
		return bytes.Clone(c.b), nil
	}
	b, err := build()
	if err != nil {
		return nil, err
	}
	mu.Lock()
	cache[k] = cachedRecord{gen: gen, b: b}
	mu.Unlock()
	return bytes.Clone(b), nil
}

type chatPagePayload struct {
	Messages []chatengine.FeedMessage `json:"messages"`
	HasMore  bool                     `json:"has_more"`
}

// encodeChatFeed encodes p within MaxChatFeedBytes, always: the oldest
// messages go first (has_more then true; the newest one always stays) with
// the actions of their turns, then the artifacts' contents, largest first
// (content_cut: "Open on your Mac"), then fitFeed's last resort.
func encodeChatFeed(p chatengine.Feed) ([]byte, error) {
	msgSizes, err := sizes(p.Messages)
	if err != nil {
		return nil, err
	}
	envelope := p
	envelope.Messages, envelope.HasMore = []chatengine.FeedMessage{}, false
	base, err := wire.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	total := len(base) + sum(msgSizes) + commas(len(msgSizes))
	drop := 0
	for total > MaxChatFeedBytes && len(msgSizes)-drop > 1 {
		total -= msgSizes[drop] + min(1, len(msgSizes)-drop-1)
		drop++
	}
	if drop > 0 {
		p.Messages, p.HasMore = p.Messages[drop:], true
		turns := map[string]bool{}
		for _, m := range p.Messages {
			turns[m.TurnID()] = true
		}
		p.Actions = slices.DeleteFunc(slices.Clone(p.Actions), func(a chatengine.FeedAction) bool { return !turns[a.TurnID()] })
	}
	b, err := wire.Marshal(p)
	if err != nil || len(b) <= MaxChatFeedBytes {
		return b, err
	}
	artSizes, err := sizes(p.Artifacts)
	if err != nil {
		return nil, err
	}
	over := len(b) - MaxChatFeedBytes
	order := make([]int, len(p.Artifacts))
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(a, b int) int { return cmp.Compare(artSizes[b], artSizes[a]) })
	p.Artifacts = slices.Clone(p.Artifacts)
	for _, i := range order {
		if over <= 0 {
			break
		}
		a := &p.Artifacts[i]
		a.Content, a.ContentCut = nil, true
		cut, err := wire.Marshal(*a)
		if err != nil {
			return nil, err
		}
		over -= artSizes[i] - len(cut)
	}
	return fitFeed(p)
}

// fitFeed is the hard ceiling: while the record is over MaxChatFeedBytes
// (a newest message of wide graphemes or escaped control characters, many
// large actions or steps), it cuts the largest message text by encoded
// bytes (text_cut stays true), then empties the messages' steps, then
// drops actions, oldest first, then clips the title. The result always
// fits unless the envelope alone does not, which no field allows.
func fitFeed(p chatengine.Feed) ([]byte, error) {
	p.Messages = slices.Clone(p.Messages)
	p.Actions = slices.Clone(p.Actions)
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes {
			return b, err
		}
		over := len(b) - MaxChatFeedBytes
		switch {
		case shrinkLargestText(p.Messages, over):
		case clearSteps(p.Messages):
		case len(p.Actions) > 0:
			chatengine.DropApprovalPart(p.Messages, p.Actions[0].ID)
			p.Actions = p.Actions[1:]
		case uniseg.GraphemeClusterCount(p.Conversation.Title) > maxChatLabel:
			p.Conversation.Title, _ = clipText(p.Conversation.Title, maxChatLabel)
		default:
			return b, nil
		}
	}
}

// encodeChatPage is encodeChatFeed for a page: the oldest messages go
// first, then fitPage's last resort.
func encodeChatPage(p chatPagePayload) ([]byte, error) {
	msgSizes, err := sizes(p.Messages)
	if err != nil {
		return nil, err
	}
	base, err := wire.Marshal(chatPagePayload{Messages: []chatengine.FeedMessage{}})
	if err != nil {
		return nil, err
	}
	total := len(base) + sum(msgSizes) + commas(len(msgSizes))
	drop := 0
	for total > MaxChatFeedBytes && len(msgSizes)-drop > 1 {
		total -= msgSizes[drop] + min(1, len(msgSizes)-drop-1)
		drop++
	}
	if drop > 0 {
		p.Messages, p.HasMore = p.Messages[drop:], true
	}
	p.Messages = slices.Clone(p.Messages)
	for {
		b, err := wire.Marshal(p)
		if err != nil || len(b) <= MaxChatFeedBytes {
			return b, err
		}
		if !shrinkLargestText(p.Messages, len(b)-MaxChatFeedBytes) && !clearSteps(p.Messages) && !chatengine.ClearApprovals(p.Messages) {
			return b, nil
		}
	}
}

// shrinkLargestText cuts the message text that encodes largest by at least
// over encoded bytes (by graphemes, ellipsis included; text_cut set); false
// when every text is already empty.
func shrinkLargestText(msgs []chatengine.FeedMessage, over int) bool {
	best, bestLen := -1, 2 // `""`
	for i := range msgs {
		if n := jsonLen(msgs[i].Text); n > bestLen {
			best, bestLen = i, n
		}
	}
	if best < 0 {
		return false
	}
	m := &msgs[best]
	// The text rides three times (flat, the text part's payload and its
	// fallback): the loop calling this runs again while the record is over.
	target := bestLen - (over+2)/3
	lo, hi := 0, uniseg.GraphemeClusterCount(m.Text)-1 // hi: cut by at least one
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if t, _ := clipText(m.Text, mid); jsonLen(t) <= target {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	m.Text, _ = clipText(m.Text, lo)
	m.TextCut = true
	m.RefitParts()
	return true
}

// clearSteps empties the steps of the message whose steps are largest;
// false when no message has steps.
func clearSteps(msgs []chatengine.FeedMessage) bool {
	best, bestLen := -1, 0
	for i := range msgs {
		if len(msgs[i].Steps) == 0 {
			continue
		}
		b, _ := wire.Marshal(msgs[i].Steps)
		if len(b) > bestLen {
			best, bestLen = i, len(b)
		}
	}
	if best < 0 {
		return false
	}
	msgs[best].Steps = []chatengine.FeedStep{}
	msgs[best].RefitParts()
	return true
}

// jsonLen is a string's encoded length on the wire.
func jsonLen(s string) int {
	b, err := wire.Marshal(s)
	if err != nil {
		return len(s)
	}
	return len(b)
}

func sizes[T any](items []T) ([]int, error) {
	out := make([]int, len(items))
	for i, it := range items {
		b, err := wire.Marshal(it)
		if err != nil {
			return nil, err
		}
		out[i] = len(b)
	}
	return out, nil
}

func sum(xs []int) int {
	n := 0
	for _, x := range xs {
		n += x
	}
	return n
}

// commas is the separators of an n-element JSON array.
func commas(n int) int { return max(n-1, 0) }
