package sources

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/platform"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// The work alert values (WorkAlertSlice, WorkAlertPolicy).
const (
	WorkAlertLifetime    = 7 * 24 * time.Hour
	alertMaxWorkbench    = 60
	alertMaxSession      = 60
	alertMaxBody         = 120
	alertStopHold        = 20 * time.Second
	alertDepartureWin    = 30 * time.Minute
	sessionsPerWorkbench = 50
)

// WorkAlertConfig wires the work alerts. Away nil is "always away" (no
// console, as on linux); Live nil is "nothing live, not settled" (liveOf);
// View (nil = none) is the Desktop's view (TerminalSessionOptions.View): the
// sessions waiting in its Undo batch (PROJ-17), which never alert and take
// no window slot, and the counts it shows over, which read as stopped; Now
// nil is time.Now.
type WorkAlertConfig struct {
	DB    *db.DB
	Store *state.Store
	Away  platform.Away
	Live  func() Liveness
	View  func() (hidden map[int64]bool, displayOver map[int64]ShownOver)
	Now   func() time.Time
}

// WorkAlert is the ask_alert slice (WorkAlertSlice, workbench-remote spec
// §5.2), record ask_alert-<key>: one alert per stop of work in a published
// workbench — a new open ask, a pending permission request, a session that
// finished, waits for input or failed — pushed only while the owner is away
// (a stop left open at the Mac pushes once when the owner leaves; a session
// stop only when it began within 30 minutes before the departure), never
// twice, and published for 7 days after its push or until the stop resolves.
// The publisher seals it under K_alert (Sealer.Alert). The sidecar's
// work_alerts ledger holds keys and times only, never alert text.
func WorkAlert(c WorkAlertConfig) slices.Source {
	if c.Now == nil {
		c.Now = time.Now
	}
	return &workAlertSource{c: c}
}

type workAlertSource struct{ c WorkAlertConfig }

func (*workAlertSource) Kind() slices.Kind { return slices.KindAskAlert }

// workAlertPayload is the Kit's WorkAlertPayload: titles only, never chat
// text.
type workAlertPayload struct {
	Event         string `json:"event"`
	Key           string `json:"key"`
	WorkbenchID   int64  `json:"workbench_id"`
	WorkbenchName string `json:"workbench_name"`
	SessionID     *int64 `json:"session_id,omitempty"`
	AskID         *int64 `json:"ask_id,omitempty"`
	RequestID     *int64 `json:"request_id,omitempty"`
	Title         string `json:"title"`
	Body          string `json:"body"`
	Quick         bool   `json:"quick"`
}

// The candidate events (WorkAlertPolicy.Event).
const (
	eventAsk            = "ask"
	eventPermission     = "permission"
	eventSessionStopped = "session_stopped"
	eventSessionFailed  = "session_failed"
)

// alertCandidate is one stop of work (WorkAlertPolicy.Candidate).
type alertCandidate struct {
	key, event                  string
	workbenchID                 int64
	sessionID, askID, requestID *int64
	startedAt                   time.Time
	title, body                 string
}

type alertAsk struct {
	id, workbenchID int64
	sessionID       *int64
	title, kind     string
	createdAt       time.Time
	quick           bool
}

// alertSession is a published session with its resolved state
// (WorkAlertPolicy.SessionInput).
type alertSession struct {
	id, workbenchID int64
	title           string
	kind            sessionKind
	stateAt         time.Time // zero = unknown, never pushes
	openAsks        int
	pendingRequest  bool
}

// alertReads is everything a pass reads from watchtower.db, in one snapshot.
type alertReads struct {
	names    map[int64]string
	asks     []alertAsk
	requests []pendingRequest
	sessions []alertSession
}

