package db

import (
	"database/sql"
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
// posted in (as its parent or a reply), who mentioned the owner, or whom
// the owner mentioned. Each branch starts from the owner's few messages or
// one pass over the window, so it stays index-backed (user_id, ts_unix,
// (channel_id, thread_ts), the primary key).
const interactionPartnersSQL = `
WITH own AS (
	SELECT channel_id, ts, thread_ts, text FROM messages
	WHERE user_id = :owner AND ts_unix >= :from AND ts_unix < :to AND is_deleted = 0
)
SELECT p.user_id FROM messages p
	WHERE p.channel_id IN (SELECT o.channel_id FROM own o JOIN channels c ON c.id = o.channel_id
		WHERE c.type IN ('dm', 'group_dm'))
		AND p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM own o JOIN messages p
	ON p.channel_id = o.channel_id AND p.thread_ts = COALESCE(o.thread_ts, o.ts)
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM own o JOIN messages p
	ON p.channel_id = o.channel_id AND p.ts = o.thread_ts
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
UNION
SELECT p.user_id FROM messages p
	WHERE p.ts_unix >= :from AND p.ts_unix < :to AND p.is_deleted = 0
		AND p.user_id >= :lo AND p.user_id < :hi
		AND (instr(p.text, '<@' || :raw || '>') > 0 OR instr(p.text, '<@' || :raw || '|') > 0)
UNION
SELECT u.id FROM own o JOIN users u ON u.id >= :lo AND u.id < :hi
	WHERE instr(o.text, '<@') > 0
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
