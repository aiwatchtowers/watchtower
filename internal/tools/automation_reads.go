package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// The D23 local-store reads for automations (spec
// 2026-10-14-automations-design §6.1, §20.1 D23, ask #277). Every tool here
// reads only the local database — the constructors take no client, so none
// can reach a live API — is visible only on the automation surface, and is
// never in ReadTools() (dev-mode MCP never mounts it, DEV-01). Lists take a
// limit (default 50, max 200) and return [] rather than null.

const (
	// maxAutomationDescriptionBytes clips calendar event and Jira release
	// descriptions (spec Global Constraints: 4 KiB).
	maxAutomationDescriptionBytes = 4 * 1024
	// maxMeetingRecapBytes clips a meeting recap's source_text and recap
	// (spec Global Constraints: 32 KiB each).
	maxMeetingRecapBytes = 32 * 1024
	// utcColumnLayout is the UTC text form the syncers store instants in.
	utcColumnLayout = "2006-01-02T15:04:05Z"
	planDateLayout  = "2006-01-02"
)

// automationSurfaceOnly is the Surfaces list of every D23 tool.
func automationSurfaceOnly() []string { return []string{AutomationSurface} }

func decodeAutomationArgs[T any](call Call) (T, error) {
	var a T
	if err := json.Unmarshal(call.Args, &a); err != nil {
		return a, &ValidationError{Msg: "invalid arguments", Err: err}
	}
	return a, nil
}

// utcArg parses an optional RFC 3339 argument into the stored UTC form;
// "" stays "" (no bound).
func utcArg(field, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	ts, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return "", &ValidationError{Msg: field + " must be an RFC 3339 time, e.g. 2026-10-14T09:00:00Z", Err: err}
	}
	return ts.UTC().Format(utcColumnLayout), nil
}

// dateArg validates an optional YYYY-MM-DD argument; "" stays "".
func dateArg(field, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if _, err := time.Parse(planDateLayout, raw); err != nil {
		return "", &ValidationError{Msg: field + " must be a date YYYY-MM-DD", Err: err}
	}
	return raw, nil
}

// statusArg resolves a status filter with a default and an "all" choice
// ("all" → "" = every status).
func statusArg(raw, def string, allowed ...string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return def, nil
	}
	if err := validateEnum("status", s, append(slices.Clone(allowed), "all")...); err != nil {
		return "", err
	}
	if s == "all" {
		return "", nil
	}
	return s, nil
}

// storedJSON returns a stored JSON column as raw JSON ("" → empty). A
// column that is not JSON is an error naming the row — never silently
// replaced.
func storedJSON(what, s, empty string) (json.RawMessage, error) {
	if strings.TrimSpace(s) == "" {
		s = empty
	}
	if !json.Valid([]byte(s)) {
		return nil, fmt.Errorf("%s is not valid JSON", what)
	}
	return json.RawMessage(s), nil
}

// ── list_inbox ────────────────────────────────────────────────────────────────

