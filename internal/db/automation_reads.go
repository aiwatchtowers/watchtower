package db

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// Read helpers for the automation surface's local-store tools (spec
// 2026-10-14-automations-design §6.1, §20.1 D23). Each is one read
// statement — no transaction, no write. Every time bound is an RFC 3339 UTC
// instant ("2006-01-02T15:04:05Z", "" = no bound), compared as text against
// columns every writer (Go and the Desktop) stores in that same UTC form —
// except meeting_notes, whose Desktop edits write datetime('now')
// ("YYYY-MM-DD HH:MM:SS"), so its times are normalised in SQL
// (utcColumnExpr). Every Limit must be positive (the tools clamp it to
// 1..200).

// readWhere accumulates AND-ed conditions and their arguments.
type readWhere struct {
	conds []string
	args  []any
}

func (w *readWhere) add(cond string, args ...any) {
	w.conds = append(w.conds, cond)
	w.args = append(w.args, args...)
}

func (w *readWhere) clause() string {
	if len(w.conds) == 0 {
		return ""
	}
	return " WHERE " + strings.Join(w.conds, " AND ")
}

// utcColumnExpr normalises a UTC datetime column written either as
// "YYYY-MM-DD HH:MM:SS" (SQLite datetime('now')) or "YYYY-MM-DDTHH:MM:SSZ"
// to the latter, so text comparison and ordering stay correct; a value
// strftime cannot parse is kept as stored.
func utcColumnExpr(col string) string {
	return `COALESCE(strftime('%Y-%m-%dT%H:%M:%SZ', ` + col + `), ` + col + `)`
}

func positiveLimit(what string, n int) error {
	if n <= 0 {
		return fmt.Errorf("%s: limit must be positive, got %d", what, n)
	}
	return nil
}

// InboxReadQuery filters ListInboxForAutomation. Status "" = every status;
// archived rows are always excluded. Since bounds created_at (inclusive).
type InboxReadQuery struct {
	Status, Priority, TriggerType, Since string
	Limit                                int
}

