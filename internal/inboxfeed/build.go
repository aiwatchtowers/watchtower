// Package inboxfeed is the one Inbox implementation: it builds the feed
// both clients draw (inbox.feed) from one read-only snapshot. It is the Go
// port of the Desktop's InboxFolderEntries, InboxListBuilder,
// InboxFolderCounts and the list and counts part of ActionStripViewModel;
// the shared fixture testdata/inbox_feed_cases.json pins that the two agree
// (InboxFeedParityTests runs the Swift builders over the same cases). See
// docs/features/inbox-core.md.
package inboxfeed

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// ClipBytes is the most of a card's body Options.Clip keeps.
const ClipBytes = 16 << 10

// MaxBlocksBytes is the largest block document a card carries; a bigger
// one is sent as a notice card, never as a broken record.
const MaxBlocksBytes = 128 << 10

// Options shape one Build.
type Options struct {
	// Folder narrows the cards to one folder (every folder is still sent).
	Folder *int64
	// Limit caps the cards (0 = none): see Limit.
	Limit int
	// Clip clips each body to ClipBytes on a rune boundary.
	Clip bool
	// Now is the moment the feed is read at. Its location is the owner's
	// zone for the one date-only value the read compares (an idea's
	// "not now" day); every stamp the feed carries is UTC.
	Now time.Time
}

// stampLayout is how Go writes the automation tables' times and how the
// feed sends every stamp: RFC 3339 UTC, whole seconds.
const stampLayout = "2006-01-02T15:04:05Z"

// Build reads the Inbox in one read-only transaction and composes the feed.
// It writes nothing.
func Build(ctx context.Context, d *db.DB, o Options) (api.Feed, error) {
	if o.Now.IsZero() {
		o.Now = time.Now()
	}
	tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return api.Feed{}, fmt.Errorf("inboxfeed: opening the read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	s, err := read(ctx, tx, o.Now)
	if err != nil {
		return api.Feed{}, err
	}
	feed := compose(s, o)
	feed.BuiltAt = o.Now.UTC().Format(stampLayout)
	return feed, nil
}

// compose lays the snapshot out as the feed: every folder with its counts,
// then the cards (narrowed, capped and clipped by o).
func compose(s *snapshot, o Options) api.Feed {
	feed := api.Feed{V: api.FeedVersion, Folders: s.apiFolders()}
	cards := []api.Card{}
	for _, f := range s.tree.folders {
		if o.Folder != nil && *o.Folder != f.ID {
			continue
		}
		cards = append(cards, s.cards(f)...)
	}
	if o.Limit > 0 {
		cards, feed.More = Limit(cards, s.tree.approvalsID(), o.Limit)
	}
	if o.Clip {
		for i := range cards {
			cards[i].Body, cards[i].BodyClipped = Clip(cards[i].Body, ClipBytes)
		}
	}
	feed.Cards = cards
	return feed
}

// snapshot is everything one Build reads, from one transaction: the
// InboxFolderMenuSnapshot and InboxFeedSnapshot of the Desktop, reduced to
// what the feed carries.
type snapshot struct {
	tree tree
	// artifacts are each folder's open artifacts in the Inbox order, without
	// Needs approval's own cards and without Waiting for me's while the
	// Messages entry stands in for it.
	artifacts map[int64][]output
	// refs are each artifact's row refs (output id → refs).
	refs map[int64][]ref
	// waits are the refs whose record waits on the owner.
	waits        map[ref]bool
	waitingForMe waitingForMe
	notices      []notice
	// counts are each folder's own count.
	counts map[int64]int
}

// read reads the snapshot at now.
func read(ctx context.Context, tx *sql.Tx, now time.Time) (*snapshot, error) {
	t, err := readTree(ctx, tx)
	if err != nil {
		return nil, err
	}
	s := &snapshot{tree: t}
	if s.waitingForMe, err = readWaitingForMe(ctx, tx); err != nil {
		return nil, err
	}
	approvalsAutomation, err := builtinAutomationID(ctx, tx, needsApprovalBuiltinID)
	if err != nil {
		return nil, err
	}
	outputs, err := readOutputs(ctx, tx)
	if err != nil {
		return nil, err
	}
	s.artifacts = place(t, outputs, func(o output) bool {
		if approvalsAutomation != 0 && o.AutomationID == approvalsAutomation {
			return false // Needs approval's own cards (Task 7's approvals)
		}
		return !s.waitingForMe.hides(o.AutomationID)
	})
	s.refs = map[int64][]ref{}
	var all []ref
	for _, list := range s.artifacts {
		for _, o := range list {
			r := refsOf(o.BlocksJSON)
			s.refs[o.ID] = r
			all = append(all, r...)
		}
	}
	if s.waits, err = readWaits(ctx, tx, all, now); err != nil {
		return nil, err
	}
	if s.notices, err = readNotices(ctx, tx); err != nil {
		return nil, err
	}
	legacy, err := legacyCounts(ctx, tx, t, now, s.waitingForMe.standIn, len(s.notices))
	if err != nil {
		return nil, err
	}
	s.counts = counts(t, s.artifacts, s.refs, s.waits, legacy)
	return s, nil
}