func (s *workAlertSource) Items(ctx context.Context) ([]slices.Item, error) {
	c := s.c
	stamp := c.Now()
	// The hub's first enable; the heartbeat sets the same value.
	enabledAt, err := c.Store.EnsureMetaTime(ctx, state.MetaEnabledAt, stamp)
	if err != nil {
		return nil, err
	}
	var (
		hidden map[int64]bool
		over   map[int64]ShownOver
	)
	if c.View != nil {
		hidden, over = c.View()
	}
	var rd alertReads
	if err := readTx(ctx, c.DB, func(tx *sql.Tx) error {
		var err error
		rd, err = s.read(ctx, tx, liveOf(c.Live), hidden, over, stamp)
		return err
	}); err != nil {
		return nil, err
	}
	names, asks, requests, sessions := rd.names, rd.asks, rd.requests, rd.sessions
	all := alertCandidates(asks, requests, sessions, stamp)

	// A stop an ask or a request stood for stays theirs once they resolve
	// (seen-only cover- rows, never pushed).
	covers := coveredStopKeys(sessions)
	for i, k := range covers {
		covers[i] = coverKey(k)
	}
	_, covered, err := c.Store.NoteWorkAlerts(ctx, covers, nil, stamp)
	if err != nil {
		return nil, err
	}
	startedAt, err := c.Store.EnsureMetaTime(ctx, state.MetaWorkAlertsStartedAt, stamp)
	if err != nil {
		return nil, err
	}
	var candidates []alertCandidate
	for _, cand := range all {
		if _, ok := covered[coverKey(cand.key)]; !ok && alertCounts(cand, enabledAt, startedAt) {
			candidates = append(candidates, cand)
		}
	}
	since, away, err := s.awaySince(ctx, stamp)
	if err != nil {
		return nil, err
	}
	keys := make([]string, len(candidates))
	pushing := map[string]bool{}
	for i, cand := range candidates {
		keys[i] = cand.key
		if away && pushesWhileAway(cand, since) {
			pushing[cand.key] = true
		}
	}
	// At the Mac only what already reached the zone stays: a push whose
	// publish failed waits for the next departure, so its first save (and
	// signal) never lands while the owner sits at the Mac.
	var inZone map[string]state.SliceRecord
	if !away {
		if inZone, err = c.Store.SliceHashes(string(slices.KindAskAlert)); err != nil {
			return nil, err
		}
	}
	gen, marks, err := c.Store.NoteWorkAlerts(ctx, keys, pushing, stamp)
	if err != nil {
		return nil, err
	}
	keeping := map[string]bool{}
	for _, cand := range all {
		keeping[cand.key] = true
		keeping[coverKey(cand.key)] = true
	}
	for _, k := range covers {
		keeping[k] = true
	}
	if err := c.Store.PruneWorkAlerts(ctx, stamp.Add(-WorkAlertLifetime), keeping); err != nil {
		return nil, err
	}
	quick := map[int64]bool{}
	for _, a := range asks {
		quick[a.id] = a.quick
	}
	var out []slices.Item
	for _, cand := range candidates {
		m, ok := marks[cand.key]
		if !ok || !m.Pushed() || m.Generation != gen || stamp.Sub(m.PushedAt) > WorkAlertLifetime {
			continue
		}
		if inZone != nil {
			if _, ok := inZone[string(slices.KindAskAlert)+"-"+cand.key]; !ok {
				continue
			}
		}
		b, err := wire.Marshal(alertPayload(cand, names[cand.workbenchID], cand.askID != nil && quick[*cand.askID]))
		if err != nil {
			return nil, fmt.Errorf("encoding a work alert: %w", err)
		}
		out = append(out, slices.Item{ID: cand.key, Payload: b})
	}
	return out, nil
}

