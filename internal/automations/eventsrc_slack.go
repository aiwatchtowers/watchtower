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
// channel whose newest stored message moved forward during the phase,
// counting the non-deleted messages newer than the channel's newest before
// the phase that the owner did not write. It diffs the messages table itself
// — the default search sync writes no sync_state. A channel with no stored
// message before the phase publishes nothing (its history is a backfill, not
// news), and a message older than the channel's newest before the phase
// (a history backfill, a thread fill) is never counted.
func SlackSource(d *db.DB) EventSource { return slackSource{d: d} }

type slackSource struct{ d *db.DB }

func (slackSource) Type() string { return slackNewMessages }

func (s slackSource) Before(ctx context.Context) (EventDiff, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("snapshotting slack messages: %w", err)
	}
	newest, err := s.d.SlackChannelNewestTS()
	if err != nil {
		return nil, fmt.Errorf("snapshotting slack messages: %w", err)
	}
	return slackDiff{d: s.d, before: newest}, nil
}

type slackDiff struct {
	d      *db.DB
	before map[string]string // channel id → newest stored ts
}

// slackAccountLabels is one account's event label and owner user id.
type slackAccountLabels struct{ account, owner string }

func (s slackDiff) After(ctx context.Context) ([]Event, error) {
	after, err := s.d.SlackChannelNewestTS()
	if err != nil {
		return nil, fmt.Errorf("reading slack messages: %w", err)
	}
	labels := map[int64]slackAccountLabels{}
	var events []Event
	for _, id := range advancedChannels(s.before, after) {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("diffing slack messages: %w", err)
		}
		e, ok, err := s.channelEvent(id, s.before[id], labels)
		if err != nil {
			return nil, err
		}
		if ok {
			events = append(events, e)
		}
	}
	return events, nil
}

// advancedChannels returns, sorted, the channels that held messages before
// the phase and whose newest message moved forward.
func advancedChannels(before, after map[string]string) []string {
	var ids []string
	for id, a := range after {
		if b, ok := before[id]; ok && a > b {
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
