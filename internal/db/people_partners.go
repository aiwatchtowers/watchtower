package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"

	watchtowerslack "watchtower/internal/slack"
)

// SlackOwnersByAccount maps each live Slack account (not removed or purged)
// with a known current_user_id to that namespaced owner id ("<account>:<U>"),
// the owners ComputeAllUserStats makes cards through. It reads the accounts
// through ListSlackAccounts, the per-account path OWNER-01 allows.
func (db *DB) SlackOwnersByAccount() (map[int64]string, error) {
	accounts, err := db.ListSlackAccounts()
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string)
	for _, a := range accounts {
		if a.CurrentUserID != "" && a.Status != "removed" && a.Status != "purged" {
			out[a.ID] = a.CurrentUserID
		}
	}
	return out, nil
}

// interactionPartnersSQL lists who interacted directly with the owner in
// [from, to) within one account (spec 2026-11-17 §5.3, A13): someone who
// posted in a DM or group DM the owner posted in, in a thread the owner
// posted in (as its parent, a reply, or both replying in a third thread),
// who mentioned the owner, or whom the owner mentioned.
//
// Every branch is bounded by the window (TestInteractionPartners_QueryPlan):
// own is the owner's window messages, materialized once and read through
// idx_messages_ts_unix (the unary + keeps the planner off the owner's whole
// history in idx_messages_user_id); the DM branch seeks
// idx_messages_channel_ts_unix per DM channel; the thread branches seek
// idx_messages_thread and the primary key per owner message; the mention
// branch is one pass over the window's messages; the owner-mentions branch
// starts from own and seeks the users primary key.
const interactionPartnersSQL = `
WITH own AS MATERIALIZED (
	SELECT channel_id, ts, thread_ts, text FROM messages INDEXED BY idx_messages_ts_unix
	WHERE ts_unix >= :from AND ts_unix < :to AND +user_id = :owner AND is_deleted = 0
)
SELECT p.user_id FROM messages p INDEXED BY idx_messages_channel_ts_unix
	WHERE p.channel_id IN (SELECT o.channel_id FROM own o JOIN channels c ON c.id = o.channel_id
		WHERE c.type IN ('dm', 'group_dm'))
		AND p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM own o CROSS JOIN messages p INDEXED BY idx_messages_thread
	ON p.channel_id = o.channel_id AND p.thread_ts = COALESCE(o.thread_ts, o.ts)
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM own o CROSS JOIN messages p
	ON p.channel_id = o.channel_id AND p.ts = o.thread_ts
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM messages p INDEXED BY idx_messages_ts_unix
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
		AND +p.user_id >= :lo AND +p.user_id < :hi
		AND (instr(p.text, '<@' || :raw || '>') > 0 OR instr(p.text, '<@' || :raw || '|') > 0)
UNION
SELECT u.id FROM own o CROSS JOIN users u
	WHERE instr(o.text, '<@') > 0 AND u.id >= :lo AND u.id < :hi
		AND (instr(o.text, '<@' || substr(u.id, :rawAt) || '>') > 0
			OR instr(o.text, '<@' || substr(u.id, :rawAt) || '|') > 0)`

// InteractionPartners returns the namespaced ids of account accountID's
// users (the owner excluded) who interacted directly with owner in
// [from, to). An owner id outside accountID's namespace has no partners.
func (db *DB) InteractionPartners(accountID int64, owner string, from, to float64) ([]string, error) {
	acct, raw, ok := watchtowerslack.SplitAccountID(owner)
	if !ok || acct != accountID || raw == "" {
		return nil, nil
	}
	prefix := strconv.FormatInt(accountID, 10) + ":"
	lo, hi := prefixRange(prefix)
	rows, err := db.Query(interactionPartnersSQL,
		sql.Named("owner", owner), sql.Named("from", from), sql.Named("to", to),
		sql.Named("lo", lo), sql.Named("hi", hi), sql.Named("raw", raw),
		sql.Named("rawAt", len(prefix)+1))
	if err != nil {
		return nil, fmt.Errorf("listing interaction partners of %s: %w", owner, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning interaction partner: %w", err)
		}
		// The DM and thread branches match by channel, which is already in
		// the account's namespace; the check keeps the contract explicit.
		if id != owner && id >= lo && id < hi {
			out = append(out, id)
		}
	}
	return out, rows.Err()
}

