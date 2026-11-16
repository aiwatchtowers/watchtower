package inboxfeed

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The built-ins whose rows shape the feed (builtin.Entry ids).
const (
	waitingForMeBuiltinID  = "waiting-for-me"
	needsApprovalBuiltinID = "needs-approval"
)

// openMessageLimit is how many open messages the Messages entry lists and
// counts (InboxQueries.openMessageLimit).
const openMessageLimit = 200

// awaitingOwnerClause is the Desktop's AgentActionQueries.awaitingOwnerClause:
// the agent_actions rows that wait on the owner — pending or failed, never a
// workbench's direct-apply audit row unless external, never an Inbox
// button's one-press row, never a failed session-applied call except an
// unknown outcome the owner has not dismissed yet.
const awaitingOwnerClause = `status IN ('pending','failed')
	AND ((context_type IS NOT 'project' OR external = 1) AND NOT (surface = 'inbox' AND tool = 'apply_track_action'))
	AND NOT (status = 'failed' AND tool = 'claude_ai_connector_call'
		AND NOT (error = 'session ended while the call ran; outcome unknown' AND dismissed_at = ''))`

// counts is each folder's own count (InboxFolderCounts.counts): its legacy
// count, plus, outside Needs approval, each artifact's share.
func counts(t tree, artifacts map[int64][]output, refs map[int64][]ref, waits map[ref]bool, legacy map[int64]int) map[int64]int {
	out := map[int64]int{}
	for _, f := range t.folders {
		n := legacy[f.ID]
		if f.Kind != api.FolderApprovals {
			for _, o := range artifacts[f.ID] {
				n += artifactCount(o, refs[o.ID], waits)
			}
		}
		out[f.ID] = n
	}
	return out
}

// artifactCount is one artifact's share of its folder's count: 1 while
// unread when its document has no row ref, else its rows that wait on the
// owner, whatever its read state.
func artifactCount(o output, refs []ref, waits map[ref]bool) int {
	if len(refs) == 0 {
		if o.Unread {
			return 1
		}
		return 0
	}
	return waitingRows(refs, waits)
}

// waitingRows counts the refs that wait on the owner.
func waitingRows(refs []ref, waits map[ref]bool) int {
	n := 0
	for _, r := range refs {
		if waits[r] {
			n++
		}
	}
	return n
}

// legacyCounts are the badge's terms from before the folders, by the folder
// that shows them now (ActionStripViewModel.legacyCounts): Needs approval
// (the root on a tree without it) counts the actions that wait on the
// owner, the due reminders and the built-in upgrade notices; the root counts
// the ideas awaiting a verdict, the unread open messages while the Messages
// entry stands in for Waiting for me, and 1 while the latest briefing is
// unread.
func legacyCounts(ctx context.Context, tx *sql.Tx, t tree, now time.Time, messagesStandIn bool, notices int) (map[int64]int, error) {
	nowUTC := now.UTC().Format(stampLayout)
	queries := []struct {
		name string
		sql  string
		args []any
		root bool
	}{
		{"actions", `SELECT COUNT(*) FROM agent_actions WHERE ` + awaitingOwnerClause, nil, false},
		{"reminders", `SELECT COUNT(*) FROM reminders WHERE status = 'pending' AND remind_at <= ?`, []any{nowUTC}, false},
		{"ideas", `SELECT COUNT(*) FROM ideas WHERE (status = 'proposed' OR needs_review = 1)
			AND (kind != 'decision' OR chat_born = 1)`, nil, true},
		{"briefing", `SELECT COUNT(*) FROM (SELECT read_at FROM briefings ORDER BY created_at DESC, id DESC LIMIT 1)
			WHERE read_at IS NULL OR read_at = ''`, nil, true},
	}
	if messagesStandIn {
		queries = append(queries, struct {
			name string
			sql  string
			args []any
			root bool
		}{"messages", `SELECT COUNT(*) FROM (SELECT read_at FROM inbox_items WHERE ` + db.OpenInboxClause() + `
			ORDER BY MAX(created_at, mentioned_at) DESC, id DESC LIMIT ?) WHERE read_at IS NULL OR read_at = ''`,
			[]any{nowUTC, openMessageLimit}, true})
	}
	root, approvals := 0, notices
	for _, q := range queries {
		var n int
		if err := tx.QueryRowContext(ctx, q.sql, q.args...).Scan(&n); err != nil {
			return nil, fmt.Errorf("inboxfeed: counting the %s: %w", q.name, err)
		}
		if q.root {
			root += n
		} else {
			approvals += n
		}
	}
	out := map[int64]int{t.root().ID: root}
	out[t.approvalsID()] += approvals
	return out, nil
}

