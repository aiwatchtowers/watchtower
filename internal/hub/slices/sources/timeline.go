package sources

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"sort"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionreport"
)

// The session_timeline slice's caps and the sidecar's milestone rules
// (SessionTimelineSlice, HubSyncState).
const (
	maxMilestones        = 100
	maxMilestoneText     = 200
	milestonesPerSession = 100
	milestoneLifetime    = 14 * 24 * time.Hour
	reportWindow         = 7 * 24 * time.Hour
	// milestoneTextLabel is the SealLocal label of session_milestones.text.
	milestoneTextLabel = "session_milestones.text"
)

// LocalSealer seals and opens a sidecar content value under the hub's wrap
// key (identity.Keyring's SealLocal/OpenLocal).
type LocalSealer interface {
	SealLocal(label string, plain []byte) ([]byte, error)
	OpenLocal(label string, sealed []byte) ([]byte, error)
}

// TimelineOptions wires the session_timeline source. Sessions gives the
// window and the resolved states; Store and Sealer hold the hub-observed
// state milestones (session_milestones, text sealed under
// milestoneTextLabel); Reports (nil = none) returns the stored session
// reports by session id, whose phases and pull requests become milestones;
// Now (nil = time.Now) is the clock of the window, the transitions and the
// 14-day pruning.
type TimelineOptions struct {
	Sessions *TerminalSessionSource
	Store    *state.Store
	Sealer   LocalSealer
	Reports  func(ctx context.Context) (map[int64]sessionreport.Report, error)
	Now      func() time.Time
}