type listInboxArgs struct {
	Status      string `json:"status,omitempty" jsonschema:"pending (default), snoozed, resolved, dismissed or all"`
	Priority    string `json:"priority,omitempty" jsonschema:"high, medium or low"`
	TriggerType string `json:"trigger_type,omitempty" jsonschema:"only items of this trigger type, e.g. mention, dm, jira_assigned, calendar_invite, email_received"`
	Since       string `json:"since,omitempty" jsonschema:"only items created at or after this RFC 3339 time"`
	Limit       int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type inboxItemResult struct {
	ID           int    `json:"id"`
	TriggerType  string `json:"trigger_type"`
	ItemClass    string `json:"item_class"`
	Status       string `json:"status"`
	Priority     string `json:"priority"`
	Snippet      string `json:"snippet"`
	WhyMatters   string `json:"why_matters"`
	Permalink    string `json:"permalink"`
	ChannelID    string `json:"channel_id"`
	SenderUserID string `json:"sender_user_id"`
	SnoozeUntil  string `json:"snooze_until"`
	TargetID     *int   `json:"target_id"`
	ReadAt       string `json:"read_at"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
}

// NewListInbox lists the owner's attention inbox (inbox_items), newest
// first; archived rows are never returned, nor the large text columns.
func NewListInbox() *Tool {
	return &Tool{
		Name: "list_inbox",
		Description: "List the owner's attention inbox — items that need them across Slack, Jira, calendar and email — newest first. " +
			"Defaults to pending items; filter with status, priority, trigger_type and since. Archived items are never listed.",
		InputSchema: mustSchema[listInboxArgs]("list_inbox"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listInboxArgs](call)
			if err != nil {
				return nil, err
			}
			q, err := inboxQuery(a)
			if err != nil {
				return nil, err
			}
			items, err := d.ListInboxForAutomation(ctx, q)
			if err != nil {
				return nil, err
			}
			out := make([]inboxItemResult, 0, len(items))
			for _, it := range items {
				out = append(out, inboxItemResult{
					ID: it.ID, TriggerType: it.TriggerType, ItemClass: it.ItemClass, Status: it.Status, Priority: it.Priority,
					Snippet: it.Snippet, WhyMatters: it.WhyMatters, Permalink: it.Permalink, ChannelID: it.ChannelID,
					SenderUserID: it.SenderUserID, SnoozeUntil: it.SnoozeUntil, TargetID: it.TargetID, ReadAt: it.ReadAt,
					CreatedAt: it.CreatedAt, UpdatedAt: it.UpdatedAt,
				})
			}
			return map[string]any{"items": out}, nil
		},
	}
}

func inboxQuery(a listInboxArgs) (db.InboxReadQuery, error) {
	status, err := statusArg(a.Status, "pending", "pending", "snoozed", "resolved", "dismissed")
	if err != nil {
		return db.InboxReadQuery{}, err
	}
	if err := validateEnum("priority", a.Priority, "high", "medium", "low"); err != nil {
		return db.InboxReadQuery{}, err
	}
	since, err := utcArg("since", a.Since)
	if err != nil {
		return db.InboxReadQuery{}, err
	}
	return db.InboxReadQuery{Status: status, Priority: a.Priority, TriggerType: strings.TrimSpace(a.TriggerType),
		Since: since, Limit: listLimit(a.Limit)}, nil
}

// ── list_calendar_events ──────────────────────────────────────────────────────

type listCalendarEventsArgs struct {
	From    string `json:"from" jsonschema:"start of the range (inclusive), RFC 3339"`
	To      string `json:"to" jsonschema:"end of the range (exclusive), RFC 3339, after from"`
	Account string `json:"account,omitempty" jsonschema:"only this calendar account: a Google account's label or address, or a CalDAV/ICS account's label"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type calendarEventResult struct {
	ID                   string          `json:"id"`
	CalendarID           string          `json:"calendar_id"`
	Calendar             string          `json:"calendar"`
	Account              string          `json:"account"`
	Title                string          `json:"title"`
	Start                string          `json:"start"`
	End                  string          `json:"end"`
	AllDay               bool            `json:"all_day"`
	Location             string          `json:"location"`
	Organizer            string          `json:"organizer"`
	Attendees            json.RawMessage `json:"attendees"`
	Status               string          `json:"status"`
	HTMLLink             string          `json:"html_link"`
	ConferenceURL        string          `json:"conference_url"`
	Description          string          `json:"description"`
	DescriptionTruncated bool            `json:"description_truncated"`
}

// NewListCalendarEvents lists synced calendar events starting in [from, to)
// — past and cancelled ones included — in start order.
func NewListCalendarEvents() *Tool {
	return &Tool{
		Name: "list_calendar_events",
		Description: "List locally synced calendar events that start in [from, to), past ones included, in start order. " +
			"Cancelled events are listed with their status. Optionally only one calendar account. Descriptions are clipped at 4 KiB.",
		InputSchema: mustSchema[listCalendarEventsArgs]("list_calendar_events"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listCalendarEventsArgs](call)
			if err != nil {
				return nil, err
			}
			q, err := calendarRangeQuery(d, a)
			if err != nil {
				return nil, err
			}
			events, err := d.ListCalendarEventsRange(ctx, q)
			if err != nil {
				return nil, err
			}
			out := make([]calendarEventResult, 0, len(events))
			for _, e := range events {
				r, err := calendarEventOf(e)
				if err != nil {
					return nil, err
				}
				out = append(out, r)
			}
			return map[string]any{"events": out}, nil
		},
	}
}

func calendarRangeQuery(d *db.DB, a listCalendarEventsArgs) (db.CalendarRangeQuery, error) {
	if strings.TrimSpace(a.From) == "" || strings.TrimSpace(a.To) == "" {
		return db.CalendarRangeQuery{}, &ValidationError{Msg: "from and to are required (RFC 3339)"}
	}
	from, err := utcArg("from", a.From)
	if err != nil {
		return db.CalendarRangeQuery{}, err
	}
	to, err := utcArg("to", a.To)
	if err != nil {
		return db.CalendarRangeQuery{}, err
	}
	if to <= from {
		return db.CalendarRangeQuery{}, &ValidationError{Msg: "to must be after from"}
	}
	q := db.CalendarRangeQuery{From: from, To: to, Limit: listLimit(a.Limit)}
	if acct := strings.TrimSpace(a.Account); acct != "" {
		q.Filtered = true
		if q.GoogleAccountIDs, q.CalendarIDs, err = resolveCalendarAccount(d, acct); err != nil {
			return db.CalendarRangeQuery{}, err
		}
	}
	return q, nil
}

// resolveCalendarAccount matches ref, case-insensitively, against every
// Google account's label and address and every calendar account's label —
// the same lookup the calendar:read scope uses, so a ref naming two accounts
// lists both and the manifest must cover both. No match is a
// *ValidationError.
func resolveCalendarAccount(d *db.DB, ref string) ([]int64, []string, error) {
	google, err := d.ListGoogleAccounts()
	if err != nil {
		return nil, nil, fmt.Errorf("resolving calendar account: %w", err)
	}
	cals, err := d.ListCalendarAccounts()
	if err != nil {
		return nil, nil, fmt.Errorf("resolving calendar account: %w", err)
	}
	var googleIDs []int64
	for _, g := range google {
		if strings.EqualFold(g.Label, ref) || strings.EqualFold(g.Email, ref) {
			googleIDs = append(googleIDs, g.ID)
		}
	}
	var calendarIDs []string
	for _, c := range cals {
		if strings.EqualFold(c.Label, ref) {
			calendarIDs = append(calendarIDs, db.CalendarAccountCalendarID(c.Provider, c.ID))
		}
	}
	if len(googleIDs)+len(calendarIDs) == 0 {
		return nil, nil, &ValidationError{Msg: "unknown account " + strconv.Quote(ref) +
			": use a connected Google account's label or address, or a calendar account's label"}
	}
	return googleIDs, calendarIDs, nil
}

func calendarEventOf(e db.CalendarRangeEvent) (calendarEventResult, error) {
	attendees, err := storedJSON("attendees of calendar event "+e.ID, e.Attendees, "[]")
	if err != nil {
		return calendarEventResult{}, err
	}
	desc, truncated := clipUTF8Bytes(e.Description, maxAutomationDescriptionBytes)
	return calendarEventResult{
		ID: e.ID, CalendarID: e.CalendarID, Calendar: e.CalendarName, Account: e.Account, Title: e.Title,
		Start: e.StartTime, End: e.EndTime, AllDay: e.IsAllDay, Location: e.Location, Organizer: e.OrganizerEmail,
		Attendees: attendees, Status: e.EventStatus, HTMLLink: e.HTMLLink, ConferenceURL: e.ConferenceURL,
		Description: desc, DescriptionTruncated: truncated,
	}, nil
}

// ── meeting recaps and notes ──────────────────────────────────────────────────

type listMeetingRecapsArgs struct {
	Since string `json:"since,omitempty" jsonschema:"only recaps of meetings that started at or after this RFC 3339 time (a recap with no event: its creation time)"`
	Until string `json:"until,omitempty" jsonschema:"only recaps of meetings that started before this RFC 3339 time"`
	Limit int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getMeetingRecapArgs struct {
	ID      int64  `json:"id,omitempty" jsonschema:"the recap id from list_meeting_recaps"`
	EventID string `json:"event_id,omitempty" jsonschema:"the calendar event id the recap belongs to (give id or event_id, not both)"`
}

type meetingRecapSummary struct {
	ID           int64  `json:"id"`
	EventID      string `json:"event_id"`
	EventTitle   string `json:"event_title"`
	EventStart   string `json:"event_start"`
	TranscriptID *int64 `json:"transcript_id"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
}

type meetingRecapDetail struct {
	meetingRecapSummary
	Recap           any    `json:"recap"`
	RecapTruncated  bool   `json:"recap_truncated"`
	SourceText      string `json:"source_text"`
	SourceTruncated bool   `json:"source_truncated"`
}

func summarizeMeetingRecap(r db.MeetingRecapRow) meetingRecapSummary {
	var transcript *int64
	if r.TranscriptID.Valid {
		transcript = &r.TranscriptID.Int64
	}
	return meetingRecapSummary{
		ID: r.ID, EventID: r.EventID, EventTitle: r.EventTitle, EventStart: r.EventStart,
		TranscriptID: transcript, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
	}
}

// NewListMeetingRecaps lists meeting recaps, newest meeting first, without
// their texts.
func NewListMeetingRecaps() *Tool {
	return &Tool{
		Name: "list_meeting_recaps",
		Description: "List meeting recaps (summaries of recorded or transcribed meetings) with their meeting's title and start, newest first. " +
			"Read one recap with get_meeting_recap.",
		InputSchema: mustSchema[listMeetingRecapsArgs]("list_meeting_recaps"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listMeetingRecapsArgs](call)
			if err != nil {
				return nil, err
			}
			since, err := utcArg("since", a.Since)
			if err != nil {
				return nil, err
			}
			until, err := utcArg("until", a.Until)
			if err != nil {
				return nil, err
			}
			rows, err := d.ListMeetingRecaps(ctx, since, until, listLimit(a.Limit))
			if err != nil {
				return nil, err
			}
			out := make([]meetingRecapSummary, 0, len(rows))
			for _, r := range rows {
				out = append(out, summarizeMeetingRecap(r))
			}
			return map[string]any{"recaps": out}, nil
		},
	}
}

// NewGetMeetingRecap reads one recap by id or by its event: the recap JSON
// and the source text, each clipped at 32 KiB.
func NewGetMeetingRecap() *Tool {
	return &Tool{
		Name: "get_meeting_recap",
		Description: "Read one meeting recap by id or by its calendar event_id: the structured recap and the text it was made from " +
			"(each clipped at 32 KiB; a recap above that comes back as clipped text with recap_truncated).",
		InputSchema: mustSchema[getMeetingRecapArgs]("get_meeting_recap"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[getMeetingRecapArgs](call)
			if err != nil {
				return nil, err
			}
			r, err := loadMeetingRecap(ctx, d, a)
			if err != nil {
				return nil, err
			}
			recap, recapTruncated := recapValue(r.RecapJSON)
			source, sourceTruncated := clipUTF8Bytes(r.SourceText, maxMeetingRecapBytes)
			return meetingRecapDetail{
				meetingRecapSummary: summarizeMeetingRecap(*r), Recap: recap, RecapTruncated: recapTruncated,
				SourceText: source, SourceTruncated: sourceTruncated,
			}, nil
		},
	}
}

func loadMeetingRecap(ctx context.Context, d *db.DB, a getMeetingRecapArgs) (*db.MeetingRecapRow, error) {
	eventID := strings.TrimSpace(a.EventID)
	if (a.ID != 0) == (eventID != "") {
		return nil, &ValidationError{Msg: "give exactly one of id or event_id"}
	}
	id := a.ID
	if eventID != "" {
		byEvent, err := d.GetMeetingRecap(eventID)
		if err != nil {
			return nil, err
		}
		if byEvent == nil {
			return nil, &ValidationError{Msg: "no meeting recap for event " + strconv.Quote(eventID)}
		}
		id = byEvent.ID
	}
	r, err := d.GetMeetingRecapByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if r == nil {
		return nil, &ValidationError{Msg: fmt.Sprintf("no meeting recap %d", id)}
	}
	return r, nil
}

// recapValue is the stored recap JSON as JSON when it fits in 32 KiB; a
// larger one, or one that is not JSON, comes back as text (clipped, with
// truncated set when cut).
func recapValue(raw string) (any, bool) {
	if len(raw) <= maxMeetingRecapBytes && json.Valid([]byte(raw)) {
		return json.RawMessage(raw), false
	}
	return clipUTF8Bytes(raw, maxMeetingRecapBytes)
}

type listMeetingNotesArgs struct {
	EventID string `json:"event_id,omitempty" jsonschema:"the calendar event whose notes to list (in their order)"`
	Since   string `json:"since,omitempty" jsonschema:"only notes added or edited at or after this RFC 3339 time; give event_id, since, or both"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type meetingNoteResult struct {
	ID        int64  `json:"id"`
	EventID   string `json:"event_id"`
	Type      string `json:"type"`
	Text      string `json:"text"`
	IsChecked bool   `json:"is_checked"`
	SortOrder int    `json:"sort_order"`
	TaskID    *int64 `json:"task_id"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

// NewListMeetingNotes lists the owner's meeting notes and questions of one
// event, or those added or edited since a time — each note whole.
func NewListMeetingNotes() *Tool {
	return &Tool{
		Name: "list_meeting_notes",
		Description: "List the owner's meeting notes and questions — of one calendar event (in their order), or added or edited since a time. " +
			"Each note's text is returned whole.",
		InputSchema: mustSchema[listMeetingNotesArgs]("list_meeting_notes"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listMeetingNotesArgs](call)
			if err != nil {
				return nil, err
			}
			eventID := strings.TrimSpace(a.EventID)
			since, err := utcArg("since", a.Since)
			if err != nil {
				return nil, err
			}
			if eventID == "" && since == "" {
				return nil, &ValidationError{Msg: "give event_id, since, or both"}
			}
			notes, err := d.ListMeetingNotes(ctx, eventID, since, listLimit(a.Limit))
			if err != nil {
				return nil, err
			}
			out := make([]meetingNoteResult, 0, len(notes))
			for _, n := range notes {
				r := meetingNoteResult{ID: n.ID, EventID: n.EventID, Type: n.Type, Text: n.Text, IsChecked: n.IsChecked,
					SortOrder: n.SortOrder, CreatedAt: n.CreatedAt, UpdatedAt: n.UpdatedAt}
				if n.TaskID.Valid {
					r.TaskID = &n.TaskID.Int64
				}
				out = append(out, r)
			}
			return map[string]any{"notes": out}, nil
		},
	}
}

// ── day plans ─────────────────────────────────────────────────────────────────

type listDayPlansArgs struct {
	Since string `json:"since,omitempty" jsonschema:"only plans dated on or after this date, YYYY-MM-DD"`
	Limit int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getDayPlanArgs struct {
	Date string `json:"date,omitempty" jsonschema:"the plan's date, YYYY-MM-DD; default today (local time)"`
	ID   int64  `json:"id,omitempty" jsonschema:"the plan id from list_day_plans (instead of date)"`
}

type dayPlanResult struct {
	ID              int64  `json:"id"`
	PlanDate        string `json:"plan_date"`
	Status          string `json:"status"`
	HasConflicts    bool   `json:"has_conflicts"`
	ConflictSummary string `json:"conflict_summary"`
	GeneratedAt     string `json:"generated_at"`
	ItemCount       int    `json:"item_count"`
	DoneCount       int    `json:"done_count"`
}

type dayPlanItemResult struct {
	ID          int64           `json:"id"`
	Kind        string          `json:"kind"`
	SourceType  string          `json:"source_type"`
	SourceID    string          `json:"source_id"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Rationale   string          `json:"rationale"`
	StartTime   string          `json:"start_time"`
	EndTime     string          `json:"end_time"`
	DurationMin *int64          `json:"duration_min"`
	Priority    string          `json:"priority"`
	Status      string          `json:"status"`
	OrderIndex  int             `json:"order_index"`
	Tags        json.RawMessage `json:"tags"`
}

func dayPlanOf(p db.DayPlan, items, done int) dayPlanResult {
	return dayPlanResult{
		ID: p.ID, PlanDate: p.PlanDate, Status: p.Status, HasConflicts: p.HasConflicts,
		ConflictSummary: p.ConflictSummary.String, GeneratedAt: formatUTC(p.GeneratedAt),
		ItemCount: items, DoneCount: done,
	}
}

func formatUTC(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// NewListDayPlans lists the owner's day plans, newest first, with item and
// done counts. An unknown owner is the OWNER-02 error, never an empty list.
func NewListDayPlans() *Tool {
	return &Tool{
		Name:        "list_day_plans",
		Description: "List the owner's day plans, newest date first, with how many items each has and how many are done. Read one with get_day_plan.",
		InputSchema: mustSchema[listDayPlansArgs]("list_day_plans"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listDayPlansArgs](call)
			if err != nil {
				return nil, err
			}
			since, err := dateArg("since", a.Since)
			if err != nil {
				return nil, err
			}
			owner, err := d.RequireOwner()
			if err != nil {
				return nil, err
			}
			plans, err := d.ListDayPlanSummaries(ctx, owner.ID, since, listLimit(a.Limit))
			if err != nil {
				return nil, err
			}
			out := make([]dayPlanResult, 0, len(plans))
			for _, p := range plans {
				out = append(out, dayPlanOf(p.DayPlan, p.ItemCount, p.DoneCount))
			}
			return map[string]any{"plans": out}, nil
		},
	}
}

// NewGetDayPlan reads one of the owner's day plans (by date, default today,
// or by id) with its items in order. No plan → {plan: null, items: []}.
func NewGetDayPlan() *Tool {
	return &Tool{
		Name: "get_day_plan",
		Description: "Read the owner's day plan for a date (default today) or by id, with its time blocks and backlog items in order. " +
			"A date with no plan returns plan: null.",
		InputSchema: mustSchema[getDayPlanArgs]("get_day_plan"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[getDayPlanArgs](call)
			if err != nil {
				return nil, err
			}
			plan, err := loadOwnerDayPlan(d, a)
			if err != nil {
				return nil, err
			}
			if plan == nil {
				return map[string]any{"plan": nil, "items": []dayPlanItemResult{}}, nil
			}
			return dayPlanWithItems(d, plan)
		},
	}
}

// loadOwnerDayPlan returns the owner's plan for a.Date (default today,
// local zone; nil when that date has none) or a.ID (a *ValidationError when
// no plan of the owner has that id — never another user's plan).
func loadOwnerDayPlan(d *db.DB, a getDayPlanArgs) (*db.DayPlan, error) {
	date, err := dateArg("date", a.Date)
	if err != nil {
		return nil, err
	}
	if a.ID != 0 && date != "" {
		return nil, &ValidationError{Msg: "give date or id, not both"}
	}
	owner, err := d.RequireOwner()
	if err != nil {
		return nil, err
	}
	if a.ID == 0 {
		if date == "" {
			date = time.Now().Format(planDateLayout)
		}
		return d.GetDayPlan(owner.ID, date)
	}
	p, err := d.GetDayPlanByID(a.ID)
	if err != nil {
		return nil, err
	}
	if p == nil || p.UserID != owner.ID {
		return nil, &ValidationError{Msg: fmt.Sprintf("no day plan %d", a.ID)}
	}
	return p, nil
}

func dayPlanWithItems(d *db.DB, plan *db.DayPlan) (any, error) {
	items, err := d.GetDayPlanItems(plan.ID)
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(items, func(x, y db.DayPlanItem) int { return x.OrderIndex - y.OrderIndex })
	out := make([]dayPlanItemResult, 0, len(items))
	done := 0
	for _, it := range items {
		r, err := dayPlanItemOf(it)
		if err != nil {
			return nil, err
		}
		if it.Status == "done" {
			done++
		}
		out = append(out, r)
	}
	return map[string]any{"plan": dayPlanOf(*plan, len(items), done), "items": out}, nil
}

func dayPlanItemOf(it db.DayPlanItem) (dayPlanItemResult, error) {
	tags, err := storedJSON(fmt.Sprintf("tags of day plan item %d", it.ID), it.Tags, "[]")
	if err != nil {
		return dayPlanItemResult{}, err
	}
	r := dayPlanItemResult{
		ID: it.ID, Kind: it.Kind, SourceType: it.SourceType, SourceID: it.SourceID.String, Title: it.Title,
		Description: it.Description.String, Rationale: it.Rationale.String, Priority: it.Priority.String,
		Status: it.Status, OrderIndex: it.OrderIndex, Tags: tags,
	}
	if it.StartTime.Valid {
		r.StartTime = formatUTC(it.StartTime.Time)
	}
	if it.EndTime.Valid {
		r.EndTime = formatUTC(it.EndTime.Time)
	}
	if it.DurationMin.Valid {
		r.DurationMin = &it.DurationMin.Int64
	}
	return r, nil
}

// ── list_reminders ────────────────────────────────────────────────────────────

type listRemindersArgs struct {
	Status    string `json:"status,omitempty" jsonschema:"pending (default), done, dismissed or all"`
	DueBefore string `json:"due_before,omitempty" jsonschema:"only reminders due before this RFC 3339 time"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type reminderResult struct {
	ID         int64  `json:"id"`
	AccountID  int64  `json:"account_id"`
	MessageRef string `json:"message_ref"`
	Note       string `json:"note"`
	RemindAt   string `json:"remind_at"`
	Status     string `json:"status"`
	CreatedAt  string `json:"created_at"`
	DoneAt     string `json:"done_at"`
}

// NewListReminders lists the owner's reminders (remind_me), soonest first.
func NewListReminders() *Tool {
	return &Tool{
		Name:        "list_reminders",
		Description: "List the owner's reminders (set with remind_me), soonest first. Defaults to pending; filter with status and due_before.",
		InputSchema: mustSchema[listRemindersArgs]("list_reminders"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listRemindersArgs](call)
			if err != nil {
				return nil, err
			}
			status, err := statusArg(a.Status, "pending", "pending", "done", "dismissed")
			if err != nil {
				return nil, err
			}
			due, err := utcArg("due_before", a.DueBefore)
			if err != nil {
				return nil, err
			}
			rows, err := d.ListReminders(ctx, status, due, listLimit(a.Limit))
			if err != nil {
				return nil, err
			}
			out := make([]reminderResult, 0, len(rows))
			for _, r := range rows {
				out = append(out, reminderResult(r))
			}
			return map[string]any{"reminders": out}, nil
		},
	}
}

// ── Jira sprints and releases ─────────────────────────────────────────────────

type listJiraSprintsArgs struct {
	Project string `json:"project,omitempty" jsonschema:"only sprints of this project's boards, e.g. PAY"`
	BoardID int64  `json:"board_id,omitempty" jsonschema:"only sprints of this board"`
	State   string `json:"state,omitempty" jsonschema:"active, future or closed"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type jiraSprintResult struct {
	AccountID    int64  `json:"account_id"`
	ID           int64  `json:"id"`
	BoardID      int64  `json:"board_id"`
	BoardName    string `json:"board_name"`
	ProjectKey   string `json:"project_key"`
	Name         string `json:"name"`
	State        string `json:"state"`
	Goal         string `json:"goal"`
	StartDate    string `json:"start_date"`
	EndDate      string `json:"end_date"`
	CompleteDate string `json:"complete_date"`
}

// NewListJiraSprints lists synced Jira sprints with their board, newest
// start first. project and board_id both apply when both are given.
func NewListJiraSprints() *Tool {
	return &Tool{
		Name:        "list_jira_sprints",
		Description: "List locally synced Jira sprints with their board and project, newest first. Filter by project, board_id and state.",
		InputSchema: mustSchema[listJiraSprintsArgs]("list_jira_sprints"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listJiraSprintsArgs](call)
			if err != nil {
				return nil, err
			}
			if err := validateEnum("state", a.State, "active", "future", "closed"); err != nil {
				return nil, err
			}
			rows, err := d.ListJiraSprints(ctx, db.JiraSprintQuery{
				Project: strings.TrimSpace(a.Project), BoardID: a.BoardID, State: a.State, Limit: listLimit(a.Limit),
			})
			if err != nil {
				return nil, err
			}
			out := make([]jiraSprintResult, 0, len(rows))
			for _, s := range rows {
				out = append(out, jiraSprintResult(s))
			}
			return map[string]any{"sprints": out}, nil
		},
	}
}

type listJiraReleasesArgs struct {
	Project         string `json:"project,omitempty" jsonschema:"only releases of this project, e.g. PAY"`
	Released        *bool  `json:"released,omitempty" jsonschema:"true = only released versions, false = only unreleased"`
	IncludeArchived bool   `json:"include_archived,omitempty" jsonschema:"also list archived versions (default false)"`
	Limit           int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type jiraReleaseResult struct {
	AccountID            int64  `json:"account_id"`
	ID                   int64  `json:"id"`
	ProjectKey           string `json:"project_key"`
	Name                 string `json:"name"`
	Description          string `json:"description"`
	DescriptionTruncated bool   `json:"description_truncated"`
	ReleaseDate          string `json:"release_date"`
	Released             bool   `json:"released"`
	Archived             bool   `json:"archived"`
}

// NewListJiraReleases lists synced Jira releases (fix versions), latest
// release date first; archived ones only on request.
func NewListJiraReleases() *Tool {
	return &Tool{
		Name: "list_jira_releases",
		Description: "List locally synced Jira releases (fix versions), latest release date first. Filter by project and released; " +
			"archived versions only with include_archived. Descriptions are clipped at 4 KiB.",
		InputSchema: mustSchema[listJiraReleasesArgs]("list_jira_releases"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listJiraReleasesArgs](call)
			if err != nil {
				return nil, err
			}
			rows, err := d.ListJiraReleases(ctx, db.JiraReleaseQuery{
				Project: strings.TrimSpace(a.Project), Released: a.Released, IncludeArchived: a.IncludeArchived,
				Limit: listLimit(a.Limit),
			})
			if err != nil {
				return nil, err
			}
			out := make([]jiraReleaseResult, 0, len(rows))
			for _, r := range rows {
				desc, truncated := clipUTF8Bytes(r.Description, maxAutomationDescriptionBytes)
				out = append(out, jiraReleaseResult{
					AccountID: r.AccountID, ID: r.ID, ProjectKey: r.ProjectKey, Name: r.Name, Description: desc,
					DescriptionTruncated: truncated, ReleaseDate: r.ReleaseDate, Released: r.Released, Archived: r.Archived,
				})
			}
			return map[string]any{"releases": out}, nil
		},
	}
}

// AutomationReadTools is the D23 set, registered by buildToolRegistry beside
// the email reads. Never part of ReadTools() (DEV-01).
func AutomationReadTools() []*Tool {
	return []*Tool{
		NewListInbox(),
		NewListCalendarEvents(),
		NewListMeetingRecaps(),
		NewGetMeetingRecap(),
		NewListMeetingNotes(),
		NewListDayPlans(),
		NewGetDayPlan(),
		NewListReminders(),
		NewListJiraSprints(),
		NewListJiraReleases(),
	}
}
