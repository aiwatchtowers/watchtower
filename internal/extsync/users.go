package extsync

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"
)

// usersTTL is how long a cached ext_users row is trusted before it is
// resolved again.
const usersTTL = 30 * 24 * time.Hour

// usersBatchSize bounds one Users call.
const usersBatchSize = 100

// userSet collects the author and mention ids written during one source
// run.
type userSet map[string]struct{}

func (u userSet) add(ids ...string) {
	for _, id := range ids {
		if id != "" {
			u[id] = struct{}{}
		}
	}
}

// addItem records an item's author and mentioned users.
func (u userSet) addItem(it *Item) {
	u.add(it.AuthorID)
	u.add(it.MentionedUserIDs...)
}

func (u userSet) sorted() []string {
	out := make([]string, 0, len(u))
	for id := range u {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// resolveUsers resolves the ids collected this run that are missing from
// ext_users or older than usersTTL, in batches, and caches them. An id the
// provider does not return stays unresolved (asked again the next time it
// is written).
func (e *Engine) resolveUsers(ctx context.Context, provider string, f Fetcher, seen userSet) error {
	if len(seen) == 0 {
		return nil
	}
	now := e.opts.Now()
	stale, err := staleUsers(ctx, e.db, provider, seen.sorted(), now)
	if err != nil {
		return err
	}
	for start := 0; start < len(stale); start += usersBatchSize {
		ids := stale[start:min(start+usersBatchSize, len(stale))]
		users, err := f.Users(ctx, ids)
		if err != nil {
			return fmt.Errorf("extsync: resolving users: %w", err)
		}
		if err := e.withTx(ctx, func(q Queryer) error {
			return upsertUsers(ctx, q, provider, users, now)
		}); err != nil {
			return err
		}
	}
	return nil
}

// staleUsers returns the ids (in input order) with no ext_users row or a
// fetched_at older than usersTTL; an unparseable fetched_at is stale.
func staleUsers(ctx context.Context, q Queryer, provider string, ids []string, now time.Time) ([]string, error) {
	args := make([]any, 0, len(ids)+1)
	args = append(args, provider)
	for _, id := range ids {
		args = append(args, id)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	rows, err := q.QueryContext(ctx, `SELECT ext_user_id, fetched_at FROM ext_users
		WHERE provider = ? AND ext_user_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading cached users: %w", err)
	}
	defer rows.Close()
	fresh := map[string]bool{}
	for rows.Next() {
		var id, fetched string
		if err := rows.Scan(&id, &fetched); err != nil {
			return nil, fmt.Errorf("extsync: scanning cached user: %w", err)
		}
		if t, err := time.Parse(isoLayout, fetched); err == nil && now.Sub(t) < usersTTL {
			fresh[id] = true
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: reading cached users: %w", err)
	}
	var out []string
	for _, id := range ids {
		if !fresh[id] {
			out = append(out, id)
		}
	}
	return out, nil
}

func upsertUsers(ctx context.Context, q Queryer, provider string, users map[string]User, now time.Time) error {
	for id, u := range users {
		if id == "" {
			continue
		}
		if _, err := q.ExecContext(ctx, `INSERT INTO ext_users (provider, ext_user_id, display_name, email, fetched_at)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(provider, ext_user_id) DO UPDATE SET
			 display_name = excluded.display_name, email = excluded.email, fetched_at = excluded.fetched_at`,
			provider, id, u.DisplayName, u.Email, formatTime(now)); err != nil {
			return fmt.Errorf("extsync: caching user %s: %w", id, err)
		}
	}
	return nil
}