// waitingForMe is the waiting-for-me built-in's place in the root
// (InboxFolderQueries.waitingForMe, WaitingForMeState).
type waitingForMe struct {
	// automationID is its row; 0 before it is indexed.
	automationID int64
	// standIn: the Messages entry stands in for it — before its first
	// successful run and after a failed one, or while the daemon stopped it.
	standIn bool
	// turnedOff: the owner turned it off (its row disabled with no reason):
	// neither its artifacts nor the Messages entry show or count.
	turnedOff bool
}

// hides reports whether automation's artifacts leave the root: Waiting for
// me's own while the Messages entry stands in or it is turned off.
func (w waitingForMe) hides(automation int64) bool {
	return w.automationID != 0 && automation == w.automationID && (w.standIn || w.turnedOff)
}

// readWaitingForMe reads the built-in's state. The feature switch is read
// from its row: turning attention detection off turns the row off with no
// disabled_reason (turnOffBuiltinsOfDisabled, the built-in sync).
func readWaitingForMe(ctx context.Context, tx *sql.Tx) (waitingForMe, error) {
	var id int64
	var enabled bool
	var reason string
	err := tx.QueryRowContext(ctx, `SELECT id, enabled, disabled_reason FROM automations WHERE builtin_id = ?`,
		waitingForMeBuiltinID).Scan(&id, &enabled, &reason)
	if errors.Is(err, sql.ErrNoRows) {
		return waitingForMe{standIn: true}, nil
	}
	if err != nil {
		return waitingForMe{}, fmt.Errorf("inboxfeed: reading Waiting for me: %w", err)
	}
	stopped := reason != ""
	if !enabled && !stopped {
		return waitingForMe{automationID: id, turnedOff: true}, nil
	}
	if stopped {
		return waitingForMe{automationID: id, standIn: true}, nil
	}
	var status string
	err = tx.QueryRowContext(ctx, `SELECT status FROM automation_runs
		WHERE automation_id = ? AND trigger != 'dry_run' AND status NOT IN ('queued', 'running', 'waiting')
		ORDER BY id DESC LIMIT 1`, id).Scan(&status)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return waitingForMe{}, fmt.Errorf("inboxfeed: reading Waiting for me's last run: %w", err)
	}
	return waitingForMe{automationID: id, standIn: status != "succeeded"}, nil
}

