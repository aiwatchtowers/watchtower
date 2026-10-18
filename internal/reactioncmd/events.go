package reactioncmd

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/slack-go/slack"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// EventSink is the automations event bus as the poll sees it: whether a
// runnable recipe listens for an event type, and the publish call.
type EventSink interface {
	Wants(eventType string) bool
	Publish(events ...automations.Event)
}

// reactionList is one account's reactions.list result for one poll, fetched
// on first use and shared by the dictionary and the event paths.
type reactionList struct {
	acct     Account
	rawOwner string
	fetched  bool
	items    []slack.ReactedItem
	err      error
}

func newReactionList(acct Account) *reactionList {
	rawOwner := acct.OwnerID
	if _, raw, ok := watchtowerslack.SplitAccountID(acct.OwnerID); ok {
		rawOwner = raw
	}
	return &reactionList{acct: acct, rawOwner: rawOwner}
}

func (l *reactionList) get(ctx context.Context) ([]slack.ReactedItem, error) {
	if !l.fetched {
		l.fetched = true
		l.items, l.err = l.acct.Lister.ListUserReactions(ctx, l.rawOwner)
		if l.err != nil {
			l.err = fmt.Errorf("reactions.list: %w", l.err)
		}
	}
	return l.items, l.err
}

// resetEventSeeds clears every account's reaction-events stamp while the bus
// has no listener for reaction events, so the next wanted poll records what
// was placed meanwhile as history instead of firing for it. Best-effort: an error is logged.
func (p *Pipeline) resetEventSeeds() {
	if err := p.db.ResetReactionEventsSeeded(); err != nil {
		p.logf("reaction-commands: clearing reaction-event seed stamps: %v", err)
	}
}

// publishReactionEvents publishes a slack.reaction_added event for every owner
// reaction on a message that the reaction_events ledger has not seen, in list
// order. An account without a seed stamp records its reactions as history and
// publishes nothing. A reaction on a message older than the seed stamp never
// fires (ask #366): reactions.list returns only the latest window, so removing
// a fresh reaction slides an old, never-recorded one into it, and the message
// time is the only signal telling the two apart. The cost: a fresh reaction on
// a message from before the seed does not fire either. The dictionary plays no
// part: a dictionary emoji takes the tool path and this one independently.
func (p *Pipeline) publishReactionEvents(ctx context.Context, list *reactionList, sink EventSink) error {
	accountID := list.acct.AccountID
	seededAt, err := p.db.ReactionEventsSeededAt(accountID)
	if err != nil {
		return err
	}
	items, err := list.get(ctx)
	if err != nil {
		return err
	}
	reactions := ownerMessageReactions(items, list.rawOwner, accountID)
	if seededAt.IsZero() {
		if err := p.db.SeedReactionEvents(accountID, reactions); err != nil {
			return err
		}
		p.logf("reaction-commands: account #%d: recorded %d pre-existing reaction(s) as seen for automation events", accountID, len(reactions))
		return nil
	}
	label, _, err := p.db.SlackEventLabels(accountID)
	if err != nil {
		return err
	}
	// Filter with a read first: a steady-state poll lists ~2000 reactions it
	// has all seen, and writing each one would churn the write lock.
	unseen, err := p.db.FilterUnseenReactionEvents(accountID, postedSince(reactions, seededAt))
	if err != nil {
		return err
	}
	var events []automations.Event
	for _, r := range unseen {
		inserted, err := p.db.InsertReactionEvent(r)
		if err != nil {
			p.logf("reaction-commands: account #%d: skipping the event for :%s: on %s@%s: %v", accountID, r.Emoji, r.ChannelID, r.MessageTS, err)
			continue
		}
		if inserted {
			events = append(events, automations.ReactionEvent(label, r.ChannelID, r.MessageTS, r.Emoji))
		}
	}
	if len(events) > 0 {
		sink.Publish(events...)
	}
	return nil
}

// postedSince keeps the reactions whose message was posted at or after since.
// A message ts is "<unix seconds>.<micros>"; one that does not parse is
// dropped with the old ones.
func postedSince(rs []db.OwnerReaction, since time.Time) []db.OwnerReaction {
	var out []db.OwnerReaction
	for _, r := range rs {
		secs, _, _ := strings.Cut(r.MessageTS, ".")
		posted, err := strconv.ParseInt(secs, 10, 64)
		if err == nil && posted >= since.Unix() {
			out = append(out, r)
		}
	}
	return out
}
