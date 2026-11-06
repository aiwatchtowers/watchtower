package builtin

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// SlotWaitingForMe is Waiting for me's slot, right after the attention
// detector (phaseInbox).
const SlotWaitingForMe Slot = "waiting_for_me"

// Waiting for me's read limits.
const (
	// WaitingLimit is how many open items attention.waiting returns, the
	// Desktop's InboxQueries.openMessageLimit.
	WaitingLimit = 200
	// WaitingTextRunes caps an item's text.
	WaitingTextRunes = 300
	// waitingNameRunes caps an item's who and where, so "<who> in <where>"
	// stays within a list row's title.
	waitingNameRunes = 120
)

// ReadPrimitives are the built-ins' read primitives
// (automations.ReadPrimitiveNames) over d: what every executor and dry run
// carries, since a dry run calls them.
func ReadPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	return WaitingPrimitives(d, now)
}

// WaitingPrimitives returns attention.waiting over d: the open attention
// items (db.OpenInboxItems, newest first, at most WaitingLimit) as
// {status: "done", items: [{id, who, where, text, trigger, permalink, at,
// age, age_hours, count, count_label}]}. It reads only and calls no model.
// now is the clock the open check and the ages use.
func WaitingPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		automations.PrimitiveAttentionWaiting: func(ctx context.Context, _ automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if d == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			at := now()
			open, err := d.OpenInboxItems(ctx, at, WaitingLimit)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			items, err := waitingItems(d, open, at)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			return automations.PrimitiveResult{Status: "done", Fields: map[string]any{"items": items}}, nil
		},
	}
}

// waitingItems is the script's view of open: who and where as the Desktop's
// HomeFeedQueries.who / whereText word them.
func waitingItems(d *db.DB, open []db.OpenInboxItem, now time.Time) ([]any, error) {
	var raws []string
	for _, o := range open {
		raws = append(raws, o.Mentions)
	}
	names, err := d.InboxMentionSenderNames(raws...)
	if err != nil {
		return nil, err
	}
	items := make([]any, 0, len(open))
	for _, o := range open {
		mentions, _ := db.ParseInboxMentions(o.Mentions)
		count := len(mentions) + o.MentionsEarlier
		who, label := waitingWho(o), ""
		if count > 1 {
			who = db.InboxMentionSenders(mentions, names)
			label = db.InboxMentionCountLabel(mentions, o.MentionsEarlier)
		} else {
			count = 1
		}
		at := parseStamp(o.At)
		hours := 0
		if !at.IsZero() && now.After(at) {
			hours = int(now.Sub(at) / time.Hour)
		}
		items = append(items, map[string]any{
			"id":          int64(o.ID),
			"who":         clipRunes(who, waitingNameRunes),
			"where":       clipRunes(waitingWhere(o), waitingNameRunes),
			"text":        clipRunes(strings.Join(strings.Fields(o.Snippet), " "), WaitingTextRunes),
			"trigger":     o.TriggerType,
			"permalink":   webLink(o.Permalink),
			"at":          o.At,
			"age":         ageText(at, now),
			"age_hours":   hours,
			"count":       count,
			"count_label": label,
		})
	}
	return items, nil
}

// waitingWho is a single item's sender: the issue key for Jira and Linear,
// the address for mail, else the Slack user's name.
func waitingWho(o db.OpenInboxItem) string {
	switch t := o.TriggerType; {
	case strings.HasPrefix(t, "jira_"), strings.HasPrefix(t, "linear_"):
		return o.ChannelID
	case t == "email_received":
		return o.SenderUserID
	}
	return o.SenderName
}

// waitingWhere is where the item happened: "assigned to you" or "mentioned
// you" for a tracker, the subject for mail, "#channel" for Slack ("" for a
// DM or an unknown channel).
func waitingWhere(o db.OpenInboxItem) string {
	switch o.TriggerType {
	case "jira_assigned", "linear_assigned":
		return "assigned to you"
	case "jira_comment_mention", "linear_comment_mention":
		return "mentioned you"
	case "email_received":
		subject, _, _ := strings.Cut(o.Snippet, " — ")
		return subject
	case "dm":
		return ""
	}
	if o.ChannelName == "" {
		return ""
	}
	return "#" + o.ChannelName
}

// webLink is raw when it is an http(s) link with a host that fits a row's
// link, else "": a row with a link the blocks would refuse would fail the
// whole run.
func webLink(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(raw) > 2048 {
		return ""
	}
	return raw
}

// ageText is how long ago at was, in its largest unit: "now", "5m", "3h",
// "2d".
func ageText(at, now time.Time) string {
	d := now.Sub(at)
	switch {
	case at.IsZero() || d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d/time.Hour))
	}
	return fmt.Sprintf("%dd", int(d/(24*time.Hour)))
}

// parseStamp reads an RFC 3339 stamp (zero when it is not one).
func parseStamp(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// clipRunes is s cut to at most n runes, an ellipsis marking the cut.
func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
