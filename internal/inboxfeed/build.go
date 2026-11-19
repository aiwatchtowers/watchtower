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
	"slices"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// ClipBytes is the most of a card's body Options.Clip keeps.
const ClipBytes = 16 << 10

// ArgsDisplayClipBytes is the most of an approval's args_display
// Options.Clip keeps (mobile Inbox spec §12.1): a byte cap on top of
// tools.ArgsDisplay's 4000 characters, so a card stays within the hub's
// record budget whatever its characters' widths.
const ArgsDisplayClipBytes = 8 << 10

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
	// Day is a Morning brief day the client has open (FeedRequest.Day):
	// listed while it has a briefing or a day plan.
	Day string
	// DisabledFeatures are the feature registry ids turned off (the
	// config's switches, as `features list` reports them "disabled"): the
	// Mac's own feature list. Attention detection off ("secretary-inbox")
	// turns Waiting for me and its Messages stand-in off.
	DisabledFeatures []string
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
	s, err := read(ctx, tx, o.Now, o.DisabledFeatures)
	if err != nil {
		return api.Feed{}, err
	}
	s.legacy.openDay = o.Day
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
		var approvals *int64
		if s.tree.hasApprovals() {
			id := s.tree.approvalsID()
			approvals = &id
		}
		cards, feed.More = Limit(cards, approvals, o.Limit)
	}
	for i := range cards {
		ap := cards[i].Approval
		if !o.Clip {
			// The display args are the phone's (the hub's clipped feed, §12.1):
			// the Mac draws its own rows and never reads them.
			if ap != nil {
				ap.ArgsDisplay, ap.ArgsComplete = "", false
			}
			continue
		}
		cards[i].Body, cards[i].BodyClipped = Clip(cards[i].Body, ClipBytes)
		if ap != nil {
			ap.RecipeText, ap.Diff, ap.RecipeClipped = clipRecipe(ap.RecipeText, ap.Diff)
			var cut bool
			if ap.ArgsDisplay, cut = Clip(ap.ArgsDisplay, ArgsDisplayClipBytes); cut {
				ap.ArgsComplete = false
			}
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
	// outputs are every open inbox output by id (Needs approval's recipe
	// cards included).
	outputs map[int64]output
	// artifacts are each folder's open artifacts in the Inbox order, without
	// Needs approval's own cards and without Waiting for me's while the
	// Messages entry stands in for it.
	artifacts map[int64][]output
	// refs are each output's row refs (output id → refs).
	refs map[int64][]ref
	// refState is what the read found about their records.
	refState     refState
	waitingForMe waitingForMe
	notices      []notice
	// needs is Needs approval's read: the open approvals, their artifacts,
	// the built-in's state and the settled rows.
	needs db.NeedsApprovalView
	// targets are the target buttons' facts by context id.
	targets map[string]targetFacts
	// runLabels name the runs that proposed an approval; workbenches the
	// workbenches a save_automation names.
	runLabels, workbenches map[int64]string
	legacy                 legacy
	// counts and waiting are each folder's own count and the part of it
	// that waits on the owner.
	counts, waiting map[int64]int
	now             time.Time
}

// read reads the snapshot at now with the features off in disabled.
func read(ctx context.Context, tx *sql.Tx, now time.Time, disabled []string) (*snapshot, error) {
	off := func(id string) bool { return slices.Contains(disabled, id) }
	t, err := readTree(ctx, tx)
	if err != nil {
		return nil, err
	}
	s := &snapshot{tree: t, now: now}
	if s.waitingForMe, err = readWaitingForMe(ctx, tx, !off(waitingForMeFeatureID)); err != nil {
		return nil, err
	}
	if s.needs, err = db.ReadNeedsApprovalTx(ctx, tx, now); err != nil {
		return nil, fmt.Errorf("inboxfeed: %w", err)
	}
	s.needs.Builtin.FeatureOn = !off(approvalsFeatureID)
	approvalsAutomation := s.needs.Builtin.AutomationID
	all, err := readOutputs(ctx, tx)
	if err != nil {
		return nil, err
	}
	s.outputs = make(map[int64]output, len(all))
	s.refs = map[int64][]ref{}
	var refs []ref
	for _, o := range all {
		s.outputs[o.ID] = o
		r := refsOf(o.BlocksJSON)
		s.refs[o.ID] = r
		refs = append(refs, r...)
	}
	s.artifacts = place(t, all, func(o output) bool {
		if approvalsAutomation != 0 && o.AutomationID == approvalsAutomation {
			return false // drawn only through the approvals they show (APPROVAL-01)
		}
		return !s.waitingForMe.hides(o.AutomationID)
	})
	if s.legacy, err = readLegacy(ctx, tx, now, off, s.waitingForMe.standIn); err != nil {
		return nil, err
	}
	// The Messages card's items carry their facts too (Reply, an open
	// Reply, shown, waits), as an artifact's rows do.
	for _, m := range s.legacy.messages {
		refs = append(refs, ref{Kind: api.RefInboxItem, ID: m.ID})
	}
	if s.refState, err = readRefState(ctx, tx, refs, now); err != nil {
		return nil, err
	}
	if s.notices, err = readNotices(ctx, tx); err != nil {
		return nil, err
	}
	if s.targets, err = readTargetFacts(ctx, tx); err != nil {
		return nil, err
	}
	if err := readApprovalExtras(ctx, tx, s); err != nil {
		return nil, err
	}
	legacy, err := legacyCounts(ctx, tx, t, now, s.waitingForMe.standIn, len(s.notices))
	if err != nil {
		return nil, err
	}
	s.counts = counts(t, s.artifacts, s.refs, s.refState.waits, legacy)
	s.waiting = waitingCounts(t, s.artifacts, s.refs, s.refState.waits, len(s.needs.Open))
	return s, nil
}
