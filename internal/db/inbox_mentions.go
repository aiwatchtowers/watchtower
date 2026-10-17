package db

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Channel-level inbox items (board #586): Slack messages outside threads in
// one channel fold into one item whose inbox_items.mentions lists them.
const (
	// InboxMentionsKeep is how many of the newest messages the list keeps;
	// older ones are only counted in mentions_earlier.
	InboxMentionsKeep = 20
	// InboxMentionTextRunes is the one truncation length of an entry's text.
	InboxMentionTextRunes = 300
)

// notListedInMentions is the detectors' second dedupe clause (alias m =
// messages): a message already listed in any inbox item's mentions for its
// channel — pending, resolved or dismissed — is not news. A malformed list
// reads as empty instead of failing the detector.
const notListedInMentions = `NOT EXISTS (
			SELECT 1 FROM inbox_items il,
				json_each(CASE WHEN json_valid(il.mentions) THEN il.mentions ELSE '[]' END) je
			WHERE il.channel_id = m.channel_id AND il.mentions <> '[]'
			  AND json_extract(je.value, '$.ts') = m.ts
		)`

// InboxMention is one message folded into a channel-level Slack inbox item.
type InboxMention struct {
	TS        string `json:"ts"`
	SenderID  string `json:"sender"`
	Trigger   string `json:"trigger"` // the candidate's trigger_type: mention, dm, reaction
	Text      string `json:"text"`
	Permalink string `json:"permalink,omitempty"`
}

// PackInboxMentions dedupes list by ts (first wins), orders it oldest first,
// truncates every text to InboxMentionTextRunes and keeps the
// InboxMentionsKeep newest. It returns the JSON for inbox_items.mentions and
// how many entries fell off.
func PackInboxMentions(list []InboxMention) (string, int) {
	seen := make(map[string]bool, len(list))
	out := make([]InboxMention, 0, len(list))
	for _, m := range list {
		if seen[m.TS] {
			continue
		}
		seen[m.TS] = true
		m.Text = truncateMentionText(m.Text)
		out = append(out, m)
	}
	sort.SliceStable(out, func(i, j int) bool { return slackTSLess(out[i].TS, out[j].TS) })
	dropped := 0
	if len(out) > InboxMentionsKeep {
		dropped = len(out) - InboxMentionsKeep
		out = out[dropped:]
	}
	data, _ := json.Marshal(out) // plain strings: cannot fail
	return string(data), dropped
}

// ParseInboxMentions decodes inbox_items.mentions; ok is false for a
// malformed value.
func ParseInboxMentions(raw string) (list []InboxMention, ok bool) {
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		return nil, false
	}
	return list, true
}

// InboxMentionCountLabel is the item's count wording, shared with the Desktop
// (InboxItem.mentionCountTitle): "3 mentions" when every listed entry is a
// mention, otherwise "3 messages". The count includes the earlier ones.
func InboxMentionCountLabel(list []InboxMention, earlier int) string {
	word := "mentions"
	for _, m := range list {
		if m.Trigger != "mention" {
			word = "messages"
			break
		}
	}
	return fmt.Sprintf("%d %s", len(list)+earlier, word)
}

// InboxMentionLines renders an item's list for an AI prompt, oldest first:
// "<sender name>: <text>" per entry and "(+N earlier)" when some fell off.
// Nil when the item lists fewer than two messages.
func (db *DB) InboxMentionLines(raw string, earlier int) []string {
	list, ok := ParseInboxMentions(raw)
	if !ok || len(list)+earlier < 2 {
		return nil
	}
	lines := make([]string, 0, len(list)+1)
	if earlier > 0 {
		lines = append(lines, fmt.Sprintf("(+%d earlier)", earlier))
	}
	for _, m := range list {
		name, err := db.UserNameByID(m.SenderID)
		if err != nil || name == "" {
			name = m.SenderID
		}
		lines = append(lines, name+": "+strings.Join(strings.Fields(m.Text), " "))
	}
	return lines
}

