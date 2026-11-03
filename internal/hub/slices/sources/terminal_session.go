package sources

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionstate"
)

// Caps of the terminal_session slice (TerminalSessionSlice).
const (
	newestSessionsPerWorkbench = 50
	maxSessionTitle            = 200
	maxStateCaption            = 120
	maxFinishSummary           = 2000
	maxAgentError              = 60
	maxPRLine                  = 120
)

// Liveness is what only the session host knows: the sessions whose process
// runs, each with its run's start (SessionLiveness.liveIDs + startedAt).
// Settled is false until the host's runs were listed once: before it a
// running session may be missing from Runs, so nothing may be written over
// a session for not being live (the permission requests' expiry).
type Liveness struct {
	Runs    map[int64]time.Time
	Settled bool
}

// ReportSummary is a session's line of `workbench session-report --summary`
// (the Swift SessionReportSummary): the target the report is about, its
// done/total leaves and the PR line.
type ReportSummary struct {
	TargetID *int64
	Done     int
	Total    int
	PRLine   string
}

// TerminalSessionOptions wires the terminal_session source. Liveness (nil =
// nothing live) is read once per Items; ReportSummary (nil = none) is the
// summary runner's last good summary of (workbench, session); Now (nil =
// time.Now) the time a background agent count is judged at (#411). View
// (nil = none) is what the Desktop reported it shows (desktop_view): the
// sessions waiting in its Undo batch (PROJ-17), never published, and the
// sessions whose background count it shows over (#411), published as the
// Mac shows them; read once per Items.
type TerminalSessionOptions struct {
	Liveness      func() Liveness
	ReportSummary func(workbenchID, sessionID int64) (ReportSummary, bool)
	Now           func() time.Time
	View          func() (hidden map[int64]bool, displayOver map[int64]ShownOver)
}

// ShownOver is a background count the Desktop shows over (the Swift
// ShownOverCount): the run it was judged for (zero = the session was not
// live) and the count's agent_background_at stamp ("" = none). It applies
// only while the row still holds that run and that report, so a newer report
// or another run is agents working again.
type ShownOver struct {
	Run        time.Time
	ReportedAt string
}

// holds reports whether the row (its live run, when live, and its report
// stamp) is the one the count was judged for. Runs compare at the agent-state
// stamp's millisecond precision.
func (o ShownOver) holds(run time.Time, live bool, reportedAt *string) bool {
	if live != !o.Run.IsZero() || (live && db.AgentStateStamp(run) != db.AgentStateStamp(o.Run)) {
		return false
	}
	if reportedAt == nil {
		return o.ReportedAt == ""
	}
	return *reportedAt == o.ReportedAt
}

// TerminalSessionSource is the `terminal_session` slice (mobile POC spec
// §4.5), record `terminal_session-<terminal_sessions.id>`: the agent
// sessions (claude and codex) of the published workbenches — every live one
// plus the newest 50 by last_active_at per workbench. Shell sessions are not
// published. The state fields are the Mac's presentation of the state
// sessionstate.Resolve gives (SessionStatePresentation); the caption carries
// no age, so a record does not change every minute. claude_session_id,
// folder_path and the raw hook columns are never published. Wire shape: the
// Kit mirror WatchtowerKit.TerminalSessionState. A session in the Desktop's
// Undo batch is left out (before the window, as the Swift slice), and a
// count the Desktop shows over resolves as over (TerminalSessionOptions.View).
type TerminalSessionSource struct {
	d *db.DB
	o TerminalSessionOptions
}

