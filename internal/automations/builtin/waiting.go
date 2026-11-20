package builtin

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
)

// SlotWaitingForMe is Waiting for me's slot, right after the attention
// detector (phaseInbox); Mail waiting runs at it right after Waiting for me.
const SlotWaitingForMe Slot = "waiting_for_me"

// MailWaitingID is Mail waiting's built-in id: the open mail of
// attention.waiting's senders, one row per sender.
const MailWaitingID = "mail-waiting"

// attention.waiting's read limits.
const (
	// WaitingPeopleLimit is how many open people items (every feed trigger
	// but email_received) attention.waiting returns in items, the Desktop's
	// InboxQueries.openMessageLimit.
	WaitingPeopleLimit = 200
	// WaitingMailLimit is how many open mail items it returns in mail_items.
	WaitingMailLimit = 200
	// WaitingSendersLimit is how many mail senders it returns in senders.
	WaitingSendersLimit = 200
	// WaitingTextRunes caps an item's text.
	WaitingTextRunes = 300
	// waitingNameRunes caps an item's who and where, so "<who> in <where>"
	// stays within a list row's title.
	waitingNameRunes = 120
	// The byte budgets bound the JSON size of each list's rows together:
	// every row gets an even share of its list's budget, and its longest
	// string (an item's text, a sender's subject) gets what the row's other
	// fields leave of it. Together with the counts they keep the result
	// under automations.MaxSDKResultBytes, and the people rows a recipe
	// shows under the block document's cap (blocks.MaxBlocksBytes).
	waitingPeopleBudgetBytes  = 90 << 10
	waitingMailBudgetBytes    = 40 << 10
	waitingSendersBudgetBytes = 80 << 10
	// waitingRowOverhead is an item row's JSON besides its strings and its
	// stamp: the keys, the numbers, kind, section and trigger — more than
	// a list row's keys, badge, tone, ref and the title's joiner.
	waitingRowOverhead = 220
)

// ReadPrimitives are the built-ins' read primitives
// (automations.ReadPrimitiveNames and automations.WindowPrimitiveNames) over
// d: what every executor and dry run carries, since a dry run calls them.
func ReadPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	out := WaitingPrimitives(d, now)
	maps.Copy(out, ApprovalsPrimitives(d, now))
	maps.Copy(out, SlackWindowPrimitives(d, now))
	return out
}

// WaitingPrimitives returns attention.waiting over d. It returns
// {status: "done", items, mail_items, people, mail, senders}:
//   - items: the open people items (db.WaitingPeople, newest first, at most
//     WaitingPeopleLimit) and mail_items: the open mail of unmuted senders
//     (db.WaitingMail, at most WaitingMailLimit), each row {id, kind, section,
//     who, where, text, trigger, permalink, at, age, age_hours, count,
//     count_label}. Mail is never in items, so a recipe written before the
//     split never gets a mail row or more than 200 rows.
//   - people: {open, today, week, older} over every open people item.
//   - mail: {open, today, senders, top_ten_share} over the unmuted mail.
//   - senders: the busiest unmuted senders (at most WaitingSendersLimit),
//     {address, actionable, open, today, subject, at, permalink}.
//
// It reads only and calls no model. now is the clock the open check, the
// ages and the sections use; a section is placed in now's location (the
// daemon's local zone).
func WaitingPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc {
	return map[string]automations.PrimitiveFunc{
		automations.PrimitiveAttentionWaiting: func(ctx context.Context, _ automations.PrimitiveCall) (automations.PrimitiveResult, error) {
			if d == nil {
				return automations.PrimitiveResult{}, errNotWired
			}
			at := now()
			people, counts, err := waitingPeople(ctx, d, at)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			mail, err := d.OpenInboxItemsOfKind(ctx, at, db.WaitingMail, WaitingMailLimit)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			mailItems, err := waitingItems(d, mail, at, waitingMailBudgetBytes)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			senders, mailCounts, err := waitingSenders(ctx, d, at)
			if err != nil {
				return automations.PrimitiveResult{}, err
			}
			return automations.PrimitiveResult{Status: "done", Fields: map[string]any{
				"items": people, "mail_items": mailItems, "people": counts,
				"mail": mailCounts, "senders": senders,
			}}, nil
		},
	}
}

