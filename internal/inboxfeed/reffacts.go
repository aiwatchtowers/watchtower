package inboxfeed

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// refState is what one read found about the records the list rows point
// at (InboxRefState, InboxReplyPolicy): which are shown, which wait on the
// owner, and an inbox item's Reply and link.
type refState struct {
	// shown: the row is drawn. waits: it waits on the owner (counted). A
	// deleted record is neither.
	shown, waits map[ref]bool
	// reply: the inbox item has a Reply (InboxReplyPolicy.tool(for:)).
	reply map[int64]bool
	// replyWaiting: a Reply to the inbox item is open (pending, approved or
	// executing; InboxReplyPolicy.isOpenReply).
	replyWaiting map[int64]bool
	// links are an inbox item's permalink and a reminder's Slack message.
	links map[ref]string
	// rows are the facts the Mac's row buttons read: an inbox item's
	// trigger, a track's custom origin and linked target, an idea's kind
	// and status.
	rows map[ref]api.RefFacts
}

// readRefState reads refs' records at now: one query per kind present.
// Shown and waits agree for every kind but an idea, which is shown while
// not merged, superseded or snoozed, and waits while shown and awaiting a
// verdict.
func readRefState(ctx context.Context, tx *sql.Tx, refs []ref, now time.Time) (refState, error) {
	st := refState{shown: map[ref]bool{}, waits: map[ref]bool{}, reply: map[int64]bool{},
		replyWaiting: map[int64]bool{}, links: map[ref]string{}, rows: map[ref]api.RefFacts{}}
	ids := map[api.RefKind][]int64{}
	seen := map[ref]bool{}
	for _, r := range refs {
		if !seen[r] {
			seen[r] = true
			ids[r.Kind] = append(ids[r.Kind], r.ID)
		}
	}
	nowUTC := now.UTC().Format(stampLayout)
	for kind, list := range ids {
		args := make([]any, 0, len(list)+2)
		for _, id := range list {
			args = append(args, id)
		}
		marks := strings.TrimSuffix(strings.Repeat("?,", len(list)), ",")
		var query string
		switch kind {
		case api.RefInboxItem:
			query = `SELECT id, ` + db.OpenInboxClause() + `, trigger_type, permalink, channel_id
				FROM inbox_items WHERE id IN (` + marks + `)`
			args = append([]any{nowUTC}, args...)
		case api.RefTrack:
			query = `SELECT id, dismissed_at = '' AND read_at IS NULL, origin = 'custom', COALESCE(linked_target_id, 0)
				FROM tracks WHERE id IN (` + marks + `)`
		case api.RefReminder:
			query = `SELECT id, status = 'pending' AND remind_at <= ?, message_ref FROM reminders WHERE id IN (` + marks + `)`
			args = append([]any{nowUTC}, args...)
		case api.RefAction:
			query = `SELECT id, ` + db.AwaitingOwnerClause + ` FROM agent_actions WHERE id IN (` + marks + `)`
		case api.RefIdea:
			query = `SELECT id, status NOT IN ('merged', 'superseded') AND NOT ` + ideaSnoozedClause + `,
				(status = 'proposed' OR needs_review = 1) AND (kind != 'decision' OR chat_born = 1), kind, status
				FROM ideas WHERE id IN (` + marks + `)`
			args = append([]any{now.Format("2006-01-02"), nowUTC}, args...)
		default:
			continue
		}
		err := eachRow(ctx, tx, query, args, func(rows *sql.Rows) error {
			return st.scan(kind, rows)
		})
		if err != nil {
			return st, fmt.Errorf("inboxfeed: reading %s refs: %w", kind, err)
		}
	}
	if len(ids[api.RefInboxItem]) > 0 {
		if err := readOpenReplies(ctx, tx, st.replyWaiting); err != nil {
			return st, err
		}
	}
	return st, nil
}