// TerminalSessions builds the terminal_session source; the workbench and
// session_timeline sources read its published sessions too.
func TerminalSessions(d *db.DB, o TerminalSessionOptions) *TerminalSessionSource {
	if o.Liveness == nil {
		o.Liveness = func() Liveness { return Liveness{} }
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.View == nil {
		o.View = func() (map[int64]bool, map[int64]ShownOver) { return nil, nil }
	}
	return &TerminalSessionSource{d: d, o: o}
}

// Kind is "terminal_session".
func (s *TerminalSessionSource) Kind() hubslices.Kind { return "terminal_session" }

type sessionPayload struct {
	ID                   int64      `json:"id"`
	WorkbenchID          int64      `json:"workbench_id"`
	Title                string     `json:"title"`
	TitleClipped         *bool      `json:"title_clipped,omitempty"`
	TargetID             *int64     `json:"target_id,omitempty"`
	Agent                string     `json:"agent"`
	CreatedAt            wire.Time  `json:"created_at"`
	LastActiveAt         wire.Time  `json:"last_active_at"`
	StateAt              *wire.Time `json:"state_at,omitempty"`
	Live                 bool       `json:"live"`
	StateKind            string     `json:"state_kind"`
	StateCaption         string     `json:"state_caption"`
	StateCaptionClipped  *bool      `json:"state_caption_clipped,omitempty"`
	StateTone            string     `json:"state_tone"`
	StateGlyph           string     `json:"state_glyph"`
	IsRing               bool       `json:"is_ring"`
	OpenAsks             int        `json:"open_asks"`
	OldestAskID          *int64     `json:"oldest_ask_id,omitempty"`
	ClosedAsks           int        `json:"closed_asks"`
	FinishSummary        string     `json:"finish_summary"`
	FinishSummaryClipped *bool      `json:"finish_summary_clipped,omitempty"`
	AgentError           string     `json:"agent_error"`
	AgentErrorClipped    *bool      `json:"agent_error_clipped,omitempty"`
	ReportTargetID       *int64     `json:"report_target_id,omitempty"`
	ReportDone           *int       `json:"report_done,omitempty"`
	ReportTotal          *int       `json:"report_total,omitempty"`
	ReportPRLine         *string    `json:"report_pr_line,omitempty"`
	ReportPRLineClipped  *bool      `json:"report_pr_line_clipped,omitempty"`
}

// publishedSession is one session of the window with its resolved state.
type publishedSession struct {
	id, workbenchID         int64
	agent                   agentkind.Kind
	title                   string
	targetID                *int64
	createdAt, lastActiveAt string
	finishSummary           string
	state                   sessionState
	stateAt                 *wire.Time
}

// Items publishes the window's sessions.
func (s *TerminalSessionSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	var items []hubslices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		published, err := s.published(ctx, tx)
		if err != nil || len(published) == 0 {
			return err
		}
		closed, err := closedAskCounts(ctx, tx)
		if err != nil {
			return err
		}
		for _, p := range published {
			b, err := wire.Marshal(s.payload(p, closed[p.id]))
			if err != nil {
				return err
			}
			items = append(items, hubslices.Item{ID: strconv.FormatInt(p.id, 10), Payload: b})
		}
		return nil
	})
	return items, err
}

func (s *TerminalSessionSource) payload(p publishedSession, closedAsks int) sessionPayload {
	record := "terminal_session-" + strconv.FormatInt(p.id, 10)
	st := p.state
	title, titleClipped := clipText(p.title, maxSessionTitle)
	caption, captionClipped := clipText(st.caption(), maxStateCaption)
	finish, finishClipped := clipText(p.finishSummary, maxFinishSummary)
	agentErr, agentErrClipped := clipText(st.err, maxAgentError)
	out := sessionPayload{
		ID: p.id, WorkbenchID: p.workbenchID,
		Title: title, TitleClipped: titleClipped,
		TargetID:     p.targetID,
		Agent:        wireAgent(p.agent),
		CreatedAt:    requiredDate(p.createdAt, "created_at", record),
		LastActiveAt: requiredDate(p.lastActiveAt, "last_active_at", record),
		StateAt:      p.stateAt,
		Live:         st.live,
		StateKind:    st.wireKind(),
		StateCaption: caption, StateCaptionClipped: captionClipped,
		StateTone:     st.tone(),
		StateGlyph:    st.glyph(),
		IsRing:        !st.live,
		OpenAsks:      st.openAsks,
		OldestAskID:   st.oldestAskID,
		ClosedAsks:    closedAsks,
		FinishSummary: finish, FinishSummaryClipped: finishClipped,
		AgentError: agentErr, AgentErrorClipped: agentErrClipped,
	}
	if s.o.ReportSummary != nil {
		if sum, ok := s.o.ReportSummary(p.workbenchID, p.id); ok {
			line, lineClipped := clipText(sum.PRLine, maxPRLine)
			done, total := sum.Done, sum.Total
			out.ReportTargetID, out.ReportDone, out.ReportTotal = sum.TargetID, &done, &total
			out.ReportPRLine, out.ReportPRLineClipped = &line, lineClipped
		}
	}
	return out
}

