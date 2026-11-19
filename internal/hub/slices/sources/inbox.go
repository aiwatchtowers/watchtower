package sources

import (
	"context"
	"log"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources/inboxlegacy"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tower/api"
)

// PhoneInboxLimit is the cards the phone's feed keeps (inbox.feed's Limit:
// Needs approval and Waiting for me first, then the rest newest first).
const PhoneInboxLimit = 300

// inboxRecordBudget is the most a card's payload may be: the envelope cap
// less its header, signature and padding.
const inboxRecordBudget = secure.MaxEnvelopeBytes - 4096

// inboxFeedReuse is how long one build serves the other kind: the two kinds
// of one cycle, never a later retry.
const inboxFeedReuse = 5 * time.Second

// fallbackTitleChars caps the title of a card published in its fallback
// form.
const fallbackTitleChars = 200

// InboxFeed builds the Inbox feed (inbox.feed) with o; the hub's is the
// daemon tower's own command, so the phone reads what the Mac reads.
type InboxFeed func(ctx context.Context, o inboxfeed.Options) (api.Feed, error)

// inboxFolderRecord is an inbox_folder record: the folder, how many of its
// cards PhoneInboxLimit left out (Feed.More), and the ids of its cards in the
// feed's order. The replica keeps no publish order, so the phone lists a
// folder's cards by CardIDs; carrying the order here keeps card records
// order-free, so a new card changes only its own record and its folder's.
type inboxFolderRecord struct {
	api.Folder
	More    int      `json:"more,omitempty"`
	CardIDs []string `json:"card_ids"`
}

// InboxSource is the phone Inbox (mobile Inbox spec §6): inbox_folder-<id>,
// one record per folder of the feed (hidden ones flagged, as the Mac's menu
// gets them; the phone's screen models hide them), and inbox_card-<id>, one
// per card, from one feed built with Limit PhoneInboxLimit and Clip. A
// legacy card keeps its typed section (UTC stamps: the phone draws plan
// times in its own zone) and carries it as a block document too
// (inboxlegacy); one past the record budget drops the typed items and keeps
// the (capped) document. Any other card past the budget is published in a
// fallback form, never failing the kind. The feed is built outside any write
// transaction, once per cycle for both kinds; a failed build fails both
// kinds, which keep their last records (the publisher logs the error
// class). now nil is time.Now.
func InboxSource(build InboxFeed, now func() time.Time) []slices.Source {
	if now == nil {
		now = time.Now
	}
	f := &inboxFeedCache{build: build, now: now, served: map[slices.Kind]bool{}}
	return []slices.Source{inboxKindSource{f, slices.KindInboxFolder}, inboxKindSource{f, slices.KindInboxCard}}
}

// inboxFeedCache shares one build between the two kinds of a cycle: a kind
// that already took the cached feed, or a feed older than inboxFeedReuse,
// builds a new one.
type inboxFeedCache struct {
	build InboxFeed
	now   func() time.Time

	mu      sync.Mutex
	feed    *api.Feed
	builtAt time.Time
	served  map[slices.Kind]bool
}

func (c *inboxFeedCache) take(ctx context.Context, k slices.Kind) (*api.Feed, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if age := now.Sub(c.builtAt); c.feed == nil || c.served[k] || age < 0 || age > inboxFeedReuse {
		c.feed, c.served = nil, map[slices.Kind]bool{}
		// OmitMacOnly: the phone has no journal pane, and the card must not
		// take a slot under the limit.
		feed, err := c.build(ctx, inboxfeed.Options{Limit: PhoneInboxLimit, Clip: true, OmitMacOnly: true, Now: now})
		if err != nil {
			return nil, err
		}
		c.feed, c.builtAt = &feed, now
	}
	c.served[k] = true
	return c.feed, nil
}

type inboxKindSource struct {
	c    *inboxFeedCache
	kind slices.Kind
}

func (s inboxKindSource) Kind() slices.Kind { return s.kind }

func (s inboxKindSource) Items(ctx context.Context) ([]slices.Item, error) {
	feed, err := s.c.take(ctx, s.kind)
	if err != nil {
		return nil, err
	}
	if s.kind == slices.KindInboxFolder {
		return folderItems(feed)
	}
	return cardItems(feed)
}

func folderItems(feed *api.Feed) ([]slices.Item, error) {
	more := map[int64]int{}
	for _, m := range feed.More {
		more[m.FolderID] = m.Count
	}
	ids := map[int64][]string{}
	for _, c := range feed.Cards {
		ids[c.FolderID] = append(ids[c.FolderID], c.ID)
	}
	out := make([]slices.Item, 0, len(feed.Folders))
	for _, f := range feed.Folders {
		cardIDs := ids[f.ID]
		if cardIDs == nil {
			cardIDs = []string{}
		}
		payload, err := wire.Marshal(inboxFolderRecord{Folder: f, More: more[f.ID], CardIDs: cardIDs})
		if err != nil {
			return nil, err
		}
		out = append(out, slices.Item{ID: strconv.FormatInt(f.ID, 10), Payload: payload})
	}
	return out, nil
}

func cardItems(feed *api.Feed) ([]slices.Item, error) {
	out := make([]slices.Item, 0, len(feed.Cards))
	for _, c := range feed.Cards {
		if c.Legacy != nil {
			c = projectLegacy(c)
		}
		payload, err := wire.Marshal(c)
		if err != nil {
			return nil, err
		}
		if len(payload) > inboxRecordBudget && c.Legacy != nil {
			// A long legacy list: its document (capped) stands alone.
			c.Legacy = &api.LegacySection{Kind: c.Legacy.Kind, Items: []api.LegacyItem{}, Attention: []api.LegacyAttention{}}
			if payload, err = wire.Marshal(c); err != nil {
				return nil, err
			}
		}
		if len(payload) > inboxRecordBudget {
			// One record over the envelope cap would fail the whole kind:
			// the card goes out in its fallback form instead.
			if payload, err = wire.Marshal(fallbackCard(c)); err != nil {
				return nil, err
			}
		}
		out = append(out, slices.Item{ID: c.ID, Payload: payload})
	}
	return out, nil
}

// projectLegacy is a legacy card as the phone gets it: its typed section
// and the section as a block document. A section that does not project
// carries one line sending the owner to the Mac (logged by class).
func projectLegacy(c api.Card) api.Card {
	doc, err := inboxlegacy.Project(*c.Legacy)
	if err != nil {
		log.Printf("hub slices: an inbox legacy card was not projected (%s)", errClass(err))
		doc = inboxlegacy.Unprojected()
	}
	c.Blocks = doc
	return c
}

// fallbackCard is c too large to publish: its ids, place and time, its
// title clipped, and the too-large sentence as its body; a notice with no
// blocks, actions, approval or legacy section, so the phone sends the owner
// to the Mac.
func fallbackCard(c api.Card) api.Card {
	title := c.Title
	if utf8.RuneCountInString(title) > fallbackTitleChars {
		title = string([]rune(title)[:fallbackTitleChars-1]) + ellipsis
	}
	return api.Card{
		ID: c.ID, FolderID: c.FolderID, CardKind: api.CardNotice, Title: title,
		Preview: inboxfeed.TooLargeSentence, Body: inboxfeed.TooLargeSentence,
		Stamp: c.Stamp, Unread: c.Unread, Priority: c.Priority, Pinned: c.Pinned,
		ContentHash: c.ContentHash, Actions: []api.CardAction{}, RefFacts: []api.RefFacts{},
	}
}
