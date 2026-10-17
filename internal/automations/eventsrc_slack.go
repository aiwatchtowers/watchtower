package automations

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

const slackNewMessages = "slack.new_messages"

// SlackSource is phaseSlackSync's event source: one slack.new_messages per
// channel whose sync mark advanced during the phase, counting the new,
// non-deleted messages not written by the owner. A channel whose initial sync
// was not complete before the phase publishes nothing (its history is a
// backfill, not news).
func SlackSource(d *db.DB) EventSource { return slackSource{d: d} }

type slackSource struct{ d *db.DB }

func (slackSource) Type() string { return slackNewMessages }

func (s slackSource) Before(ctx context.Context) (EventDiff, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("snapshotting slack sync marks: %w", err)
	}
	marks, err := s.d.SlackChannelSyncMarks()
	if err != nil {
		return nil, fmt.Errorf("snapshotting slack sync marks: %w", err)
	}
	return slackDiff{d: s.d, before: marks}, nil
}

type slackDiff struct {
	d      *db.DB
	before map[string]db.SlackSyncMark
}

// slackAccountLabels is one account's event label and owner user id.
type slackAccountLabels struct{ account, owner string }

func (s slackDiff) After(ctx context.Context) ([]Event, error) {
	after, err := s.d.SlackChannelSyncMarks()
	if err != nil {
		return nil, fmt.Errorf("reading slack sync marks: %w", err)
	}
	labels := map[int64]slackAccountLabels{}
	var events []Event
	for _, id := range advancedChannels(s.before, after) {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("diffing slack sync marks: %w", err)
		}
		e, ok, err := s.channelEvent(id, s.before[id].LastSyncedTS, labels)
		if err != nil {
			return nil, err
		}
		if ok {
			events = append(events, e)
		}
	}
	return events, nil
}

// advancedChannels returns, sorted, the channels whose mark moved forward
// and whose initial sync was complete before the phase.
func advancedChannels(before, after map[string]db.SlackSyncMark) []string {
	var ids []string
	for id, a := range after {
		b, ok := before[id]
		if ok && b.InitialSyncComplete && a.LastSyncedTS > b.LastSyncedTS {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

// channelEvent builds one channel's event; false when it has no new message
// from someone other than the owner, or its id carries no account.
func (s slackDiff) channelEvent(id, oldTS string, cache map[int64]slackAccountLabels) (Event, bool, error) {
	acct, _, ok := slack.SplitAccountID(id)
	if !ok {
		return Event{}, false, nil
	}
	l, err := s.accountLabels(acct, cache)
	if err != nil {
		return Event{}, false, err
	}
	count, err := s.d.CountSlackMessagesAfter(id, oldTS, l.owner)
	if err != nil || count == 0 {
		return Event{}, false, err
	}
	name, err := s.d.ChannelNameByID(id)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Event{}, false, fmt.Errorf("reading channel %s name: %w", id, err)
	}
	return Event{Type: slackNewMessages, Fields: map[string]any{
		"account": l.account, "channel": name, "channel_id": id, "count": count,
	}}, true, nil
}

// accountLabels reads an account's labels once per diff.
func (s slackDiff) accountLabels(acct int64, cache map[int64]slackAccountLabels) (slackAccountLabels, error) {
	if l, ok := cache[acct]; ok {
		return l, nil
	}
	account, owner, err := s.d.SlackEventLabels(acct)
	if err != nil {
		return slackAccountLabels{}, err
	}
	l := slackAccountLabels{account: account, owner: owner}
	cache[acct] = l
	return l, nil
}