// waitingPeople is attention.waiting's items and people at now.
func waitingPeople(ctx context.Context, d *db.DB, now time.Time) ([]any, map[string]any, error) {
	open, err := d.OpenInboxItemsOfKind(ctx, now, db.WaitingPeople, WaitingPeopleLimit)
	if err != nil {
		return nil, nil, err
	}
	items, err := waitingItems(d, open, now, waitingPeopleBudgetBytes)
	if err != nil {
		return nil, nil, err
	}
	c, err := d.OpenPeopleCounts(ctx, now)
	if err != nil {
		return nil, nil, err
	}
	return items, map[string]any{"open": c.Open, "today": c.Today, "week": c.Week, "older": c.Older}, nil
}

// waitingSenders is attention.waiting's senders and mail at now.
func waitingSenders(ctx context.Context, d *db.DB, now time.Time) ([]any, map[string]any, error) {
	w, err := d.OpenMailSenders(ctx, now, WaitingSendersLimit)
	if err != nil {
		return nil, nil, err
	}
	// A hard budget, measured as the executor marshals the result: each row
	// gets an even share of what the list's brackets and commas leave.
	share := (waitingSendersBudgetBytes-2)/max(len(w.Senders), 1) - 1
	senders := make([]any, 0, len(w.Senders))
	for _, s := range w.Senders {
		actionable := blocks.ValidSenderAddress(s.Address)
		addr := s.Address
		if !actionable {
			// Only an actionable address is a ref, never clipped: at most
			// 254 bytes that JSON never escapes. Any other is display text.
			addr = clipJSON(addr, share/4)
		}
		link := webLink(s.Permalink)
		if jsonLen(link) > share/4 {
			link = ""
		}
		row := map[string]any{
			"address":    addr,
			"actionable": actionable,
			"open":       s.Open,
			"today":      s.Today,
			"subject":    "",
			"at":         s.At,
			"permalink":  link,
		}
		if jsonSize(row) > share {
			row["permalink"] = ""
		}
		// The empty subject's quotes are already in the row's size.
		left := share - jsonSize(row) + jsonLen("")
		row["subject"] = clipJSON(clipRunes(strings.Join(strings.Fields(s.Subject), " "), WaitingTextRunes), left)
		senders = append(senders, row)
	}
	mail := map[string]any{"open": w.Open, "today": w.Today, "senders": w.SenderCount, "top_ten_share": w.TopTenShare}
	return senders, mail, nil
}

