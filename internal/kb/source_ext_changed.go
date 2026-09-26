package kb

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// extUserPageSize caps one Changed call's users-arm page: at most this many
// (user, document) pairs are listed per call. A wider rename fan-out (or a
// users-cache refresh) is drained over several calls through a key-based
// continuation — Changed reports done=false while a page is full, so the
// indexer calls again in the same cycle (budget permitting) or resumes next
// cycle — and every pair is re-rendered exactly once.
const extUserPageSize = 5000

// extCursor is the confluence source's cursor, stored as JSON in
// kb_sources.cursor. The two arms advance independently:
//   - Docs: the highest document marker (MAX(synced_at, children_changed_at))
//     already listed;
//   - User*: the last (fetched_at, ext_user_id, document key) users-arm pair
//     already listed, in the arm's ORDER BY.
//
// Both arms compare strictly (>) and only ever list markers from seconds
// that are already over (< the current second, see horizon), so an idle
// install lists nothing: a second that is over can gain no new row from the
// daemon, whose extsync phase runs before the knowledge-index phase on the
// same clock. (A `confluence sync --force` racing the daemon in the same
// second is the one writer this does not cover; `kb reindex` repairs it.)
type extCursor struct {
	Docs    string `json:"docs,omitempty"`
	UserTS  string `json:"user_ts,omitempty"`
	UserID  string `json:"user_id,omitempty"`
	UserKey string `json:"user_key,omitempty"`
}

func parseExtCursor(s string) (extCursor, error) {
	var c extCursor
	if s == "" {
		return c, nil
	}
	if err := json.Unmarshal([]byte(s), &c); err != nil {
		return c, fmt.Errorf("bad cursor %q: %w", s, err)
	}
	return c, nil
}

func (c extCursor) String() string {
	if c == (extCursor{}) {
		return ""
	}
	b, _ := json.Marshal(c) // a struct of strings always marshals
	return string(b)
}

// horizon is the first second that is not over yet: markers are listed only
// strictly below it (RFC3339 UTC strings compare in time order).
func horizon(now time.Time) string {
	return now.UTC().Truncate(time.Second).Format(time.RFC3339)
}

// Changed lists documents whose row was synced or whose comments changed
// since the cursor, plus documents authored or commented on by a user whose
// cached name was refreshed since the cursor, so a rename re-renders them.
func (s extSource) Changed(ctx context.Context, q Queryer, cursor string, now time.Time) ([]string, string, bool, error) {
	cur, err := parseExtCursor(cursor)
	if err != nil {
		return nil, cursor, false, err
	}
	h := horizon(now)
	docKeys, docsNext, err := changedByColumn(ctx, q, cur.Docs,
		`SELECT ? || ':' || d.source_id || ':' || d.ext_id, MAX(d.synced_at, d.children_changed_at)
		 FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
		 WHERE s.provider = ? AND MAX(d.synced_at, d.children_changed_at) > ?
		   AND MAX(d.synced_at, d.children_changed_at) < ?`,
		s.provider, s.provider, cur.Docs, h)
	if err != nil {
		return nil, cursor, false, err
	}
	userKeys, next, full, err := s.changedByUsers(ctx, q, cur, h)
	if err != nil {
		return nil, cursor, false, err
	}
	next.Docs = docsNext
	return mergeKeys(docKeys, userKeys), next.String(), !full, nil
}

// changedByUsers lists one page of the users arm after cur's continuation
// point; full reports that the page hit the cap (more may follow).
func (s extSource) changedByUsers(ctx context.Context, q Queryer, cur extCursor, h string) ([]string, extCursor, bool, error) {
	limit := s.userLimit
	if limit <= 0 {
		limit = extUserPageSize
	}
	rows, err := q.QueryContext(ctx, `SELECT k, ts, uid FROM (
		   SELECT ? || ':' || d.source_id || ':' || d.ext_id AS k, u.fetched_at AS ts, u.ext_user_id AS uid
		   FROM ext_users u
		   JOIN ext_documents d ON d.author_id = u.ext_user_id
		   JOIN ext_sources s ON s.id = d.source_id AND s.provider = u.provider
		   WHERE u.provider = ? AND u.fetched_at >= ? AND u.fetched_at < ?
		   UNION
		   SELECT ? || ':' || d.source_id || ':' || d.ext_id, u.fetched_at, u.ext_user_id
		   FROM ext_users u
		   JOIN ext_comments c ON c.author_id = u.ext_user_id
		   JOIN ext_documents d ON d.source_id = c.source_id AND d.ext_id = c.page_ext_id
		   JOIN ext_sources s ON s.id = d.source_id AND s.provider = u.provider
		   WHERE u.provider = ? AND u.fetched_at >= ? AND u.fetched_at < ?)
		 WHERE (ts, uid, k) > (?, ?, ?)
		 ORDER BY ts, uid, k LIMIT ?`,
		s.provider, s.provider, cur.UserTS, h,
		s.provider, s.provider, cur.UserTS, h,
		cur.UserTS, cur.UserID, cur.UserKey, limit)
	if err != nil {
		return nil, cur, false, err
	}
	defer rows.Close()
	next := cur
	var keys []string
	for rows.Next() {
		if err := rows.Scan(&next.UserKey, &next.UserTS, &next.UserID); err != nil {
			return nil, cur, false, err
		}
		keys = append(keys, next.UserKey)
	}
	if err := rows.Err(); err != nil {
		return nil, cur, false, err
	}
	return keys, next, len(keys) == limit, nil
}

// mergeKeys returns the sorted union of a and b.
func mergeKeys(a, b []string) []string {
	set := make(map[string]bool, len(a)+len(b))
	for _, k := range append(append([]string(nil), a...), b...) {
		set[k] = true
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