// scan reads one row of kind's query into the state.
func (st refState) scan(kind api.RefKind, rows *sql.Rows) error {
	var id int64
	var open bool
	r := ref{Kind: kind, ID: id}
	switch kind {
	case api.RefInboxItem:
		var trigger, permalink, channel string
		if err := rows.Scan(&id, &open, &trigger, &permalink, &channel); err != nil {
			return err
		}
		r.ID = id
		st.reply[id] = replyTool(trigger, permalink, channel) != ""
		st.links[r] = permalink
		st.rows[r] = api.RefFacts{TriggerType: trigger}
	case api.RefReminder:
		var message string
		if err := rows.Scan(&id, &open, &message); err != nil {
			return err
		}
		r.ID = id
		st.links[r] = slackMessageURL(message)
	case api.RefTrack:
		var custom bool
		var target int64
		if err := rows.Scan(&id, &open, &custom, &target); err != nil {
			return err
		}
		r.ID = id
		st.rows[r] = api.RefFacts{Custom: custom, LinkedTargetID: target}
	case api.RefIdea:
		var verdict bool
		var ideaKind, status string
		if err := rows.Scan(&id, &open, &verdict, &ideaKind, &status); err != nil {
			return err
		}
		r.ID = id
		st.rows[r] = api.RefFacts{IdeaKind: ideaKind, IdeaStatus: status}
		st.shown[r] = open
		st.waits[r] = open && verdict
		return nil
	default:
		if err := rows.Scan(&id, &open); err != nil {
			return err
		}
		r.ID = id
	}
	st.shown[r], st.waits[r] = open, open
	return nil
}

// readOpenReplies marks the inbox items with a Reply open: a proposal of a
// reply tool in their context, pending, approved or executing (the one-open-
// reply rule of db.InsertInboxReplyProposal).
func readOpenReplies(ctx context.Context, tx *sql.Tx, out map[int64]bool) error {
	replyTools := db.InboxReplyToolNames()
	args := []any{db.InboxItemContextType}
	for _, t := range replyTools {
		args = append(args, t)
	}
	err := eachRow(ctx, tx, `SELECT context_id FROM agent_actions WHERE context_type = ?
		AND status IN ('pending','approved','executing')
		AND tool IN (`+strings.TrimSuffix(strings.Repeat("?,", len(replyTools)), ",")+`)`,
		args, func(rows *sql.Rows) error {
			var ctxID string
			if err := rows.Scan(&ctxID); err != nil {
				return err
			}
			if id, err := strconv.ParseInt(ctxID, 10, 64); err == nil {
				out[id] = true
			}
			return nil
		})
	if err != nil {
		return fmt.Errorf("inboxfeed: reading the open replies: %w", err)
	}
	return nil
}

// replyTool is InboxReplyPolicy.tool(for:): the write a Reply from an
// inbox item proposes — Slack's four triggers with a permalink, Jira's and
// Linear's two with an issue key; "" for none (mail, any other trigger).
func replyTool(trigger, permalink, channelID string) string {
	switch trigger {
	case "mention", "dm", "thread_reply", "reaction":
		if permalink != "" {
			return "send_slack_message"
		}
	case "jira_assigned", "jira_comment_mention":
		if channelID != "" {
			return "add_jira_comment"
		}
	case "linear_assigned", "linear_comment_mention":
		if channelID != "" {
			return "add_linear_comment"
		}
	}
	return ""
}

// refFacts are a document's row refs as the feed sends them, each once,
// in document order: shown (open), waits, Reply, link and the row buttons'
// facts. Closed refs stay
// listed; the screen models hide their rows by Open.
func (st refState) refFacts(refs []ref) []api.RefFacts {
	out := []api.RefFacts{}
	seen := map[ref]bool{}
	for _, r := range refs {
		if seen[r] {
			continue
		}
		seen[r] = true
		f := st.rows[r]
		f.Kind, f.ID, f.Open, f.Waits, f.Link = r.Kind, r.ID, st.shown[r], st.waits[r], st.links[r]
		if r.Kind == api.RefInboxItem {
			f.Reply, f.ReplyWaiting = st.reply[r.ID], st.replyWaiting[r.ID]
		}
		out = append(out, f)
	}
	return out
}
