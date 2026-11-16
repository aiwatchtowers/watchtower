package sources

import (
	"context"
	"log"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources/inboxlegacy"
	"watchtower/internal/hub/wire"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tower/api"
)

// PhoneInboxLimit is the cards the phone's feed keeps (inbox.feed's Limit:
// Needs approval and Waiting for me first, then the rest newest first).
const PhoneInboxLimit = 300

// InboxFeed builds the Inbox feed (inbox.feed) with o; the hub's is the
// daemon tower's own command, so the phone reads what the Mac reads.
type InboxFeed func(ctx context.Context, o inboxfeed.Options) (api.Feed, error)

// inboxFolderRecord is an inbox_folder record: the folder and how many of
// its cards PhoneInboxLimit left out (Feed.More).
type inboxFolderRecord struct {
	api.Folder
	More int `json:"more,omitempty"`
}

// InboxSource is the phone Inbox (mobile Inbox spec §6): inbox_folder-<id>,
// one record per folder of the feed (hidden ones flagged, as the Mac's menu
// gets them), and inbox_card-<id>, one per card, from one feed built with
// Limit PhoneInboxLimit and Clip. A legacy card carries its section as a
// block document (inboxlegacy, times in loc) and keeps only its section's
// kind. The feed is built outside any write transaction, once per cycle for
// both kinds; a failed build fails both kinds, which keep their last records
// (the publisher logs the error class). now nil is time.Now, loc nil
// time.Local.
func InboxSource(build InboxFeed, now func() time.Time, loc *time.Location) []slices.Source {
	if now == nil {
		now = time.Now
	}
	if loc == nil {
		loc = time.Local
	}
	f := &inboxFeedCache{build: build, now: now, loc: loc, served: map[slices.Kind]bool{}}
	return []slices.Source{inboxKindSource{f, slices.KindInboxFolder}, inboxKindSource{f, slices.KindInboxCard}}
}

// inboxFeedCache shares one build between the two kinds of a cycle: a kind
// that already took the cached feed builds a new one.
type inboxFeedCache struct {
	build InboxFeed
	now   func() time.Time
	loc   *time.Location

	mu     sync.Mutex
	feed   *api.Feed
	served map[slices.Kind]bool
}

func (c *inboxFeedCache) take(ctx context.Context, k slices.Kind) (*api.Feed, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.feed == nil || c.served[k] {
		c.feed, c.served = nil, map[slices.Kind]bool{}
		feed, err := c.build(ctx, inboxfeed.Options{Limit: PhoneInboxLimit, Clip: true, Now: c.now()})
		if err != nil {
			return nil, err
		}
		c.feed = &feed
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
	return cardItems(feed, s.c.loc)
}

func folderItems(feed *api.Feed) ([]slices.Item, error) {
	more := map[int64]int{}
	for _, m := range feed.More {
		more[m.FolderID] = m.Count
	}
	out := make([]slices.Item, 0, len(feed.Folders))
	for _, f := range feed.Folders {
		payload, err := wire.Marshal(inboxFolderRecord{Folder: f, More: more[f.ID]})
		if err != nil {
			return nil, err
		}
		out = append(out, slices.Item{ID: strconv.FormatInt(f.ID, 10), Payload: payload})
	}
	return out, nil
}

func cardItems(feed *api.Feed, loc *time.Location) ([]slices.Item, error) {
	out := make([]slices.Item, 0, len(feed.Cards))
	for _, c := range feed.Cards {
		if c.Legacy != nil {
			c = projectLegacy(c, loc)
		}
		payload, err := wire.Marshal(c)
		if err != nil {
			return nil, err
		}
		out = append(out, slices.Item{ID: c.ID, Payload: payload})
	}
	return out, nil
}

// projectLegacy is a legacy card as the phone gets it: its section as a
// block document, the section's kind alone left beside it. A section that
// does not project leaves the card with no blocks (logged by class).
func projectLegacy(c api.Card, loc *time.Location) api.Card {
	doc, err := inboxlegacy.Project(*c.Legacy, loc)
	if err != nil {
		log.Printf("hub slices: an inbox legacy card was not projected (%s)", errClass(err))
		doc = ""
	}
	c.Blocks = doc
	c.Legacy = &api.LegacySection{Kind: c.Legacy.Kind, Items: []api.LegacyItem{}, Attention: []api.LegacyAttention{}}
	return c
}