// builtinAutomationID is the automation row of built-in id; 0 when it is
// not indexed.
func builtinAutomationID(ctx context.Context, tx *sql.Tx, id string) (int64, error) {
	var out int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM automations WHERE builtin_id = ?`, id).Scan(&out)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("inboxfeed: reading built-in %s: %w", id, err)
	}
	return out, nil
}

// ref is a list row's record (InboxRef).
type ref struct {
	Kind api.RefKind
	ID   int64
}

// refKinds are the ref kinds a stored document's row may carry (the Kit's
// ArtifactRefKind as InboxRef reads it).
var refKinds = map[api.RefKind]bool{
	api.RefInboxItem: true, api.RefTrack: true, api.RefIdea: true, api.RefReminder: true, api.RefAction: true,
}

// blockTypes are the block types the Kit's v1 decoder reads.
var blockTypes = map[string]bool{
	"heading": true, "text": true, "list": true, "table": true,
	"person": true, "metrics": true, "link": true, "actions": true,
}

// refsOf is every list row's ref of a stored document, in document order
// (InboxRef.refs): none for a document the Kit marks unreadable — not JSON,
// another version, no blocks array, a block that is not an object or has
// an unknown type, a list without rows, a row that is not an object or has
// no title, a malformed ref.
func refsOf(blocksJSON string) []ref {
	if blocksJSON == "" {
		return nil
	}
	var doc map[string]json.RawMessage
	if json.Unmarshal([]byte(blocksJSON), &doc) != nil {
		return nil
	}
	if v, ok := jsonInt(doc["v"]); !ok || v != 1 {
		return nil
	}
	var blocks []json.RawMessage
	if json.Unmarshal(doc["blocks"], &blocks) != nil || blocks == nil {
		return nil
	}
	var out []ref
	for _, raw := range blocks {
		var block map[string]json.RawMessage
		if json.Unmarshal(raw, &block) != nil || block == nil {
			return nil
		}
		var typ string
		if json.Unmarshal(block["type"], &typ) != nil || !blockTypes[typ] {
			return nil
		}
		if typ != "list" {
			continue
		}
		var rows []json.RawMessage
		if json.Unmarshal(block["rows"], &rows) != nil || rows == nil {
			return nil
		}
		for _, rawRow := range rows {
			r, ok, valid := rowRef(rawRow)
			if !valid {
				return nil
			}
			if ok {
				out = append(out, r)
			}
		}
	}
	return out
}

// rowRef reads one list row: its ref (ok false for none) and whether the
// row is readable at all.
func rowRef(raw json.RawMessage) (r ref, ok, valid bool) {
	var row map[string]json.RawMessage
	if json.Unmarshal(raw, &row) != nil || row == nil {
		return ref{}, false, false
	}
	var title string
	if json.Unmarshal(row["title"], &title) != nil || title == "" {
		return ref{}, false, false
	}
	value, has := row["ref"]
	if !has || string(value) == "null" {
		return ref{}, false, true
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(value, &obj) != nil || obj == nil {
		return ref{}, false, false
	}
	var kind string
	if json.Unmarshal(obj["kind"], &kind) != nil || !refKinds[api.RefKind(kind)] {
		return ref{}, false, false
	}
	id, isInt := jsonInt(obj["id"])
	if !isInt || id <= 0 {
		return ref{}, false, false
	}
	return ref{Kind: api.RefKind(kind), ID: id}, true, true
}

// jsonInt reads a JSON integer: a number with no fraction that fits int64,
// never a bool or a string.
func jsonInt(raw json.RawMessage) (int64, bool) {
	s := strings.TrimSpace(string(raw))
	if s == "" || (s[0] != '-' && (s[0] < '0' || s[0] > '9')) {
		return 0, false
	}
	var f float64
	if json.Unmarshal(raw, &f) != nil || f != float64(int64(f)) {
		return 0, false
	}
	return int64(f), true
}

// readWaits returns the refs whose record waits on the owner (the waits
// half of InboxRefState.read): one query per kind present. A deleted record
// never waits.
func readWaits(ctx context.Context, tx *sql.Tx, refs []ref, now time.Time) (map[ref]bool, error) {
	ids := map[api.RefKind][]int64{}
	seen := map[ref]bool{}
	for _, r := range refs {
		if !seen[r] {
			seen[r] = true
			ids[r.Kind] = append(ids[r.Kind], r.ID)
		}
	}
	nowUTC := now.UTC().Format(stampLayout)
	out := map[ref]bool{}
	for kind, list := range ids {
		var query string
		args := make([]any, 0, len(list)+1)
		for _, id := range list {
			args = append(args, id)
		}
		marks := strings.TrimSuffix(strings.Repeat("?,", len(list)), ",")
		switch kind {
		case api.RefInboxItem:
			query = `SELECT id FROM inbox_items WHERE id IN (` + marks + `) AND ` + db.OpenInboxClause()
			args = append(args, nowUTC)
		case api.RefTrack:
			query = `SELECT id FROM tracks WHERE id IN (` + marks + `) AND dismissed_at = '' AND read_at IS NULL`
		case api.RefReminder:
			query = `SELECT id FROM reminders WHERE id IN (` + marks + `) AND status = 'pending' AND remind_at <= ?`
			args = append(args, nowUTC)
		case api.RefAction:
			query = `SELECT id FROM agent_actions WHERE id IN (` + marks + `) AND ` + awaitingOwnerClause
		case api.RefIdea:
			query = `SELECT id FROM ideas WHERE id IN (` + marks + `)
				AND status NOT IN ('merged', 'superseded')
				AND (status = 'proposed' OR needs_review = 1) AND (kind != 'decision' OR chat_born = 1)
				AND NOT ` + ideaSnoozedClause
			args = append(args, now.Format("2006-01-02"), nowUTC)
		default:
			continue
		}
		if err := collectIDs(ctx, tx, query, args, func(id int64) { out[ref{Kind: kind, ID: id}] = true }); err != nil {
			return nil, fmt.Errorf("inboxfeed: reading %s refs: %w", kind, err)
		}
	}
	return out, nil
}

// ideaSnoozedClause is InboxRefState.ideaSnoozed in SQL: snooze_until is ""
// (none), an owner-local yyyy-MM-dd (snoozed while it is after today, the
// first `?`) or an RFC 3339 time (snoozed while after now, the second);
// anything else reads as not snoozed, so the idea is never lost.
const ideaSnoozedClause = `(snooze_until != '' AND (
	(length(snooze_until) = 10 AND date(snooze_until) IS NOT NULL AND snooze_until > ?)
	OR (length(snooze_until) != 10 AND julianday(snooze_until) IS NOT NULL
		AND julianday(snooze_until) > julianday(?))))`

// collectIDs runs query and calls add with each id it returns.
func collectIDs(ctx context.Context, tx *sql.Tx, query string, args []any, add func(int64)) error {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return err
		}
		add(id)
	}
	return rows.Err()
}