// SessionTimeline is the `session_timeline` slice (mobile POC spec §4.9),
// record `session_timeline-<terminal_sessions.id>`: a session's milestones,
// newest first, at most 100 (milestones_more for the rest), each {at, kind,
// text ≤ 200, ref} with ref a target or ask id. The window is the
// terminal_session window's sessions that are live or were active in the
// last 7 days; a session with no milestone still gets its record with an
// empty list. Sources:
//   - state: the transitions the hub observed, written by this source into
//     the sidecar's session_milestones (text sealed) whenever a session's
//     state text differs from its last stored one — the first sighting at
//     the state's own time, a transition at the time it was seen;
//   - ask_opened / ask_answered / ask_withdrawn: the session's owner_asks;
//   - target_linked: terminal_session_targets.first_at;
//   - target_status: the status moves of the linked targets (and the
//     session's own) from the session's created_at on;
//   - phase and pr: the stored session report;
//   - finished: finished_at with finish_summary.
//
// No subagent events and never the transcript or terminal text (I-4). Wire
// shape: the Kit mirror WatchtowerKit.SessionTimeline.
//
// Both Items and Observe write the sidecar (session_milestones): only the
// hub, holding the hub lock (state.AcquireLock), may call them — never a CLI
// or preview path. Sessions, Store and Sealer are required.
func SessionTimeline(d *db.DB, o TimelineOptions) (*TimelineSource, error) {
	switch {
	case d == nil:
		return nil, errors.New("hub slices: session_timeline needs the database")
	case o.Sessions == nil:
		return nil, errors.New("hub slices: session_timeline needs the terminal_session source")
	case o.Store == nil:
		return nil, errors.New("hub slices: session_timeline needs the hub state")
	case o.Sealer == nil:
		return nil, errors.New("hub slices: session_timeline needs a sealer")
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &TimelineSource{d: d, o: o}, nil
}

// TimelineSource is the session_timeline source (SessionTimeline).
type TimelineSource struct {
	d *db.DB
	o TimelineOptions
}

// Kind is "session_timeline".
func (s *TimelineSource) Kind() hubslices.Kind { return "session_timeline" }

// Milestone kinds: the Kit's SessionTimeline.Milestone.Kind values, and
// nothing beyond them (no subagent kind).
const (
	msState        = "state"
	msAskOpened    = "ask_opened"
	msAskAnswered  = "ask_answered"
	msAskWithdrawn = "ask_withdrawn"
	msTargetLinked = "target_linked"
	msTargetStatus = "target_status"
	msPhase        = "phase"
	msPR           = "pr"
	msFinished     = "finished"
)

type milestonePayload struct {
	At          wire.Time `json:"at"`
	Kind        string    `json:"kind"`
	Text        string    `json:"text"`
	TextClipped *bool     `json:"text_clipped,omitempty"`
	Ref         *int64    `json:"ref,omitempty"`
}

type timelinePayload struct {
	SessionID      int64              `json:"session_id"`
	Milestones     []milestonePayload `json:"milestones"`
	MilestonesMore *int               `json:"milestones_more,omitempty"`
}

// rawMilestone is one milestone before the cap and the clip.
type rawMilestone struct {
	at   time.Time
	kind string
	text string
	ref  *int64
}

// windowed is one session of the report and timeline window.
type windowed struct {
	id           int64
	workbenchID  int64
	createdAt    *time.Time
	lastActiveAt time.Time
	state        sessionState
	stateAt      *time.Time
	rows         []rawMilestone
}

// Observe records a state milestone for each windowed session whose state
// text changed since its newest stored one, the transition stamped
// changedAt (when the hub first saw the change; the newest stored time if
// that is later). The runtime calls it on a session-state change seen on the
// fast lane, so a state shorter than a publish cycle still becomes a
// milestone at its own time; Items observes too, as the fallback. It also
// prunes the sidecar (14 days, 100 per session).
func (s *TimelineSource) Observe(ctx context.Context, changedAt time.Time) error {
	window, err := s.window(ctx, s.o.Now(), false)
	if err != nil {
		return err
	}
	_, err = s.observe(ctx, window, changedAt)
	return err
}

// Items publishes the window's timelines, observing the states first.
func (s *TimelineSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	now := s.o.Now()
	window, err := s.window(ctx, now, true)
	if err != nil {
		return nil, err
	}
	// Observed even with an empty window: the pass also prunes the sidecar.
	states, err := s.observe(ctx, window, now)
	if err != nil || len(window) == 0 {
		return nil, err
	}
	var reports map[int64]sessionreport.Report
	if s.o.Reports != nil {
		if reports, err = s.o.Reports(ctx); err != nil {
			return nil, fmt.Errorf("reading the session reports: %w", err)
		}
	}
	items := make([]hubslices.Item, 0, len(window))
	for _, w := range window {
		raw := append(states[w.id], w.rows...)
		if rep, ok := reports[w.id]; ok {
			raw = append(raw, reportMilestones(rep)...)
		}
		b, err := wire.Marshal(timelineOf(w.id, raw))
		if err != nil {
			return nil, err
		}
		items = append(items, hubslices.Item{ID: strconv.FormatInt(w.id, 10), Payload: b})
	}
	return items, nil
}

// window is sessionWindow over this source's database and sessions.
func (s *TimelineSource) window(ctx context.Context, now time.Time, withRows bool) ([]windowed, error) {
	return sessionWindow(ctx, s.d, s.o.Sessions, now, withRows)
}

// sessionWindow is SessionReportSlice.window, the window of both
// session_report and session_timeline: the terminal_session window's
// sessions that are live or were active in the last 7 days, with their row
// milestones when withRows.
func sessionWindow(ctx context.Context, d *db.DB, sessions *TerminalSessionSource, now time.Time, withRows bool) ([]windowed, error) {
	var window []windowed
	err := readTx(ctx, d, func(tx *sql.Tx) error {
		published, err := sessions.published(ctx, tx)
		if err != nil {
			return err
		}
		cutoff := now.Add(-reportWindow)
		for _, p := range published {
			last := time.Unix(0, 0).UTC()
			if t := parseDate(p.lastActiveAt); t != nil {
				last = t.Time
			}
			if !p.state.live && last.Before(cutoff) {
				continue
			}
			w := windowed{id: p.id, workbenchID: p.workbenchID, lastActiveAt: last, state: p.state}
			if t := parseDate(p.createdAt); t != nil {
				w.createdAt = &t.Time
			}
			if p.stateAt != nil {
				w.stateAt = &p.stateAt.Time
			}
			if withRows {
				if w.rows, err = rowMilestones(ctx, tx, w); err != nil {
					return err
				}
			}
			window = append(window, w)
		}
		return nil
	})
	return window, err
}

// timelineOf is SessionTimelineSlice.payload: newest first (ties keep their
// source order), the newest 100, texts clipped at 200.
func timelineOf(sessionID int64, raw []rawMilestone) timelinePayload {
	sort.SliceStable(raw, func(i, j int) bool { return raw[i].at.After(raw[j].at) })
	kept, more := clipList(raw, maxMilestones)
	out := timelinePayload{SessionID: sessionID, Milestones: make([]milestonePayload, 0, len(kept)), MilestonesMore: more}
	for _, m := range kept {
		text, clipped := clipText(m.text, maxMilestoneText)
		out.Milestones = append(out.Milestones, milestonePayload{
			At: wire.Time{Time: m.at}, Kind: m.kind, Text: text, TextClipped: clipped, Ref: m.ref,
		})
	}
	return out
}

// stateText is SessionTimelineSlice.stateText: the text of a resolved
// state's milestone; "" for a session never started (no milestone).
func stateText(st sessionState) string {
	switch st.kind {
	case kindRunning:
		return "Started"
	case kindWorking:
		return "Working"
	case kindBackground:
		return "Agents working"
	case kindWaitingOnAsk:
		return "Waiting for you"
	case kindReadyToCheck:
		if st.asksAreOnlyReviews() {
			return "Ready for review"
		}
		return "Ready to check"
	case kindNeedsApproval:
		return "Needs approval"
	case kindFinished:
		return "Finished"
	case kindStopped:
		return "Stopped"
	case kindFailed:
		// "Error: rate limit", or "Stopped on an error".
		return st.caption()
	case kindNotStarted:
	}
	return ""
}

// storedMilestone is a session_milestones row with its text opened.
type storedMilestone struct {
	at   time.Time
	text string
}

var unreadableMilestones sync.Once

// observe records a state milestone for each windowed session whose state
// text differs from its newest stored one, prunes the milestones past 14
// days and past a session's newest 100, and returns every stored state
// milestone by session, newest first — one sidecar transaction. at is the
// transition time (when the change was seen).
func (s *TimelineSource) observe(ctx context.Context, window []windowed, at time.Time) (map[int64][]rawMilestone, error) {
	out := map[int64][]rawMilestone{}
	err := s.o.Store.WithTx(ctx, func(tx *sql.Tx) error {
		stored, err := s.storedMilestones(tx)
		if err != nil {
			return err
		}
		cutoff := s.o.Now().Add(-milestoneLifetime)
		for _, w := range window {
			text := stateText(w.state)
			if text == "" {
				continue
			}
			var when time.Time
			if prev := stored[w.id]; len(prev) > 0 {
				if prev[0].text == text {
					continue
				}
				when = at
				if prev[0].at.After(at) {
					when = prev[0].at
				}
			} else {
				// First sighting: the state's own time.
				when = w.lastActiveAt
				if w.stateAt != nil {
					when = *w.stateAt
				}
				if when.Before(cutoff) {
					continue
				}
			}
			sealed, err := s.o.Sealer.SealLocal(milestoneTextLabel, []byte(text))
			if err != nil {
				return fmt.Errorf("sealing a milestone: %w", err)
			}
			if err := state.InsertMilestone(tx, w.id, when, sealed); err != nil {
				return err
			}
		}
		if err := state.PruneMilestones(tx, cutoff, milestonesPerSession); err != nil {
			return err
		}
		if stored, err = s.storedMilestones(tx); err != nil {
			return err
		}
		for id, list := range stored {
			for _, m := range list {
				out[id] = append(out[id], rawMilestone{at: m.at, kind: msState, text: m.text})
			}
		}
		return nil
	})
	return out, err
}

// storedMilestones reads every state milestone by session, newest first,
// opened. A text that does not open (an adopted Swift sidecar's plaintext
// row, another hub's key) is deleted on sight, so it neither hides behind a
// first sighting nor counts toward the 100-per-session trim.
func (s *TimelineSource) storedMilestones(tx *sql.Tx) (map[int64][]storedMilestone, error) {
	rows, err := state.Milestones(tx)
	if err != nil {
		return nil, err
	}
	out := map[int64][]storedMilestone{}
	for _, m := range rows {
		text, err := s.o.Sealer.OpenLocal(milestoneTextLabel, m.Text)
		if err != nil {
			unreadableMilestones.Do(func() { log.Printf("hub slices: stored milestones that do not open are deleted") })
			if err := state.DeleteMilestone(tx, m.RowID); err != nil {
				return nil, err
			}
			continue
		}
		out[m.SessionID] = append(out[m.SessionID], storedMilestone{at: m.At, text: string(text)})
	}
	return out, nil
}

// rowMilestones is SessionTimelineSlice.rowMilestones: the asks, target
// links and status moves, and the finish of one session.
func rowMilestones(ctx context.Context, tx *sql.Tx, w windowed) ([]rawMilestone, error) {
	var out []rawMilestone
	err := scanRows(ctx, tx, `
SELECT a.id, a.title, a.status, a.withdrawn_reason, a.created_at, a.answered_at,
       COALESCE((SELECT MIN(n.created_at) FROM owner_asks n WHERE n.previous_ask_id = a.id), '')
FROM owner_asks a WHERE a.session_id = ? AND `+askVisible+` ORDER BY a.id`, []any{w.id},
		func(r *sql.Rows) error {
			var (
				id                                       int64
				title, status, reason, created, answered string
				superseded                               string
			)
			if err := r.Scan(&id, &title, &status, &reason, &created, &answered, &superseded); err != nil {
				return err
			}
			ref := &id
			createdAt := parseDate(created)
			if createdAt != nil {
				out = append(out, rawMilestone{at: createdAt.Time, kind: msAskOpened, text: "Asked: " + title, ref: ref})
			}
			if t := parseDate(answered); t != nil {
				out = append(out, rawMilestone{at: t.Time, kind: msAskAnswered, text: "Answered: " + title, ref: ref})
			}
			if status == "withdrawn" {
				at := parseDate(superseded)
				if at == nil {
					at = createdAt
				}
				if at != nil {
					text := "Withdrawn: " + title
					if reason == "superseded" {
						text = "Superseded: " + title
					}
					out = append(out, rawMilestone{at: at.Time, kind: msAskWithdrawn, text: text, ref: ref})
				}
			}
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("reading session asks: %w", err)
	}
	err = scanRows(ctx, tx, `
SELECT l.target_id, l.first_at, t.text FROM terminal_session_targets l
JOIN targets t ON t.id = l.target_id
WHERE l.session_id = ? ORDER BY l.first_at, l.target_id`, []any{w.id}, func(r *sql.Rows) error {
		var (
			target      int64
			first, text string
		)
		if err := r.Scan(&target, &first, &text); err != nil {
			return err
		}
		if t := parseDate(first); t != nil {
			out = append(out, rawMilestone{at: t.Time, kind: msTargetLinked, text: "Linked: " + text, ref: &target})
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("reading session links: %w", err)
	}
	if w.createdAt != nil {
		err = scanRows(ctx, tx, `
SELECT h.target_id, COALESCE(h.from_status, 'new'), h.to_status, h.actor, h.changed_at FROM target_status_history h
WHERE h.target_id IN (
    SELECT target_id FROM terminal_session_targets WHERE session_id = ?1
    UNION SELECT target_id FROM terminal_sessions WHERE id = ?1 AND target_id IS NOT NULL
)
ORDER BY h.changed_at, h.id`, []any{w.id}, func(r *sql.Rows) error {
			var (
				target                     int64
				from, to, actor, changedAt string
			)
			if err := r.Scan(&target, &from, &to, &actor, &changedAt); err != nil {
				return err
			}
			if t := parseDate(changedAt); t != nil && !t.Before(*w.createdAt) {
				out = append(out, rawMilestone{at: t.Time, kind: msTargetStatus, text: from + " → " + to + " (" + actor + ")", ref: &target})
			}
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("reading target status history: %w", err)
		}
	}
	var finishedAt sql.NullString
	var summary string
	if err := tx.QueryRowContext(ctx, `SELECT finished_at, finish_summary FROM terminal_sessions WHERE id = ?`, w.id).
		Scan(&finishedAt, &summary); err != nil {
		return nil, fmt.Errorf("reading the session finish: %w", err)
	}
	if t := parseDate(finishedAt.String); finishedAt.Valid && t != nil {
		text := "Finished"
		if summary != "" {
			text = "Finished: " + summary
		}
		out = append(out, rawMilestone{at: t.Time, kind: msFinished, text: text})
	}
	return out, nil
}

// reportMilestones: phase at each phase's started_at and finished_at, pr at
// each pull request's merged_at, else checked_at (a branch entry has no PR
// and no milestone).
func reportMilestones(rep sessionreport.Report) []rawMilestone {
	var out []rawMilestone
	for _, ph := range rep.Phases {
		ref := ph.TargetID
		if t := parseDate(ph.StartedAt); t != nil {
			out = append(out, rawMilestone{at: t.Time, kind: msPhase, text: "Started: " + ph.Text, ref: &ref})
		}
		if t := parseDate(ph.FinishedAt); t != nil {
			out = append(out, rawMilestone{at: t.Time, kind: msPhase, text: "Done: " + ph.Text, ref: &ref})
		}
	}
	for _, pr := range rep.PRs {
		if pr.PRNumber == nil {
			continue
		}
		at := parseDate(pr.MergedAt)
		if at == nil {
			at = parseDate(pr.CheckedAt)
		}
		if at == nil {
			continue
		}
		title := ""
		if pr.Title != "" {
			title = ": " + pr.Title
		}
		var ref *int64
		if len(pr.Targets) > 0 {
			first := pr.Targets[0]
			ref = &first
		}
		out = append(out, rawMilestone{
			at: at.Time, kind: msPR, text: "PR #" + strconv.FormatInt(*pr.PRNumber, 10) + " " + pr.State + title, ref: ref,
		})
	}
	return out
}