// read is the pass's database half: the published workbenches, their open
// asks, the pending requests and the terminal_session window's sessions,
// outside the hidden sessions.
func (s *workAlertSource) read(ctx context.Context, tx *sql.Tx, live Liveness, hidden map[int64]bool,
	over map[int64]ShownOver, now time.Time,
) (alertReads, error) {
	rd := alertReads{names: map[int64]string{}}
	refs, err := publishedRefs(ctx, tx)
	if err != nil || len(refs) == 0 {
		return rd, err
	}
	for _, r := range refs {
		rd.names[r.id] = r.name
	}
	if rd.asks, err = openAlertAsks(ctx, tx, rd.names, hidden); err != nil {
		return rd, err
	}
	all, err := pendingRequests(ctx, tx, live, now)
	if err != nil {
		return rd, err
	}
	waiting := map[int64]bool{}
	for _, r := range all {
		if !hidden[r.SessionID] {
			rd.requests = append(rd.requests, r)
			waiting[r.SessionID] = true
		}
	}
	// The terminal_session slice's own window and states (Swift reads
	// TerminalSessionSlice.publishedSessions the same way): the hidden
	// sessions are left out before the window, a count shown over is over.
	published, err := TerminalSessions(s.c.DB, TerminalSessionOptions{
		Liveness: func() Liveness { return live }, Now: func() time.Time { return now },
		View: func() (map[int64]bool, map[int64]ShownOver) { return hidden, over },
	}).published(ctx, tx)
	if err != nil {
		return rd, err
	}
	for _, p := range published {
		a := alertSession{id: p.id, workbenchID: p.workbenchID, title: p.title, kind: p.state.kind,
			openAsks: p.state.openAsks, pendingRequest: waiting[p.id]}
		if p.stateAt != nil {
			a.stateAt = p.stateAt.Time
		}
		rd.sessions = append(rd.sessions, a)
	}
	return rd, nil
}

// awaySince is when the owner left the Mac and whether they are away: the
// first pass that reads them away stores its stamp, the first pass that
// reads them back removes it.
func (s *workAlertSource) awaySince(ctx context.Context, stamp time.Time) (time.Time, bool, error) {
	away := true
	if s.c.Away != nil {
		var err error
		if away, err = s.c.Away.Away(); err != nil {
			return time.Time{}, false, err
		}
	}
	if !away {
		if _, ok, err := s.c.Store.Meta(state.MetaWorkAlertsAwaySince); err != nil {
			return time.Time{}, false, err
		} else if ok {
			if err := s.c.Store.DeleteMeta(state.MetaWorkAlertsAwaySince); err != nil {
				return time.Time{}, false, err
			}
		}
		return time.Time{}, false, nil
	}
	since, err := s.c.Store.EnsureMetaTime(ctx, state.MetaWorkAlertsAwaySince, stamp)
	return since, true, err
}

// coverKey is the ledger key remembering that a stop was an ask's or a
// request's.
func coverKey(key string) string { return "cover-" + key }

// alertPayload is WorkAlertSlice.payload.
func alertPayload(c alertCandidate, workbenchName string, quick bool) workAlertPayload {
	workbench, _ := clipText(workbenchName, alertMaxWorkbench)
	session, _ := clipText(c.title, alertMaxSession)
	title := workbench
	if session != "" {
		title = workbench + " · " + session
	}
	body, _ := clipText(c.body, alertMaxBody)
	return workAlertPayload{
		Event: c.event, Key: c.key, WorkbenchID: c.workbenchID, WorkbenchName: workbench,
		SessionID: c.sessionID, AskID: c.askID, RequestID: c.requestID, Title: title, Body: body, Quick: quick,
	}
}

// alertCandidates is WorkAlertPolicy.candidates: asks first, then requests,
// then session stops, each in input order.
func alertCandidates(asks []alertAsk, requests []pendingRequest, sessions []alertSession, now time.Time) []alertCandidate {
	titles := map[int64]string{}
	for _, s := range sessions {
		if _, ok := titles[s.id]; !ok {
			titles[s.id] = s.title
		}
	}
	sessionTitle := func(id *int64) string {
		if id == nil {
			return ""
		}
		return titles[*id]
	}
	var out []alertCandidate
	for _, a := range asks {
		out = append(out, alertCandidate{
			key: "ask-" + strconv.FormatInt(a.id, 10), event: eventAsk, workbenchID: a.workbenchID,
			sessionID: a.sessionID, askID: int64Ptr(a.id), startedAt: a.createdAt, title: sessionTitle(a.sessionID), body: a.title,
		})
	}
	for _, r := range requests {
		out = append(out, alertCandidate{
			key: "perm-" + strconv.FormatInt(r.ID, 10), event: eventPermission, workbenchID: r.WorkbenchID,
			sessionID: int64Ptr(r.SessionID), requestID: int64Ptr(r.ID), startedAt: r.CreatedAt,
			title: sessionTitle(int64Ptr(r.SessionID)), body: "Needs approval: " + r.ToolName,
		})
	}
	for _, s := range sessions {
		event, body, ok := stopOf(s.kind)
		if !ok || s.stateAt.IsZero() || now.Sub(s.stateAt) < alertStopHold || s.openAsks != 0 || s.pendingRequest {
			continue
		}
		out = append(out, alertCandidate{
			key: stopKey(s.id, s.stateAt), event: event, workbenchID: s.workbenchID, sessionID: int64Ptr(s.id),
			startedAt: s.stateAt, title: s.title, body: body,
		})
	}
	return out
}