// counts is the workbench slice's session_counts over the published
// sessions: working counts working, running and agents working (all green),
// waiting counts waiting on an ask and ready to check, not_running counts
// not started.
func (s *TerminalSessionSource) counts(ctx context.Context, tx *sql.Tx) (map[int64]sessionCounts, error) {
	published, err := s.published(ctx, tx)
	if err != nil {
		return nil, err
	}
	out := map[int64]sessionCounts{}
	for _, p := range published {
		c := out[p.workbenchID]
		switch p.state.kind {
		case kindWorking, kindRunning, kindBackground:
			c.Working++
		case kindWaitingOnAsk, kindReadyToCheck:
			c.Waiting++
		case kindNeedsApproval:
			c.NeedsApproval++
		case kindFinished:
			c.Finished++
		case kindFailed:
			c.Failed++
		case kindStopped:
			c.Stopped++
		case kindNotStarted:
			c.NotRunning++
		}
		out[p.workbenchID] = c
	}
	return out, nil
}

// published is TerminalSessionSlice.publishedSessions: the published
// workbenches' agent sessions, every live one plus the newest 50 per
// workbench, in last_active_at order, each with its resolved state.
func (s *TerminalSessionSource) published(ctx context.Context, tx *sql.Tx) ([]publishedSession, error) {
	refs, err := publishedRefs(ctx, tx)
	if err != nil || len(refs) == 0 {
		return nil, err
	}
	workbenches := make(map[int64]bool, len(refs))
	for _, r := range refs {
		workbenches[r.id] = true
	}
	live := s.o.Liveness()
	hidden, over := s.o.View()
	now := s.o.Now()
	seen := map[int64]int{}
	var out []publishedSession
	err = scanRows(ctx, tx, `
SELECT s.id, s.project_id, s.kind, s.title, s.target_id, s.created_at, s.last_active_at,
       s.agent_state, s.agent_state_at, s.finished_at, s.finish_summary, s.agent_failed_at, s.agent_error,
       s.agent_background, s.agent_background_at,
       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open' AND `+askVisible+`),
       (SELECT MIN(a.id) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open' AND `+askVisible+`),
       (SELECT COUNT(*) FROM owner_asks a
        WHERE a.session_id = s.id AND a.status = 'open' AND `+askVisible+` AND a.kind = 'question'),
       (SELECT COUNT(*) FROM owner_asks a
        WHERE a.session_id = s.id AND a.status = 'open' AND `+askVisible+` AND a.kind = 'review')
FROM terminal_sessions s
WHERE s.project_id IS NOT NULL AND s.kind IN ('claude','codex')
ORDER BY s.last_active_at DESC, s.id DESC`, nil, func(r *sql.Rows) error {
		var (
			p                publishedSession
			kind, agentError string
			target, oldest   sql.NullInt64
			row              sessionstate.Row
		)
		if err := r.Scan(&p.id, &p.workbenchID, &kind, &p.title, &target, &p.createdAt, &p.lastActiveAt,
			&row.AgentState, &row.AgentStateAt, &row.FinishedAt, &p.finishSummary, &row.AgentFailedAt, &agentError,
			&row.AgentBackground, &row.AgentBackgroundAt,
			&row.OpenAsks, &oldest, &row.OpenQuestionAsks, &row.OpenReviewAsks); err != nil {
			return err
		}
		if !workbenches[p.workbenchID] || hidden[p.id] {
			return nil
		}
		start, isLive := live.Runs[p.id]
		rank := seen[p.workbenchID]
		seen[p.workbenchID] = rank + 1
		if rank >= newestSessionsPerWorkbench && !isLive {
			return nil
		}
		p.agent, _ = agentkind.Parse(kind)
		p.targetID = nullInt(target)
		row.ID, row.Kind = p.id, kind
		if so, ok := over[p.id]; ok {
			row.DisplayOver = so.holds(start, isLive, row.AgentBackgroundAt)
		}
		if isLive {
			row.RunStartedAt = db.AgentStateStamp(start)
		}
		p.state = resolveState(row, now, agentError, nullInt(oldest))
		p.stateAt = stateAt(row, p.state)
		out = append(out, p)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("reading the sessions: %w", err)
	}
	return out, nil
}

// stateAt is TerminalSessionSlice.stateAt: the trusted hook stamp, else a
// finished session's finished_at (also one that reads Ready to check, #534);
// nil when unknown.
func stateAt(r sessionstate.Row, st sessionState) *wire.Time {
	if at := sessionstate.TrustedHookAt(r); at != "" {
		return parseDate(at)
	}
	if (st.kind == kindFinished || st.kind == kindReadyToCheck) && r.FinishedAt != nil {
		return parseDate(*r.FinishedAt)
	}
	return nil
}

// closedAskCounts is OwnerAskQueries.closedCounts per session: its
// answered, delivered and withdrawn asks on its own workbench.
func closedAskCounts(ctx context.Context, tx *sql.Tx) (map[int64]int, error) {
	out := map[int64]int{}
	err := scanRows(ctx, tx, `
SELECT a.session_id, COUNT(*) FROM owner_asks a
JOIN terminal_sessions s ON s.id = a.session_id AND s.project_id = a.project_id
WHERE a.status != 'open' AND `+askVisible+`
GROUP BY a.session_id`, nil, func(r *sql.Rows) error {
		var id int64
		var n int
		if err := r.Scan(&id, &n); err != nil {
			return err
		}
		out[id] = n
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("reading closed asks: %w", err)
	}
	return out, nil
}

// sessionKind is SessionSwitcherPresentation.State.Kind.
type sessionKind int

const (
	kindNotStarted sessionKind = iota
	kindRunning
	kindWorking
	kindNeedsApproval
	kindFailed
	kindWaitingOnAsk
	kindStopped
	kindFinished
	kindBackground
	kindReadyToCheck
)

// sessionState is SessionSwitcherPresentation.State: the resolved kind with
// what its presentation names.
type sessionState struct {
	kind                     sessionKind
	live                     bool
	openAsks                 int
	openQuestion, openReview int
	err                      string // agent_error of a failed turn
	oldestAskID              *int64 // nil without open asks
	agents                   int    // background agents of a background session
}

// resolveState maps sessionstate.Resolve's state onto the presentation
// state, the way SessionAgentStatus.effective builds it.
func resolveState(r sessionstate.Row, now time.Time, agentError string, oldest *int64) sessionState {
	st := sessionState{
		live: r.RunStartedAt != "", openAsks: r.OpenAsks,
		openQuestion: r.OpenQuestionAsks, openReview: r.OpenReviewAsks,
	}
	if r.OpenAsks > 0 {
		st.oldestAskID = oldest
	}
	switch sessionstate.Resolve(r, now) {
	case sessionstate.StateNotStarted:
		st.kind = kindNotStarted
	case sessionstate.StateRunning, sessionstate.StateMarkedIdle:
		st.kind = kindRunning
	case sessionstate.StateWorking:
		st.kind = kindWorking
	case sessionstate.StateAgentsWorking:
		st.kind = kindBackground
		if r.AgentBackground != nil {
			st.agents = *r.AgentBackground
		}
	case sessionstate.StateNeedsApproval:
		st.kind = kindNeedsApproval
	case sessionstate.StateError:
		st.kind = kindFailed
		st.err = agentError
	case sessionstate.StateStopped:
		st.kind = kindStopped
	case sessionstate.StateWaitingForYou:
		st.kind = kindWaitingOnAsk
	case sessionstate.StateReadyToCheck:
		st.kind = kindReadyToCheck
	case sessionstate.StateFinished:
		st.kind = kindFinished
	}
	return st
}

func (st sessionState) asksAreOnlyChecks() bool { return st.openAsks > 0 && st.openQuestion == 0 }
func (st sessionState) asksAreOnlyReviews() bool {
	return st.asksAreOnlyChecks() && st.openReview == st.openAsks
}

// wireKind is TerminalSessionSlice.wire(kind): agents working has no wire
// kind of its own and goes out as working.
func (st sessionState) wireKind() string {
	switch st.kind {
	case kindWorking, kindBackground:
		return "working"
	case kindRunning:
		return "running"
	case kindWaitingOnAsk:
		return "waiting_on_ask"
	case kindReadyToCheck:
		return "ready_to_check"
	case kindNeedsApproval:
		return "needs_approval"
	case kindFinished:
		return "finished"
	case kindStopped:
		return "stopped"
	case kindFailed:
		return "failed"
	case kindNotStarted:
	}
	return "not_started"
}

// tone is SessionStatePresentation.color.
func (st sessionState) tone() string {
	switch st.kind {
	case kindWorking, kindRunning, kindBackground:
		return "green"
	case kindWaitingOnAsk, kindNeedsApproval:
		return "orange"
	case kindReadyToCheck:
		return "purple"
	case kindFinished:
		if st.openAsks > 0 {
			return "orange"
		}
		return "blue"
	case kindFailed:
		return "red"
	case kindStopped, kindNotStarted:
	}
	return "secondary"
}

// glyph is SessionStatePresentation.glyph ("" for none).
func (st sessionState) glyph() string {
	askGlyph := "questionmark"
	if st.asksAreOnlyChecks() {
		askGlyph = "checklist"
	}
	switch st.kind {
	case kindWorking:
		if st.openAsks > 0 {
			return askGlyph
		}
	case kindBackground:
		if st.openAsks > 0 {
			return askGlyph
		}
		return "person.2.fill"
	case kindWaitingOnAsk:
		return "questionmark"
	case kindReadyToCheck:
		return "checklist"
	case kindNeedsApproval:
		return "hand.raised.fill"
	case kindFinished:
		return "checkmark"
	case kindStopped:
		return "pause.fill"
	case kindFailed:
		return "exclamationmark"
	case kindRunning, kindNotStarted:
	}
	return ""
}

// caption is SessionStatePresentation.caption with the state's own oldest
// open ask.
func (st sessionState) caption() string {
	switch st.kind {
	case kindWorking:
		if st.openAsks > 0 {
			return "Working · " + asksOpen(st.openAsks)
		}
		return "Working"
	case kindWaitingOnAsk:
		return "Waiting for you" + st.askSuffix()
	case kindReadyToCheck:
		if st.asksAreOnlyReviews() {
			return "Ready for review" + st.askSuffix()
		}
		return "Ready to check" + st.askSuffix()
	case kindNeedsApproval:
		return "Needs approval"
	case kindFinished:
		if st.openAsks > 0 {
			return "Finished · " + asksOpen(st.openAsks)
		}
		return "Finished"
	case kindStopped:
		return "Stopped"
	case kindBackground:
		agents := "Agents working"
		switch {
		case st.agents == 1:
			agents = "1 agent working"
		case st.agents > 1:
			agents = strconv.Itoa(st.agents) + " agents working"
		}
		if st.openAsks > 0 {
			return agents + " · " + asksOpen(st.openAsks)
		}
		return agents
	case kindFailed:
		words := strings.TrimFunc(strings.ReplaceAll(st.err, "_", " "), isSwiftWhitespace)
		if words == "" {
			return "Stopped on an error"
		}
		return "Error: " + words
	case kindRunning:
		return "Running"
	case kindNotStarted:
	}
	return "Not running"
}

// askSuffix is " · ask #12 · 3 asks": the ask named, the count when more
// than one.
func (st sessionState) askSuffix() string {
	var b strings.Builder
	if st.oldestAskID != nil {
		b.WriteString(" · ask #" + strconv.FormatInt(*st.oldestAskID, 10))
	}
	if st.openAsks > 1 {
		b.WriteString(" · " + strconv.Itoa(st.openAsks) + " asks")
	}
	return b.String()
}

func asksOpen(n int) string {
	if n == 1 {
		return "1 ask open"
	}
	return strconv.Itoa(n) + " asks open"
}

// isSwiftWhitespace is CharacterSet.whitespaces: the space separators (Zs)
// and the tab, never a line break.
func isSwiftWhitespace(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) }
