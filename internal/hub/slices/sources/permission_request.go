package sources

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// The permission_request values (PermissionRequestSlice, PROJ-21).
const (
	// PermissionMaxAge is the hook's own timeout: past it no hook waits on
	// the row. Go↔Swift dual path with internal/devpack/workbench_settings.go
	// permissionWaitSpec (timeoutSec 86400); change all together.
	PermissionMaxAge = 86_400 * time.Second
	// PermissionMaxSummary is the wire's summary cap in grapheme clusters
	// (Go's hook clips at 2000 runes first).
	PermissionMaxSummary = 2000
)

// liveOf reads live, or the unsettled empty Liveness for nil: nothing live,
// so requests are hidden and only their age expires them, and no session
// stop or request alerts — the safe side until the session-host list is
// wired.
func liveOf(live func() Liveness) Liveness {
	if live == nil {
		return Liveness{}
	}
	return live()
}

func isLive(l Liveness, session int64) bool {
	_, ok := l.Runs[session]
	return ok
}

// PermissionRequest is the permission_request slice (#517,
// PermissionRequestSlice), record permission_request-<id>: the pending
// permission prompts of live board Claude sessions in the published
// workbenches. Each pass first marks expired, in its own short write, every
// pending row no hook waits on (older than PermissionMaxAge, or of a session
// that is not live once liveness settled); the read leaves such rows out on
// its own, so a failed write never publishes one. live nil is "nothing live,
// not settled" (liveOf); now nil is time.Now.
func PermissionRequest(d *db.DB, live func() Liveness, now func() time.Time) slices.Source {
	if now == nil {
		now = time.Now
	}
	return &permissionSource{d: d, live: live, now: now}
}

type permissionSource struct {
	d    *db.DB
	live func() Liveness
	now  func() time.Time
}

func (*permissionSource) Kind() slices.Kind { return "permission_request" }

// permissionPayload is the Kit mirror WatchtowerKit.PermissionRequest.
type permissionPayload struct {
	ID             int64     `json:"id"`
	SessionID      int64     `json:"session_id"`
	WorkbenchID    int64     `json:"workbench_id"`
	ToolName       string    `json:"tool_name"`
	Summary        string    `json:"summary"`
	SummaryClipped bool      `json:"summary_clipped,omitempty"`
	CreatedAt      wire.Time `json:"created_at"`
}

// pendingRequest is one pending request a hook still waits on (the work
// alerts read the same rows).
type pendingRequest struct {
	ID, SessionID, WorkbenchID int64
	ToolName, Summary          string
	SummaryClipped             bool
	CreatedAt                  time.Time
}

func (s *permissionSource) Items(ctx context.Context) ([]slices.Item, error) {
	live := liveOf(s.live)
	now := s.now()
	if n, err := expirePermissionRequests(ctx, s.d, live, now); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		log.Printf("hub slices: permission request expiry failed (%s); stale rows stay hidden", errClass(err))
	} else if n > 0 {
		log.Printf("hub slices: expired %d permission requests no hook waits on", n)
	}
	var pending []pendingRequest
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		var err error
		pending, err = pendingRequests(ctx, tx, live, now)
		return err
	})
	if err != nil {
		return nil, err
	}
	out := make([]slices.Item, 0, len(pending))
	for _, r := range pending {
		summary, clipped := WireSummary(r.Summary, r.SummaryClipped)
		b, err := wire.Marshal(permissionPayload{
			ID: r.ID, SessionID: r.SessionID, WorkbenchID: r.WorkbenchID, ToolName: r.ToolName,
			Summary: summary, SummaryClipped: clipped, CreatedAt: wire.Time{Time: r.CreatedAt},
		})
		if err != nil {
			return nil, fmt.Errorf("encoding permission request %d: %w", r.ID, err)
		}
		out = append(out, slices.Item{ID: strconv.FormatInt(r.ID, 10), Payload: b})
	}
	return out, nil
}