// PeopleCardCandidates is who may have a card for [from, to): each owner in
// owners and that owner's interaction partners (A13).
func (db *DB) PeopleCardCandidates(from, to float64, owners map[int64]string) (map[string]bool, error) {
	out := make(map[string]bool)
	for acct, owner := range owners {
		partners, err := db.InteractionPartners(acct, owner, from, to)
		if err != nil {
			return nil, err
		}
		out[owner] = true
		for _, p := range partners {
			out[p] = true
		}
	}
	return out, nil
}

// PrunePreUpgradePeopleCards is the one-time upgrade pass of A13: in every
// live Slack account whose pass is not done yet and whose owner is known, it
// deletes each card whose person was neither the owner nor an interaction
// partner of the owner in that card's own window — the cards made before the
// upgrade for everyone with enough messages. A card whose own window passes
// the check stays. When an account's windows are all checked, its
// people_prune_done_at is stamped and the account is never checked again
// (new cards are limited to partners by ComputeAllUserStats). An account
// without a known owner stays pending. The pass is idempotent: one
// interrupted (ctx, a crash) resumes from the start of the account on the
// next call. done reports that no live account is pending any more.
func (db *DB) PrunePreUpgradePeopleCards(ctx context.Context) (pruned int64, done bool, err error) {
	pending, err := db.peoplePrunePending()
	if err != nil || len(pending) == 0 {
		return 0, err == nil, err
	}
	owners, err := db.SlackOwnersByAccount()
	if err != nil {
		return 0, false, err
	}
	done = true
	for _, acct := range pending {
		owner, ok := owners[acct]
		if !ok {
			done = false
			continue
		}
		n, err := db.pruneAccountPeopleCards(ctx, acct, owner)
		pruned += n
		if err != nil {
			return pruned, false, err
		}
		if _, err := db.Exec(`UPDATE slack_accounts SET people_prune_done_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, acct); err != nil {
			return pruned, false, fmt.Errorf("marking people prune done for account %d: %w", acct, err)
		}
	}
	return pruned, done, nil
}

// peoplePrunePending lists the live Slack accounts whose one-time people
// card pass has not finished.
func (db *DB) peoplePrunePending() ([]int64, error) {
	rows, err := db.Query(`SELECT id FROM slack_accounts
		WHERE people_prune_done_at = '' AND status NOT IN ('removed', 'purged') ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("listing pending people prune accounts: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning pending people prune account: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// pruneAccountPeopleCards checks every stored card window of one account
// with the window-bounded partner query and deletes the window's cards of
// non-partners. It stops between windows when ctx is done.
func (db *DB) pruneAccountPeopleCards(ctx context.Context, acct int64, owner string) (int64, error) {
	lo, hi := prefixRange(strconv.FormatInt(acct, 10) + ":")
	windows, err := db.peopleCardWindows(lo, hi)
	if err != nil {
		return 0, err
	}
	var total int64
	for _, w := range windows {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		n, err := db.pruneCardWindow(acct, owner, lo, hi, w)
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// pruneCardWindow deletes one stored window's cards, in the namespace
// [lo, hi), of people who were neither the owner nor a partner in it.
func (db *DB) pruneCardWindow(acct int64, owner, lo, hi string, w [2]float64) (int64, error) {
	partners, err := db.InteractionPartners(acct, owner, w[0], w[1])
	if err != nil {
		return 0, err
	}
	keepJSON, err := json.Marshal(append(partners, owner))
	if err != nil {
		return 0, fmt.Errorf("encoding card candidates: %w", err)
	}
	res, err := db.Exec(`DELETE FROM people_cards
		WHERE user_id >= ? AND user_id < ? AND period_from = ? AND period_to = ?
			AND user_id NOT IN (SELECT value FROM json_each(?))`, lo, hi, w[0], w[1], string(keepJSON))
	if err != nil {
		return 0, fmt.Errorf("pruning people cards of account %d: %w", acct, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("pruning people cards of account %d: %w", acct, err)
	}
	return n, nil
}

// peopleCardWindows lists the distinct [period_from, period_to) windows of
// the cards in the namespace [lo, hi).
func (db *DB) peopleCardWindows(lo, hi string) ([][2]float64, error) {
	rows, err := db.Query(`SELECT DISTINCT period_from, period_to FROM people_cards
		WHERE user_id >= ? AND user_id < ? ORDER BY period_from`, lo, hi)
	if err != nil {
		return nil, fmt.Errorf("listing people card windows: %w", err)
	}
	defer rows.Close()
	var out [][2]float64
	for rows.Next() {
		var w [2]float64
		if err := rows.Scan(&w[0], &w[1]); err != nil {
			return nil, fmt.Errorf("scanning people card window: %w", err)
		}
		out = append(out, w)
	}
	return out, rows.Err()
}