// ListInboxForAutomation returns non-archived inbox items, newest first.
func (db *DB) ListInboxForAutomation(ctx context.Context, q InboxReadQuery) ([]InboxItem, error) {
	if err := positiveLimit("listing inbox items", q.Limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	w.add("archived_at IS NULL")
	for _, f := range [][2]string{{"status", q.Status}, {"priority", q.Priority}, {"trigger_type", q.TriggerType}} {
		if f[1] != "" {
			w.add(f[0]+" = ?", f[1])
		}
	}
	if q.Since != "" {
		w.add("created_at >= ?", q.Since)
	}
	rows, err := db.QueryContext(ctx, `SELECT `+inboxSelectCols+` FROM inbox_items`+w.clause()+
		` ORDER BY created_at DESC, id DESC LIMIT ?`, append(w.args, q.Limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing inbox items: %w", err)
	}
	defer func() { _ = rows.Close() }()
	items, err := scanInboxItems(rows)
	if err != nil {
		return nil, fmt.Errorf("listing inbox items: %w", err)
	}
	return items, nil
}

// CalendarRangeQuery filters ListCalendarEventsRange: start_time in
// [From, To). A non-nil account filter (GoogleAccountIDs, CalendarIDs) keeps
// only events of those Google accounts' calendars or of those calendar ids
// (the "caldav:<id>"/"ics:<id>" rows); both empty with Filtered = nothing.
type CalendarRangeQuery struct {
	From, To         string
	Filtered         bool
	GoogleAccountIDs []int64
	CalendarIDs      []string
	Limit            int
}

// CalendarRangeEvent is one event with its calendar's name and the account
// it belongs to (a Google account's label, else address; a calendar
// account's label).
type CalendarRangeEvent struct {
	CalendarEvent
	CalendarName string
	Account      string
}

// ListCalendarEventsRange returns the events starting in [From, To) — past
// and cancelled included — in start order.
func (db *DB) ListCalendarEventsRange(ctx context.Context, q CalendarRangeQuery) ([]CalendarRangeEvent, error) {
	if err := positiveLimit("listing calendar events", q.Limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	w.add("e.start_time >= ? AND e.start_time < ?", q.From, q.To)
	if q.Filtered {
		w.add(calendarAccountCond(q.GoogleAccountIDs, q.CalendarIDs), calendarAccountArgs(q.GoogleAccountIDs, q.CalendarIDs)...)
	}
	rows, err := db.QueryContext(ctx, `SELECT e.id, e.calendar_id, e.title, e.description, e.location,
		e.start_time, e.end_time, e.organizer_email, e.attendees, e.is_all_day, e.event_status,
		e.html_link, e.conference_url, COALESCE(c.name, ''),
		COALESCE(NULLIF(g.label, ''), g.email, ca.label, '')
		FROM calendar_events e
		LEFT JOIN calendar_calendars c ON c.id = e.calendar_id
		LEFT JOIN google_accounts g ON g.id = c.account_id
		LEFT JOIN calendar_accounts ca ON e.calendar_id = ca.provider || ':' || ca.id`+w.clause()+
		` ORDER BY e.start_time, e.id LIMIT ?`, append(w.args, q.Limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing calendar events: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []CalendarRangeEvent{}
	for rows.Next() {
		var e CalendarRangeEvent
		if err := rows.Scan(&e.ID, &e.CalendarID, &e.Title, &e.Description, &e.Location, &e.StartTime, &e.EndTime,
			&e.OrganizerEmail, &e.Attendees, &e.IsAllDay, &e.EventStatus, &e.HTMLLink, &e.ConferenceURL,
			&e.CalendarName, &e.Account); err != nil {
			return nil, fmt.Errorf("scanning calendar event: %w", err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing calendar events: %w", err)
	}
	return out, nil
}

func calendarAccountCond(googleIDs []int64, calendarIDs []string) string {
	if len(googleIDs)+len(calendarIDs) == 0 {
		return "0"
	}
	var parts []string
	if len(googleIDs) > 0 {
		parts = append(parts, "c.account_id IN ("+placeholders(len(googleIDs))+")")
	}
	if len(calendarIDs) > 0 {
		parts = append(parts, "e.calendar_id IN ("+placeholders(len(calendarIDs))+")")
	}
	return "(" + strings.Join(parts, " OR ") + ")"
}

func calendarAccountArgs(googleIDs []int64, calendarIDs []string) []any {
	args := make([]any, 0, len(googleIDs)+len(calendarIDs))
	for _, id := range googleIDs {
		args = append(args, id)
	}
	for _, id := range calendarIDs {
		args = append(args, id)
	}
	return args
}

// MeetingRecapRow is a recap with its event's title and start ("" when the
// event is gone). SourceText and RecapJSON are filled only by
// GetMeetingRecapByID.
type MeetingRecapRow struct {
	MeetingRecap
	EventTitle, EventStart string
}

// meetingRecapWhen is the instant a recap is filed under: its event's start,
// else its own created_at.
const meetingRecapWhen = `COALESCE(e.start_time, r.created_at)`

// ListMeetingRecaps returns recaps whose event start (else created_at) is in
// [since, until), newest first, without their texts.
func (db *DB) ListMeetingRecaps(ctx context.Context, since, until string, limit int) ([]MeetingRecapRow, error) {
	if err := positiveLimit("listing meeting recaps", limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	if since != "" {
		w.add(meetingRecapWhen+" >= ?", since)
	}
	if until != "" {
		w.add(meetingRecapWhen+" < ?", until)
	}
	rows, err := db.QueryContext(ctx, `SELECT r.id, COALESCE(r.event_id, ''), r.transcript_id, r.created_at, r.updated_at,
		COALESCE(e.title, ''), COALESCE(e.start_time, '')
		FROM meeting_recaps r LEFT JOIN calendar_events e ON e.id = r.event_id`+w.clause()+
		` ORDER BY `+meetingRecapWhen+` DESC, r.id DESC LIMIT ?`, append(w.args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing meeting recaps: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []MeetingRecapRow{}
	for rows.Next() {
		var r MeetingRecapRow
		if err := rows.Scan(&r.ID, &r.EventID, &r.TranscriptID, &r.CreatedAt, &r.UpdatedAt, &r.EventTitle, &r.EventStart); err != nil {
			return nil, fmt.Errorf("scanning meeting recap: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing meeting recaps: %w", err)
	}
	return out, nil
}

// GetMeetingRecapByID returns one recap with its texts and event, or
// (nil, nil) when there is none.
func (db *DB) GetMeetingRecapByID(ctx context.Context, id int64) (*MeetingRecapRow, error) {
	return db.getMeetingRecapRow(ctx, "r.id = ?", id)
}

// GetMeetingRecapByEventID is GetMeetingRecapByID keyed by the recap's
// calendar event.
func (db *DB) GetMeetingRecapByEventID(ctx context.Context, eventID string) (*MeetingRecapRow, error) {
	return db.getMeetingRecapRow(ctx, "r.event_id = ?", eventID)
}

func (db *DB) getMeetingRecapRow(ctx context.Context, where string, key any) (*MeetingRecapRow, error) {
	var r MeetingRecapRow
	err := db.QueryRowContext(ctx, `SELECT r.id, COALESCE(r.event_id, ''), r.transcript_id, r.source_text, r.recap_json,
		r.created_at, r.updated_at, COALESCE(e.title, ''), COALESCE(e.start_time, '')
		FROM meeting_recaps r LEFT JOIN calendar_events e ON e.id = r.event_id WHERE `+where, key).
		Scan(&r.ID, &r.EventID, &r.TranscriptID, &r.SourceText, &r.RecapJSON, &r.CreatedAt, &r.UpdatedAt,
			&r.EventTitle, &r.EventStart)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("loading meeting recap %v: %w", key, err)
	}
	return &r, nil
}

// ListMeetingNotes returns the notes of one event (EventID, in sort_order)
// and/or the notes updated at or after since (newest first when no event is
// named). created_at/updated_at come back normalised to the UTC "T…Z" form.
func (db *DB) ListMeetingNotes(ctx context.Context, eventID, since string, limit int) ([]MeetingNote, error) {
	if err := positiveLimit("listing meeting notes", limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	updated := utcColumnExpr("updated_at")
	order := ` ORDER BY ` + updated + ` DESC, id DESC`
	if eventID != "" {
		w.add("event_id = ?", eventID)
		order = ` ORDER BY sort_order, id`
	}
	if since != "" {
		w.add(updated+" >= ?", since)
	}
	rows, err := db.QueryContext(ctx, `SELECT id, event_id, type, text, is_checked, sort_order, task_id, `+
		utcColumnExpr("created_at")+`, `+updated+` FROM meeting_notes`+w.clause()+order+` LIMIT ?`, append(w.args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing meeting notes: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []MeetingNote{}
	for rows.Next() {
		var n MeetingNote
		if err := rows.Scan(&n.ID, &n.EventID, &n.Type, &n.Text, &n.IsChecked, &n.SortOrder, &n.TaskID, &n.CreatedAt, &n.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning meeting note: %w", err)
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing meeting notes: %w", err)
	}
	return out, nil
}

// DayPlanSummary is a day plan with its item counts.
type DayPlanSummary struct {
	DayPlan
	ItemCount, DoneCount int
}

// ListDayPlanSummaries returns userID's plans dated on or after since
// (YYYY-MM-DD, "" = all), newest first, with item and done counts.
func (db *DB) ListDayPlanSummaries(ctx context.Context, userID, since string, limit int) ([]DayPlanSummary, error) {
	if err := positiveLimit("listing day plans", limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	w.add("user_id = ?", userID)
	if since != "" {
		w.add("plan_date >= ?", since)
	}
	plans, err := db.queryDayPlans(ctx, `SELECT `+dayPlanSelectCols+` FROM day_plans`+w.clause()+
		` ORDER BY plan_date DESC LIMIT ?`, append(w.args, limit)...)
	if err != nil {
		return nil, err
	}
	ids := make([]any, 0, len(plans))
	for _, p := range plans {
		ids = append(ids, p.ID)
	}
	counts, err := db.dayPlanItemCounts(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]DayPlanSummary, 0, len(plans))
	for _, p := range plans {
		c := counts[p.ID]
		out = append(out, DayPlanSummary{DayPlan: p, ItemCount: c[0], DoneCount: c[1]})
	}
	return out, nil
}

func (db *DB) queryDayPlans(ctx context.Context, q string, args ...any) ([]DayPlan, error) {
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing day plans: %w", err)
	}
	defer func() { _ = rows.Close() }()
	plans, err := scanDayPlanRows(rows)
	if err != nil {
		return nil, fmt.Errorf("listing day plans: %w", err)
	}
	return plans, nil
}

// dayPlanItemCounts maps each of the plan ids to {items, done items}.
func (db *DB) dayPlanItemCounts(ctx context.Context, planIDs []any) (map[int64][2]int, error) {
	out := map[int64][2]int{}
	if len(planIDs) == 0 {
		return out, nil
	}
	rows, err := db.QueryContext(ctx, `SELECT day_plan_id, COUNT(*), COALESCE(SUM(status = 'done'), 0)
		FROM day_plan_items WHERE day_plan_id IN (`+placeholders(len(planIDs))+`) GROUP BY day_plan_id`, planIDs...)
	if err != nil {
		return nil, fmt.Errorf("counting day plan items: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var id int64
		var c [2]int
		if err := rows.Scan(&id, &c[0], &c[1]); err != nil {
			return nil, fmt.Errorf("counting day plan items: %w", err)
		}
		out[id] = c
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("counting day plan items: %w", err)
	}
	return out, nil
}

// ListReminders returns reminders of one status ("" = every status) due
// before dueBefore ("" = no bound), soonest first.
func (db *DB) ListReminders(ctx context.Context, status, dueBefore string, limit int) ([]Reminder, error) {
	if err := positiveLimit("listing reminders", limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	if status != "" {
		w.add("status = ?", status)
	}
	if dueBefore != "" {
		w.add("remind_at < ?", dueBefore)
	}
	rows, err := db.QueryContext(ctx, `SELECT id, account_id, message_ref, note, remind_at, status, created_at, done_at
		FROM reminders`+w.clause()+` ORDER BY remind_at, id LIMIT ?`, append(w.args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing reminders: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []Reminder{}
	for rows.Next() {
		var r Reminder
		if err := rows.Scan(&r.ID, &r.AccountID, &r.MessageRef, &r.Note, &r.RemindAt, &r.Status, &r.CreatedAt, &r.DoneAt); err != nil {
			return nil, fmt.Errorf("scanning reminder: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing reminders: %w", err)
	}
	return out, nil
}

// jiraAccountLive keeps rows of enabled, non-removed Jira accounts (alias ja).
const jiraAccountLive = `ja.enabled = 1 AND ja.status != 'removed'`

// JiraSprintQuery filters ListJiraSprints. Project (case-insensitive) keeps
// the sprints of that project's boards; BoardID 0 = any board.
type JiraSprintQuery struct {
	Project, State string
	BoardID        int64
	Limit          int
}

// JiraSprintRow is a sprint with its board's name and project key.
type JiraSprintRow struct {
	AccountID, ID, BoardID                   int64
	BoardName, ProjectKey, Name, State, Goal string
	StartDate, EndDate, CompleteDate         string
}

// ListJiraSprints returns the synced sprints of connected Jira accounts,
// newest start first.
func (db *DB) ListJiraSprints(ctx context.Context, q JiraSprintQuery) ([]JiraSprintRow, error) {
	if err := positiveLimit("listing jira sprints", q.Limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	w.add(jiraAccountLive)
	if q.Project != "" {
		w.add("b.project_key = ? COLLATE NOCASE", q.Project)
	}
	if q.BoardID != 0 {
		w.add("s.board_id = ?", q.BoardID)
	}
	if q.State != "" {
		w.add("s.state = ?", q.State)
	}
	rows, err := db.QueryContext(ctx, `SELECT s.account_id, s.id, s.board_id, COALESCE(b.name, ''), COALESCE(b.project_key, ''),
		s.name, s.state, s.goal, s.start_date, s.end_date, s.complete_date
		FROM jira_sprints s
		JOIN jira_accounts ja ON ja.id = s.account_id
		LEFT JOIN jira_boards b ON b.account_id = s.account_id AND b.id = s.board_id`+w.clause()+
		` ORDER BY s.start_date DESC, s.account_id, s.id DESC LIMIT ?`, append(w.args, q.Limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing jira sprints: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []JiraSprintRow{}
	for rows.Next() {
		var s JiraSprintRow
		if err := rows.Scan(&s.AccountID, &s.ID, &s.BoardID, &s.BoardName, &s.ProjectKey, &s.Name, &s.State, &s.Goal,
			&s.StartDate, &s.EndDate, &s.CompleteDate); err != nil {
			return nil, fmt.Errorf("scanning jira sprint: %w", err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing jira sprints: %w", err)
	}
	return out, nil
}

// JiraReleaseQuery filters ListJiraReleases. Released nil = either.
type JiraReleaseQuery struct {
	Project         string
	Released        *bool
	IncludeArchived bool
	Limit           int
}

// JiraReleaseRow is one synced Jira release (fix version).
type JiraReleaseRow struct {
	AccountID, ID                              int64
	ProjectKey, Name, Description, ReleaseDate string
	Released, Archived                         bool
}

// ListJiraReleases returns the synced releases of connected Jira accounts,
// latest release date first.
func (db *DB) ListJiraReleases(ctx context.Context, q JiraReleaseQuery) ([]JiraReleaseRow, error) {
	if err := positiveLimit("listing jira releases", q.Limit); err != nil {
		return nil, err
	}
	w := readWhere{}
	w.add(jiraAccountLive)
	if q.Project != "" {
		w.add("r.project_key = ? COLLATE NOCASE", q.Project)
	}
	if q.Released != nil {
		w.add("r.released = ?", *q.Released)
	}
	if !q.IncludeArchived {
		w.add("r.archived = 0")
	}
	rows, err := db.QueryContext(ctx, `SELECT r.account_id, r.id, r.project_key, r.name, r.description, r.release_date,
		r.released, r.archived
		FROM jira_releases r JOIN jira_accounts ja ON ja.id = r.account_id`+w.clause()+
		` ORDER BY r.release_date DESC, r.account_id, r.id DESC LIMIT ?`, append(w.args, q.Limit)...)
	if err != nil {
		return nil, fmt.Errorf("listing jira releases: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []JiraReleaseRow{}
	for rows.Next() {
		var r JiraReleaseRow
		if err := rows.Scan(&r.AccountID, &r.ID, &r.ProjectKey, &r.Name, &r.Description, &r.ReleaseDate, &r.Released, &r.Archived); err != nil {
			return nil, fmt.Errorf("scanning jira release: %w", err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing jira releases: %w", err)
	}
	return out, nil
}

// CalendarAccountMatch is one connected calendar account a ref names: a
// Google account (GoogleID, Label, Address) or a calendar_accounts row
// (CalendarID "caldav:<id>"/"ics:<id>", Label).
type CalendarAccountMatch struct {
	GoogleID       int64
	CalendarID     string
	Label, Address string
}

// MatchCalendarAccounts returns every calendar account ref names: a Google
// account whose label or email equals ref, or a calendar account whose label
// does, both under SQLite's COLLATE NOCASE (ASCII case folding only). It is
// the one predicate both list_calendar_events and the calendar:read scope
// use, so the tool never lists an account the scope did not see.
func (db *DB) MatchCalendarAccounts(ctx context.Context, ref string) ([]CalendarAccountMatch, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, '', label, email FROM google_accounts
		WHERE label = ?1 COLLATE NOCASE OR email = ?1 COLLATE NOCASE
		UNION ALL
		SELECT 0, provider || ':' || id, label, '' FROM calendar_accounts WHERE label = ?1 COLLATE NOCASE`, ref)
	if err != nil {
		return nil, fmt.Errorf("matching calendar account: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []CalendarAccountMatch
	for rows.Next() {
		var m CalendarAccountMatch
		if err := rows.Scan(&m.GoogleID, &m.CalendarID, &m.Label, &m.Address); err != nil {
			return nil, fmt.Errorf("matching calendar account: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("matching calendar account: %w", err)
	}
	return out, nil
}