// WaitingFingerprint hashes what attention.waiting returns at now for kind,
// as the rows show it. People: every people item's fields but its exact
// stamp and hours, with whether its row is past 24 hours instead, its
// section, and the people counts. Mail: the senders and the mail counts.
// Equal fingerprints mean the shipped recipe of that kind would write the
// same artifact, so a quiet cycle can skip the run.
func WaitingFingerprint(ctx context.Context, d *db.DB, now time.Time, kind db.WaitingKind) (string, error) {
	var shown any
	switch kind {
	case db.WaitingPeople:
		items, counts, err := waitingPeople(ctx, d, now)
		if err != nil {
			return "", err
		}
		rows := make([]map[string]any, 0, len(items))
		for _, it := range items {
			m := it.(map[string]any)
			rows = append(rows, map[string]any{"id": m["id"], "who": m["who"], "where": m["where"], "text": m["text"],
				"trigger": m["trigger"], "permalink": m["permalink"], "age": m["age"], "warning": m["age_hours"].(int) >= 24,
				"count": m["count"], "count_label": m["count_label"], "section": m["section"]})
		}
		shown = map[string]any{"items": rows, "people": counts}
	case db.WaitingMail:
		senders, counts, err := waitingSenders(ctx, d, now)
		if err != nil {
			return "", err
		}
		shown = map[string]any{"senders": senders, "mail": counts}
	default:
		return "", fmt.Errorf("unknown waiting kind %q", kind)
	}
	data, err := json.Marshal(shown)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

// waitingItems is the script's view of open within budget bytes: who and
// where as the Desktop's HomeFeedQueries.who / whereText word them, the
// item's kind and its section at now.
func waitingItems(d *db.DB, open []db.OpenInboxItem, now time.Time, budget int) ([]any, error) {
	var raws []string
	for _, o := range open {
		raws = append(raws, o.Mentions)
	}
	names, err := d.InboxMentionSenderNames(raws...)
	if err != nil {
		return nil, err
	}
	items := make([]any, 0, len(open))
	share := budget / max(len(open), 1)
	for _, o := range open {
		mentions, _ := db.ParseInboxMentions(o.Mentions)
		count := len(mentions) + o.MentionsEarlier
		label := ""
		if count > 1 {
			label = db.InboxMentionCountLabel(mentions, o.MentionsEarlier)
		} else {
			count = 1
		}
		who := waitingWho(o, count > 1, mentions, names)
		at := parseStamp(o.At)
		hours := 0
		if !at.IsZero() && now.After(at) {
			hours = int(now.Sub(at) / time.Hour)
		}
		age := ageText(at, now)
		who = clipJSON(clipRunes(who, waitingNameRunes), share/4)
		where := clipJSON(clipRunes(waitingWhere(o), waitingNameRunes), share/4)
		link := webLink(o.Permalink)
		if jsonLen(link) > share/4 {
			link = ""
		}
		left := share - waitingRowOverhead - jsonLen(o.At) - jsonLen(who) - jsonLen(where) - jsonLen(link) - jsonLen(label) - jsonLen(age)
		text := clipJSON(clipRunes(strings.Join(strings.Fields(o.Snippet), " "), WaitingTextRunes), left)
		items = append(items, map[string]any{
			"id":          int64(o.ID),
			"kind":        string(db.WaitingKindOf(o.TriggerType)),
			"section":     string(db.WaitingSectionOf(at, now)),
			"who":         who,
			"where":       where,
			"text":        text,
			"trigger":     o.TriggerType,
			"permalink":   link,
			"at":          o.At,
			"age":         age,
			"age_hours":   hours,
			"count":       count,
			"count_label": label,
		})
	}
	return items, nil
}

// waitingWho is the item's sender, in HomeFeedQueries.who's order: the
// issue key for Jira and Linear, the address for mail, a folded item's
// senders, else the Slack user's name.
func waitingWho(o db.OpenInboxItem, folded bool, mentions []db.InboxMention, names map[string]string) string {
	switch t := o.TriggerType; {
	case strings.HasPrefix(t, "jira_"), strings.HasPrefix(t, "linear_"):
		return o.ChannelID
	case t == "email_received":
		return o.SenderUserID
	case folded:
		return db.InboxMentionSenders(mentions, names)
	}
	return o.SenderName
}

// waitingWhere is where the item happened: "assigned to you" or "mentioned
// you" for a tracker, the subject for mail, "a DM" or "#channel" for Slack
// ("" for an unknown channel).
func waitingWhere(o db.OpenInboxItem) string {
	switch o.TriggerType {
	case "jira_assigned", "linear_assigned":
		return "assigned to you"
	case "jira_comment_mention", "linear_comment_mention":
		return "mentioned you"
	case "email_received":
		return db.MailSubject(o.Snippet)
	case "dm":
		return "a DM"
	}
	if o.ChannelName == "" {
		return ""
	}
	return "#" + o.ChannelName
}

// webLink is raw when the blocks admit it as a row's link (blocks.CheckURL:
// a link with a host, at most MaxLinkBytes) and it is a web link (http or
// https, any case), else "": a row with a link the blocks would refuse would
// fail the whole run, and a source permalink is never an in-app
// watchtower-nav:// jump.
func webLink(raw string) string {
	link, err := blocks.CheckURL("waiting", "link", raw)
	if err != nil {
		return ""
	}
	lower := strings.ToLower(link)
	if !strings.HasPrefix(lower, "https://") && !strings.HasPrefix(lower, "http://") {
		return ""
	}
	return link
}

// ageText is how long ago at was, coarse so the artifact changes at most
// once an hour (a living rewrite with a new content hash clears the card's
// read state): "< 1 h", "3 h", "26 h", "2 days" (from 48 hours); "" for an
// unknown at (no badge).
func ageText(at, now time.Time) string {
	switch d := now.Sub(at); {
	case at.IsZero():
		return ""
	case d < time.Hour:
		return "< 1 h"
	case d < 48*time.Hour:
		return fmt.Sprintf("%d h", int(d/time.Hour))
	default:
		return fmt.Sprintf("%d days", int(d/(24*time.Hour)))
	}
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

// jsonLen is s's length as a JSON string (quotes and escapes included).
func jsonLen(s string) int {
	data, _ := json.Marshal(s) // a string always marshals
	return len(data)
}

// jsonSize is v's length as JSON, as the executor marshals a result.
func jsonSize(v any) int {
	data, _ := json.Marshal(v) // the rows hold strings, numbers and booleans only
	return len(data)
}

// clipJSON is s cut on a rune boundary, an ellipsis marking the cut, so its
// JSON length is at most maxBytes ("" when nothing fits).
func clipJSON(s string, maxBytes int) string {
	if jsonLen(s) <= maxBytes {
		return s
	}
	r := []rune(s)
	lo, hi := 0, len(r) // the longest prefix that fits lies in [lo, hi)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if jsonLen(string(r[:mid])+"…") <= maxBytes {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	if lo == 0 {
		return ""
	}
	return string(r[:lo]) + "…"
}