// WireSummary is the summary as the phone gets it and whether it was
// shortened, by Go's hook (clippedByGo, the row's summary_clipped) or by the
// wire's cap. The phone offers Deny only for a clipped one
// (PermissionAllowBlock), and the hub's answer handler judges an allow on
// the same value.
func WireSummary(raw string, clippedByGo bool) (string, bool) {
	text, clipped := clipText(raw, PermissionMaxSummary)
	return text, clippedByGo || clipped != nil
}

// permissionStale: no hook reads the row — its session is not live, or it
// is older than the hook timeout (an unreadable stamp counts as old).
func permissionStale(created *wire.Time, live bool, now time.Time) bool {
	return !live || created == nil || now.Sub(created.Time) > PermissionMaxAge
}

// pendingRequests is PermissionRequestSlice.pending: the pending requests of
// live board Claude sessions in the published workbenches, not stale, in id
// order.
func pendingRequests(ctx context.Context, tx *sql.Tx, live Liveness, now time.Time) ([]pendingRequest, error) {
	refs, err := publishedRefs(ctx, tx)
	if err != nil || len(refs) == 0 {
		return nil, err
	}
	published := map[int64]bool{}
	for _, r := range refs {
		published[r.id] = true
	}
	rows, err := tx.QueryContext(ctx, `
SELECT r.id, r.terminal_session_id, r.workbench_id, r.tool_name, r.summary, r.summary_clipped,
       r.created_at, s.project_id
FROM permission_requests r
JOIN terminal_sessions s ON s.id = r.terminal_session_id
WHERE r.status = 'pending' AND s.kind = 'claude'
ORDER BY r.id`)
	if err != nil {
		return nil, fmt.Errorf("reading permission requests: %w", err)
	}
	defer rows.Close()
	var out []pendingRequest
	for rows.Next() {
		var (
			r       pendingRequest
			created string
			project sql.NullInt64
		)
		if err := rows.Scan(&r.ID, &r.SessionID, &r.WorkbenchID, &r.ToolName, &r.Summary, &r.SummaryClipped,
			&created, &project); err != nil {
			return nil, fmt.Errorf("reading permission requests: %w", err)
		}
		at := parseDate(created)
		if !project.Valid || !published[project.Int64] || permissionStale(at, isLive(live, r.SessionID), now) {
			continue
		}
		r.CreatedAt = at.Time
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading permission requests: %w", err)
	}
	return out, nil
}

// expirePermissionRequests is PermissionRequestSlice.expire: marks expired
// every pending request no hook waits on any more and returns how many. It
// reads first and writes only when there is one, so a pass with nothing to
// expire takes no write lock. Before liveness settled only the age counts.
func expirePermissionRequests(ctx context.Context, d *db.DB, live Liveness, now time.Time) (int64, error) {
	stale, err := staleRequestIDs(ctx, d, live, now)
	if err != nil {
		return 0, err
	}
	if len(stale) == 0 {
		return 0, nil
	}
	marks, args := inList(stale)
	// The status guard keeps an answer that landed since the read.
	res, err := d.ExecContext(ctx, `UPDATE permission_requests SET status = 'expired', decided_at = ?
		WHERE status = 'pending' AND id IN (`+marks+`)`, append([]any{db.AgentStateStamp(now)}, args...)...)
	if err != nil {
		return 0, fmt.Errorf("expiring permission requests: %w", err)
	}
	return res.RowsAffected()
}

// staleRequestIDs is every pending request no hook waits on any more.
func staleRequestIDs(ctx context.Context, d *db.DB, live Liveness, now time.Time) ([]int64, error) {
	rows, err := d.QueryContext(ctx, `SELECT id, terminal_session_id, created_at FROM permission_requests WHERE status = 'pending'`)
	if err != nil {
		return nil, fmt.Errorf("reading pending permission requests: %w", err)
	}
	defer rows.Close()
	var stale []int64
	for rows.Next() {
		var (
			id, session int64
			created     string
		)
		if err := rows.Scan(&id, &session, &created); err != nil {
			return nil, fmt.Errorf("reading pending permission requests: %w", err)
		}
		if permissionStale(parseDate(created), !live.Settled || isLive(live, session), now) {
			stale = append(stale, id)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading pending permission requests: %w", err)
	}
	return stale, nil
}