// stopOf is WorkAlertPolicy.stop over the presentation state.
func stopOf(k sessionKind) (event, body string, ok bool) {
	switch k {
	case kindFinished:
		return eventSessionStopped, "Finished", true
	case kindStopped:
		return eventSessionStopped, "Waiting for you", true
	case kindFailed:
		return eventSessionFailed, "Failed", true
	case kindNotStarted, kindRunning, kindWorking, kindNeedsApproval, kindWaitingOnAsk, kindBackground, kindReadyToCheck:
	}
	return "", "", false
}

// alertCounts is WorkAlertPolicy.counts: asks from the hub's enabled_at,
// requests and stops also from the work alerts' own start.
func alertCounts(c alertCandidate, enabledAt, startedAt time.Time) bool {
	from := enabledAt
	if c.event != eventAsk && startedAt.After(from) {
		from = startedAt
	}
	return !c.startedAt.Before(from)
}

// pushesWhileAway is WorkAlertPolicy.pushesWhileAway: an ask or a request
// always; a stop only when it began within 30 minutes before the departure.
func pushesWhileAway(c alertCandidate, awaySince time.Time) bool {
	if c.event == eventAsk || c.event == eventPermission {
		return true
	}
	return !c.startedAt.Before(awaySince.Add(-alertDepartureWin))
}

// coveredStopKeys is WorkAlertPolicy.coveredStopKeys: the stop keys of every
// dated session with an open ask or a pending request.
func coveredStopKeys(sessions []alertSession) []string {
	var out []string
	for _, s := range sessions {
		if !s.stateAt.IsZero() && (s.openAsks > 0 || s.pendingRequest) {
			out = append(out, stopKey(s.id, s.stateAt))
		}
	}
	return out
}

// stopKey is the Kit's WorkAlertKey.stop: whole unix milliseconds, rounded
// to the nearest.
func stopKey(session int64, at time.Time) string {
	secs := float64(at.Unix()) + float64(at.Nanosecond())/1e9
	return "stop-" + strconv.FormatInt(session, 10) + "-" + strconv.FormatInt(int64(math.Round(secs*1000)), 10)
}

// openAlertAsks is the open asks of the published workbenches with a
// readable created_at, outside the hidden sessions and author loops.
func openAlertAsks(ctx context.Context, tx *sql.Tx, names map[int64]string, hidden map[int64]bool) ([]alertAsk, error) {
	rows, err := tx.QueryContext(ctx, `SELECT a.id, a.project_id, a.session_id, a.kind, a.title, a.payload, a.created_at
		FROM owner_asks a WHERE a.status = 'open' AND `+askVisible+` ORDER BY a.id`)
	if err != nil {
		return nil, fmt.Errorf("reading open asks: %w", err)
	}
	defer rows.Close()
	var out []alertAsk
	for rows.Next() {
		var (
			a                alertAsk
			payload, created string
		)
		if err := rows.Scan(&a.id, &a.workbenchID, &a.sessionID, &a.kind, &a.title, &payload, &created); err != nil {
			return nil, fmt.Errorf("reading open asks: %w", err)
		}
		at := parseDate(created)
		if _, published := names[a.workbenchID]; !published || at == nil || (a.sessionID != nil && hidden[*a.sessionID]) {
			continue
		}
		a.createdAt = at.Time
		if a.kind == "question" {
			v, _ := storedJSON(payload, "ask_alert-ask-"+strconv.FormatInt(a.id, 10), "payload")
			a.quick = v != nil && quickAnswer(v) != nil
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading open asks: %w", err)
	}
	return out, nil
}