// AppendInboxMentions folds newer messages into a pending channel-level item
// without losing the ones already there. A row written before the column
// existed — or one whose list is malformed (logged) — is seeded with its own
// message first; a ts already listed is skipped, and while older entries have
// fallen off, so is anything older than the oldest kept one (it was counted
// already). Only when the list actually grows does the row change: the list,
// mentions_earlier, mentioned_at = now, read_at cleared, and — when latest is
// newer than the row's own message — its message_ts/sender/snippet/context/
// raw_text/permalink. grew reports whether anything was written.
func (db *DB) AppendInboxMentions(id int, latest InboxItem, add []InboxMention) (grew bool, err error) {
	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("appending mentions to inbox item %d: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }()

	var raw, messageTS, sender, trigger, snippet, permalink string
	var earlier int
	if err := tx.QueryRow(`SELECT mentions, mentions_earlier, message_ts, sender_user_id, trigger_type, snippet, permalink
		FROM inbox_items WHERE id = ?`, id).Scan(&raw, &earlier, &messageTS, &sender, &trigger, &snippet, &permalink); err != nil {
		return false, fmt.Errorf("reading mentions of inbox item %d: %w", id, err)
	}
	list, ok := ParseInboxMentions(raw)
	if !ok {
		log.Printf("inbox: item %d has malformed mentions %q, reseeding from the row", id, raw)
		list, earlier = nil, 0
	}
	if len(list) == 0 {
		list = []InboxMention{{TS: messageTS, SenderID: sender, Trigger: trigger, Text: snippet, Permalink: permalink}}
	}
	seen := make(map[string]bool, len(list))
	for _, m := range list {
		seen[m.TS] = true
	}
	oldest := list[0].TS
	for _, m := range list[1:] {
		if slackTSLess(m.TS, oldest) {
			oldest = m.TS
		}
	}
	added := 0
	for _, m := range add {
		if seen[m.TS] || (earlier > 0 && slackTSLess(m.TS, oldest)) {
			continue
		}
		seen[m.TS] = true
		list = append(list, m)
		added++
	}
	if added == 0 {
		return false, nil
	}
	packed, dropped := PackInboxMentions(list)
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")

	if slackTSLess(messageTS, latest.MessageTS) {
		_, err = tx.Exec(`UPDATE inbox_items SET mentions = ?, mentions_earlier = ?, mentioned_at = ?,
			message_ts = ?, sender_user_id = ?, snippet = ?, context = ?, raw_text = ?, permalink = ?,
			ai_reason = '', read_at = NULL, updated_at = ?
			WHERE id = ?`,
			packed, earlier+dropped, now, latest.MessageTS, latest.SenderUserID, latest.Snippet,
			latest.Context, latest.RawText, latest.Permalink, now, id)
	} else {
		_, err = tx.Exec(`UPDATE inbox_items SET mentions = ?, mentions_earlier = ?, mentioned_at = ?,
			read_at = NULL, updated_at = ?
			WHERE id = ?`, packed, earlier+dropped, now, now, id)
	}
	if err != nil {
		return false, fmt.Errorf("updating mentions of inbox item %d: %w", id, err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("committing mentions of inbox item %d: %w", id, err)
	}
	return true, nil
}

func truncateMentionText(s string) string {
	if utf8.RuneCountInString(s) <= InboxMentionTextRunes {
		return s
	}
	r := []rune(s)
	return string(r[:InboxMentionTextRunes]) + "…"
}

// slackTSLess orders Slack message timestamps ("1700000000.000100")
// numerically; an unparsable ts sorts by its text.
func slackTSLess(a, b string) bool {
	fa, errA := strconv.ParseFloat(a, 64)
	fb, errB := strconv.ParseFloat(b, 64)
	if errA != nil || errB != nil {
		return a < b
	}
	return fa < fb
}
