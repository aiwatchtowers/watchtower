package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Every D23 constructor takes no client, so none can reach a live API —
// pinned at compile time.
var (
	_ func() *Tool = NewListInbox
	_ func() *Tool = NewListCalendarEvents
	_ func() *Tool = NewListMeetingRecaps
	_ func() *Tool = NewGetMeetingRecap
	_ func() *Tool = NewListMeetingNotes
	_ func() *Tool = NewListDayPlans
	_ func() *Tool = NewGetDayPlan
	_ func() *Tool = NewListReminders
	_ func() *Tool = NewListJiraSprints
	_ func() *Tool = NewListJiraReleases
)

func automationReadsRegistry(t *testing.T) (*db.DB, *Registry) {
	t.Helper()
	d := openDB(t)
	reg := New(d)
	for _, tool := range AutomationReadTools() {
		require.NoError(t, reg.Register(tool))
	}
	return d, reg
}

// callAutomationRead runs a read tool and decodes its JSON result into out.
func callAutomationRead(t *testing.T, reg *Registry, name, args string, out any) string {
	t.Helper()
	raw := callReadString(t, reg, name, args)
	require.NoError(t, json.Unmarshal([]byte(raw), out), raw)
	return raw
}

func requireValidationError(t *testing.T, reg *Registry, name, args, contains string) {
	t.Helper()
	_, err := reg.CallRead(context.Background(), name, json.RawMessage(args), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve, "%s %s", name, args)
	assert.Contains(t, ve.Msg, contains)
}

func utcText(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func mustExec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	_, err := d.Exec(q, args...)
	require.NoError(t, err, q)
}

// ── list_inbox ────────────────────────────────────────────────────────────────

type inboxListResult struct {
	Items []map[string]any `json:"items"`
}

func seedInboxItem(t *testing.T, d *db.DB, ts, status, priority, trigger string, created time.Time, archived bool) {
	t.Helper()
	var archivedAt any
	if archived {
		archivedAt = utcText(created)
	}
	mustExec(t, d, `INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, raw_text,
		context, thread_digest, draft_reply, status, priority, created_at, updated_at, archived_at)
		VALUES ('C1', ?, 'U1', ?, 'snippet '||?, 'RAW-TEXT', 'CONTEXT-TEXT', 'DIGEST-TEXT', 'DRAFT-TEXT', ?, ?, ?, ?, ?)`,
		ts, trigger, ts, status, priority, utcText(created), utcText(created), archivedAt)
}

func inboxTS(r inboxListResult) []string {
	out := []string{}
	for _, it := range r.Items {
		out = append(out, strings.TrimPrefix(it["snippet"].(string), "snippet "))
	}
	return out
}

func TestListInbox_DefaultsToPendingNotArchived(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	now := time.Now().UTC().Truncate(time.Second)
	seedInboxItem(t, d, "1", "pending", "high", "mention", now.Add(-4*time.Hour), false)
	seedInboxItem(t, d, "2", "snoozed", "medium", "dm", now.Add(-3*time.Hour), false)
	seedInboxItem(t, d, "3", "resolved", "low", "mention", now.Add(-2*time.Hour), false)
	seedInboxItem(t, d, "4", "pending", "high", "mention", now.Add(-time.Hour), true)

	var got inboxListResult
	raw := callAutomationRead(t, reg, "list_inbox", `{}`, &got)
	assert.Equal(t, []string{"1"}, inboxTS(got), "pending, not archived")
	for _, hidden := range []string{"RAW-TEXT", "CONTEXT-TEXT", "DIGEST-TEXT", "DRAFT-TEXT", `"raw_text"`, `"draft_reply"`} {
		assert.NotContains(t, raw, hidden)
	}
	for _, key := range []string{"id", "trigger_type", "item_class", "status", "priority", "snippet", "why_matters", "permalink",
		"channel_id", "sender_user_id", "snooze_until", "target_id", "read_at", "created_at", "updated_at"} {
		assert.Contains(t, got.Items[0], key)
	}

	cases := []struct{ args, want string }{
		{`{"status":"all"}`, "3,2,1"},
		{`{"status":"snoozed"}`, "2"},
		{`{"status":"all","priority":"low"}`, "3"},
		{`{"status":"all","trigger_type":"mention"}`, "3,1"},
		{`{"status":"all","since":"` + now.Add(-150*time.Minute).Format(time.RFC3339) + `"}`, "3"},
	}
	for _, c := range cases {
		var r inboxListResult
		callAutomationRead(t, reg, "list_inbox", c.args, &r)
		assert.Equal(t, c.want, strings.Join(inboxTS(r), ","), c.args)
	}

	for i := range 210 {
		seedInboxItem(t, d, fmt.Sprintf("bulk-%d", i), "pending", "low", "dm", now.Add(-time.Duration(i)*time.Second), false)
	}
	for args, n := range map[string]int{`{"limit":0}`: 50, `{"limit":500}`: 200, `{"limit":3}`: 3} {
		var r inboxListResult
		callAutomationRead(t, reg, "list_inbox", args, &r)
		assert.Len(t, r.Items, n, args)
	}
	requireValidationError(t, reg, "list_inbox", `{"status":"archived"}`, "status")
	requireValidationError(t, reg, "list_inbox", `{"since":"yesterday"}`, "since")

	empty := openDB(t)
	emptyReg := New(empty)
	require.NoError(t, emptyReg.Register(NewListInbox()))
	assert.Contains(t, callReadString(t, emptyReg, "list_inbox", `{}`), `"items":[]`)
}

// ── list_calendar_events ──────────────────────────────────────────────────────

type calendarListResult struct {
	Events []struct {
		ID                   string          `json:"id"`
		Calendar             string          `json:"calendar"`
		Account              string          `json:"account"`
		Start                string          `json:"start"`
		Status               string          `json:"status"`
		Attendees            json.RawMessage `json:"attendees"`
		Description          string          `json:"description"`
		DescriptionTruncated bool            `json:"description_truncated"`
	} `json:"events"`
}

func (r calendarListResult) ids() string {
	out := []string{}
	for _, e := range r.Events {
		out = append(out, e.ID)
	}
	return strings.Join(out, ",")
}

// seedCalendars: Google account "work" (owner@example.com) with calendar
// g-cal, and CalDAV account "team" with its caldav:<id> calendar.
func seedCalendars(t *testing.T, d *db.DB) (googleCal, caldavCal string) {
	t.Helper()
	gid, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", CalendarEnabled: true})
	require.NoError(t, err)
	cid, err := d.CreateCalendarAccount(db.CalendarAccount{Provider: "caldav", URL: "https://dav.example.com", Label: "team"})
	require.NoError(t, err)
	caldavCal = db.CalendarAccountCalendarID("caldav", cid)
	mustExec(t, d, `INSERT INTO calendar_calendars (id, name, account_id) VALUES ('g-cal', 'Work calendar', ?)`, gid)
	mustExec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES (?, 'Team calendar')`, caldavCal)
	return "g-cal", caldavCal
}

func seedEvent(t *testing.T, d *db.DB, id, calendarID string, start time.Time, status, description string) {
	t.Helper()
	mustExec(t, d, `INSERT INTO calendar_events (id, calendar_id, title, description, start_time, end_time, event_status, attendees)
		VALUES (?, ?, 'title '||?, ?, ?, ?, ?, '[{"email":"a@example.com"}]')`,
		id, calendarID, id, description, utcText(start), utcText(start.Add(time.Hour)), status)
}

func TestListCalendarEvents_RangeIncludesPast(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	gcal, _ := seedCalendars(t, d)
	now := time.Now().UTC().Truncate(time.Second)
	seedEvent(t, d, "today", gcal, now, "cancelled", "")
	seedEvent(t, d, "yesterday", gcal, now.Add(-24*time.Hour), "confirmed", "")
	seedEvent(t, d, "next-week", gcal, now.Add(7*24*time.Hour), "confirmed", "")

	var got calendarListResult
	from, to := now.Add(-25*time.Hour).Format(time.RFC3339), now.Add(24*time.Hour).Format(time.RFC3339)
	callAutomationRead(t, reg, "list_calendar_events", `{"from":"`+from+`","to":"`+to+`"}`, &got)
	assert.Equal(t, "yesterday,today", got.ids(), "past included, start order")
	assert.Equal(t, "cancelled", got.Events[1].Status, "a cancelled event is listed with its status")
	assert.Equal(t, "Work calendar", got.Events[0].Calendar)
	assert.Equal(t, "work", got.Events[0].Account)
	assert.JSONEq(t, `[{"email":"a@example.com"}]`, string(got.Events[0].Attendees))

	// to is exclusive.
	var excl calendarListResult
	callAutomationRead(t, reg, "list_calendar_events", `{"from":"`+from+`","to":"`+now.Format(time.RFC3339)+`"}`, &excl)
	assert.Equal(t, "yesterday", excl.ids())

	requireValidationError(t, reg, "list_calendar_events", `{"from":"`+to+`","to":"`+from+`"}`, "to must be after from")
	requireValidationError(t, reg, "list_calendar_events", `{"from":"`+from+`","to":"`+from+`"}`, "to must be after from")
	requireValidationError(t, reg, "list_calendar_events", `{"from":"`+from+`"}`, "required")
	requireValidationError(t, reg, "list_calendar_events", `{"from":"monday","to":"`+to+`"}`, "from")
}

func TestListCalendarEvents_AccountFilter(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	gcal, dav := seedCalendars(t, d)
	now := time.Now().UTC().Truncate(time.Second)
	seedEvent(t, d, "g1", gcal, now, "confirmed", strings.Repeat("d", 10*1024))
	seedEvent(t, d, "c1", dav, now.Add(time.Minute), "confirmed", "short")
	from, to := now.Add(-time.Hour).Format(time.RFC3339), now.Add(time.Hour).Format(time.RFC3339)
	window := `"from":"` + from + `","to":"` + to + `"`

	for account, want := range map[string]string{"work": "g1", "owner@example.com": "g1", "WORK": "g1", "team": "c1", "": "g1,c1"} {
		var got calendarListResult
		callAutomationRead(t, reg, "list_calendar_events", `{`+window+`,"account":"`+account+`"}`, &got)
		assert.Equal(t, want, got.ids(), "account %q", account)
	}
	requireValidationError(t, reg, "list_calendar_events", `{`+window+`,"account":"nobody"}`, "unknown account")

	var got calendarListResult
	callAutomationRead(t, reg, "list_calendar_events", `{`+window+`}`, &got)
	assert.Len(t, got.Events[0].Description, 4*1024)
	assert.True(t, got.Events[0].DescriptionTruncated)
	assert.Equal(t, "short", got.Events[1].Description)
	assert.False(t, got.Events[1].DescriptionTruncated)
	assert.Equal(t, "team", got.Events[1].Account)
}

// ── meeting recaps and notes ──────────────────────────────────────────────────

type recapDetail struct {
	ID              int64           `json:"id"`
	EventID         string          `json:"event_id"`
	EventTitle      string          `json:"event_title"`
	EventStart      string          `json:"event_start"`
	Recap           json.RawMessage `json:"recap"`
	RecapTruncated  bool            `json:"recap_truncated"`
	SourceText      string          `json:"source_text"`
	SourceTruncated bool            `json:"source_truncated"`
}

func TestMeetingRecapTools_ListAndGet(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	gcal, _ := seedCalendars(t, d)
	now := time.Now().UTC().Truncate(time.Second)
	seedEvent(t, d, "old", gcal, now.Add(-48*time.Hour), "confirmed", "")
	seedEvent(t, d, "new", gcal, now.Add(-2*time.Hour), "confirmed", "")
	require.NoError(t, d.UpsertMeetingRecap("old", "short source", `{"summary":"old meeting"}`, 0))
	bigRecap := `{"summary":"` + strings.Repeat("r", 40*1024) + `"}`
	require.NoError(t, d.UpsertMeetingRecap("new", strings.Repeat("s", 40*1024), bigRecap, 0))

	var list struct {
		Recaps []recapDetail `json:"recaps"`
	}
	raw := callAutomationRead(t, reg, "list_meeting_recaps", `{}`, &list)
	require.Len(t, list.Recaps, 2)
	assert.Equal(t, "new", list.Recaps[0].EventID, "newest meeting first")
	assert.Equal(t, "title new", list.Recaps[0].EventTitle)
	assert.Equal(t, utcText(now.Add(-2*time.Hour)), list.Recaps[0].EventStart)
	assert.NotContains(t, raw, "short source", "a list carries no texts")

	var since struct {
		Recaps []recapDetail `json:"recaps"`
	}
	callAutomationRead(t, reg, "list_meeting_recaps", `{"since":"`+now.Add(-24*time.Hour).Format(time.RFC3339)+`"}`, &since)
	require.Len(t, since.Recaps, 1)
	assert.Equal(t, "new", since.Recaps[0].EventID)

	var byID, byEvent recapDetail
	callAutomationRead(t, reg, "get_meeting_recap", fmt.Sprintf(`{"id":%d}`, list.Recaps[1].ID), &byID)
	callAutomationRead(t, reg, "get_meeting_recap", `{"event_id":"old"}`, &byEvent)
	assert.Equal(t, byID, byEvent)
	assert.JSONEq(t, `{"summary":"old meeting"}`, string(byID.Recap))
	assert.False(t, byID.RecapTruncated)
	assert.Equal(t, "short source", byID.SourceText)

	var big recapDetail
	callAutomationRead(t, reg, "get_meeting_recap", `{"event_id":"new"}`, &big)
	assert.Len(t, big.SourceText, 32*1024)
	assert.True(t, big.SourceTruncated)
	assert.True(t, big.RecapTruncated)
	var recapText string
	require.NoError(t, json.Unmarshal(big.Recap, &recapText), "an oversized recap comes back as clipped text")
	assert.Len(t, recapText, 32*1024)

	requireValidationError(t, reg, "get_meeting_recap", `{"id":1,"event_id":"old"}`, "exactly one")
	requireValidationError(t, reg, "get_meeting_recap", `{}`, "exactly one")
	requireValidationError(t, reg, "get_meeting_recap", `{"event_id":"missing"}`, "no meeting recap")
	requireValidationError(t, reg, "get_meeting_recap", `{"id":999}`, "no meeting recap")
}

func TestMeetingRecapTools_NotesOfOneEvent(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	old := utcText(time.Now().Add(-48 * time.Hour))
	mustExec(t, d, `INSERT INTO meeting_notes (event_id, type, text, sort_order, created_at, updated_at) VALUES
		('ev1', 'note', 'second', 2, ?1, ?1), ('ev1', 'question', 'first', 1, ?1, ?1), ('ev2', 'note', 'other', 0, ?1, ?1)`, old)
	mustExec(t, d, `INSERT INTO meeting_notes (event_id, type, text, sort_order, is_checked, task_id) VALUES ('ev2', 'note', 'fresh', 1, 1, 7)`)

	var got struct {
		Notes []struct {
			EventID   string `json:"event_id"`
			Text      string `json:"text"`
			IsChecked bool   `json:"is_checked"`
			TaskID    *int64 `json:"task_id"`
		} `json:"notes"`
	}
	callAutomationRead(t, reg, "list_meeting_notes", `{"event_id":"ev1"}`, &got)
	require.Len(t, got.Notes, 2)
	assert.Equal(t, "first", got.Notes[0].Text, "in sort_order")
	assert.Equal(t, "second", got.Notes[1].Text)
	assert.Nil(t, got.Notes[0].TaskID)

	callAutomationRead(t, reg, "list_meeting_notes", `{"since":"`+time.Now().Add(-time.Hour).Format(time.RFC3339)+`"}`, &got)
	require.Len(t, got.Notes, 1)
	assert.Equal(t, "fresh", got.Notes[0].Text)
	assert.True(t, got.Notes[0].IsChecked)
	require.NotNil(t, got.Notes[0].TaskID)
	assert.Equal(t, int64(7), *got.Notes[0].TaskID)

	requireValidationError(t, reg, "list_meeting_notes", `{}`, "give event_id, since, or both")
	assert.Contains(t, callReadString(t, reg, "list_meeting_notes", `{"event_id":"none"}`), `"notes":[]`)
}

// ── day plans ─────────────────────────────────────────────────────────────────

type dayPlanGetResult struct {
	Plan *struct {
		ID        int64  `json:"id"`
		PlanDate  string `json:"plan_date"`
		ItemCount int    `json:"item_count"`
		DoneCount int    `json:"done_count"`
	} `json:"plan"`
	Items []struct {
		Title      string          `json:"title"`
		OrderIndex int             `json:"order_index"`
		Tags       json.RawMessage `json:"tags"`
	} `json:"items"`
}

func seedDayPlan(t *testing.T, d *db.DB, userID, date string, statuses ...string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO day_plans (user_id, plan_date, generated_at) VALUES (?, ?, ?)`, userID, date, utcText(time.Now()))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	for i, s := range statuses {
		// Reverse order_index against insertion, so the read must sort.
		mustExec(t, d, `INSERT INTO day_plan_items (day_plan_id, kind, source_type, title, status, order_index, tags)
			VALUES (?, 'backlog', 'manual', ?, ?, ?, '["x"]')`, id, fmt.Sprintf("item %d", i), s, len(statuses)-i)
	}
	return id
}

func TestDayPlanTools_OwnerPlanAndItems(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	for _, name := range []string{"list_day_plans", "get_day_plan"} {
		_, err := reg.CallRead(context.Background(), name, json.RawMessage(`{}`), Binding{})
		require.ErrorIs(t, err, db.ErrNoOwner, "%s with no owner is the OWNER-02 error, never an empty result", name)
	}

	_, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work"})
	require.NoError(t, err)
	owner := "google:owner@example.com"
	today := time.Now().Format("2006-01-02")
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	todayID := seedDayPlan(t, d, owner, today, "done", "pending", "done")
	seedDayPlan(t, d, owner, yesterday, "pending")
	otherID := seedDayPlan(t, d, "google:someone@example.com", today, "pending")

	var list struct {
		Plans []struct {
			PlanDate  string `json:"plan_date"`
			ItemCount int    `json:"item_count"`
			DoneCount int    `json:"done_count"`
		} `json:"plans"`
	}
	callAutomationRead(t, reg, "list_day_plans", `{}`, &list)
	require.Len(t, list.Plans, 2, "only the owner's plans")
	assert.Equal(t, today, list.Plans[0].PlanDate)
	assert.Equal(t, 3, list.Plans[0].ItemCount)
	assert.Equal(t, 2, list.Plans[0].DoneCount)
	callAutomationRead(t, reg, "list_day_plans", `{"since":"`+today+`"}`, &list)
	assert.Len(t, list.Plans, 1)

	var got dayPlanGetResult
	callAutomationRead(t, reg, "get_day_plan", `{}`, &got)
	require.NotNil(t, got.Plan)
	assert.Equal(t, todayID, got.Plan.ID)
	assert.Equal(t, 3, got.Plan.ItemCount)
	require.Len(t, got.Items, 3)
	assert.Equal(t, []int{1, 2, 3}, []int{got.Items[0].OrderIndex, got.Items[1].OrderIndex, got.Items[2].OrderIndex})
	assert.JSONEq(t, `["x"]`, string(got.Items[0].Tags))

	var byID dayPlanGetResult
	callAutomationRead(t, reg, "get_day_plan", fmt.Sprintf(`{"id":%d}`, todayID), &byID)
	assert.Equal(t, got, byID)

	raw := callAutomationRead(t, reg, "get_day_plan", `{"date":"2001-01-01"}`, &got)
	assert.JSONEq(t, `{"plan":null,"items":[]}`, raw)

	requireValidationError(t, reg, "get_day_plan", fmt.Sprintf(`{"id":%d}`, otherID), "no day plan")
	requireValidationError(t, reg, "get_day_plan", `{"date":"today"}`, "date")
	requireValidationError(t, reg, "get_day_plan", fmt.Sprintf(`{"id":%d,"date":"%s"}`, todayID, today), "not both")
}

// ── list_reminders ────────────────────────────────────────────────────────────

func TestListReminders_StatusAndDue(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	now := time.Now().UTC().Truncate(time.Second)
	for _, r := range []struct {
		note, status string
		at           time.Time
	}{
		{"later", "pending", now.Add(48 * time.Hour)},
		{"soon", "pending", now.Add(time.Hour)},
		{"finished", "done", now.Add(-time.Hour)},
		{"dropped", "dismissed", now.Add(2 * time.Hour)},
	} {
		mustExec(t, d, `INSERT INTO reminders (note, remind_at, status) VALUES (?, ?, ?)`, r.note, utcText(r.at), r.status)
	}
	notes := func(args string) string {
		var got struct {
			Reminders []struct {
				Note string `json:"note"`
			} `json:"reminders"`
		}
		callAutomationRead(t, reg, "list_reminders", args, &got)
		out := []string{}
		for _, r := range got.Reminders {
			out = append(out, r.Note)
		}
		return strings.Join(out, ",")
	}
	assert.Equal(t, "soon,later", notes(`{}`), "pending, soonest first")
	assert.Equal(t, "soon", notes(`{"due_before":"`+now.Add(24*time.Hour).Format(time.RFC3339)+`"}`))
	assert.Equal(t, "finished,soon,dropped,later", notes(`{"status":"all"}`))
	assert.Equal(t, "dropped", notes(`{"status":"dismissed"}`))
	requireValidationError(t, reg, "list_reminders", `{"status":"snoozed"}`, "status")
	requireValidationError(t, reg, "list_reminders", `{"due_before":"soon"}`, "due_before")
}

// ── Jira sprints and releases ─────────────────────────────────────────────────

func seedJiraSprintsAndReleases(t *testing.T, d *db.DB) {
	t.Helper()
	acct := db.SeedTestJiraAccount(t, d)
	mustExec(t, d, `INSERT INTO jira_boards (account_id, id, name, project_key) VALUES (?1, 7, 'Payments board', 'PAY'), (?1, 8, 'Ops board', 'OPS')`, acct)
	mustExec(t, d, `INSERT INTO jira_sprints (account_id, id, board_id, name, state, start_date) VALUES
		(?1, 1, 7, 'PAY 1', 'closed', '2026-01-01'), (?1, 2, 7, 'PAY 2', 'active', '2026-02-01'), (?1, 3, 8, 'OPS 1', 'active', '2026-02-01')`, acct)
	mustExec(t, d, `INSERT INTO jira_releases (account_id, id, project_key, name, description, release_date, released, archived) VALUES
		(?1, 10, 'PAY', 'pay-1.0', ?2, '2026-01-10', 1, 0),
		(?1, 11, 'PAY', 'pay-2.0', '', '2026-03-10', 0, 0),
		(?1, 12, 'PAY', 'pay-0.9', '', '2025-12-01', 1, 1),
		(?1, 13, 'OPS', 'ops-1.0', '', '2026-02-10', 0, 0)`, acct, strings.Repeat("n", 10*1024))
}

type jiraNamesResult struct {
	Sprints []struct {
		Name       string `json:"name"`
		ProjectKey string `json:"project_key"`
		BoardName  string `json:"board_name"`
	} `json:"sprints"`
	Releases []struct {
		Name                 string `json:"name"`
		Description          string `json:"description"`
		DescriptionTruncated bool   `json:"description_truncated"`
	} `json:"releases"`
}

func (r jiraNamesResult) names() string {
	out := []string{}
	for _, s := range r.Sprints {
		out = append(out, s.Name)
	}
	for _, s := range r.Releases {
		out = append(out, s.Name)
	}
	return strings.Join(out, ",")
}

func TestJiraSprintReleaseTools_ProjectAndBoard(t *testing.T) {
	d, reg := automationReadsRegistry(t)
	seedJiraSprintsAndReleases(t, d)

	cases := []struct{ tool, args, want string }{
		{"list_jira_sprints", `{"project":"pay"}`, "PAY 2,PAY 1"},
		{"list_jira_sprints", `{"board_id":8}`, "OPS 1"},
		{"list_jira_sprints", `{"project":"PAY","state":"active"}`, "PAY 2"},
		{"list_jira_sprints", `{"project":"PAY","board_id":8}`, ""},
		{"list_jira_releases", `{"project":"PAY"}`, "pay-2.0,pay-1.0"},
		{"list_jira_releases", `{"project":"pay","include_archived":true}`, "pay-2.0,pay-1.0,pay-0.9"},
		{"list_jira_releases", `{"released":false}`, "pay-2.0,ops-1.0"},
		{"list_jira_releases", `{"project":"PAY","released":true}`, "pay-1.0"},
	}
	for _, c := range cases {
		var got jiraNamesResult
		callAutomationRead(t, reg, c.tool, c.args, &got)
		assert.Equal(t, c.want, got.names(), "%s %s", c.tool, c.args)
	}

	var sprints jiraNamesResult
	callAutomationRead(t, reg, "list_jira_sprints", `{"project":"pay"}`, &sprints)
	assert.Equal(t, "PAY", sprints.Sprints[0].ProjectKey)
	assert.Equal(t, "Payments board", sprints.Sprints[0].BoardName)

	var rel jiraNamesResult
	callAutomationRead(t, reg, "list_jira_releases", `{"project":"PAY","released":true}`, &rel)
	assert.Len(t, rel.Releases[0].Description, 4*1024)
	assert.True(t, rel.Releases[0].DescriptionTruncated)

	requireValidationError(t, reg, "list_jira_sprints", `{"state":"done"}`, "state")
}

// ── surfaces and memory_open ──────────────────────────────────────────────────

func TestD23Tools_AutomationSurfaceOnly(t *testing.T) {
	inReadTools := map[string]bool{}
	for _, rt := range ReadTools() {
		inReadTools[rt.Name] = true
	}
	d23 := AutomationReadTools()
	require.Len(t, d23, 10)
	for _, tool := range d23 {
		assert.False(t, inReadTools[tool.Name], "%s must not be in ReadTools() (DEV-01)", tool.Name)
		assert.True(t, tool.VisibleOn(AutomationSurface), tool.Name)
		assert.False(t, tool.VisibleOn("main"), tool.Name)
		assert.Equal(t, AccessRead, tool.Access, tool.Name)
	}
	for _, tool := range d23 {
		if strings.HasPrefix(tool.Name, "list_") {
			assert.NotNil(t, tool.InputSchema.Properties["limit"], "%s has a limit, so ClampListLimit applies", tool.Name)
		}
	}

	style := NewGetWritingStyle()
	for _, s := range []string{"main", WorkbenchSurface, AutomationSurface} {
		assert.True(t, style.VisibleOn(s), "get_writing_style on %s", s)
	}
	assert.False(t, inReadTools[style.Name])
	assert.False(t, NewGetConfluencePage(nil).VisibleOn(AutomationSurface), "a live network read stays off the automation surface")
}

func TestMemoryOpen_NoAccessBumpOnAutomationSurface(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)
	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryOpen(vaultPath)))

	data, err := reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"pay-svc"}`),
		Binding{Surface: AutomationSurface})
	require.NoError(t, err)
	b, err := json.Marshal(data)
	require.NoError(t, err)
	assert.Contains(t, string(b), tPayments.ID, "the node is returned")
	assert.Equal(t, 0, statsRows(t, database), "an automation's open writes no access stat")

	_, err = reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"pay-svc"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	assert.Equal(t, 1, statsRows(t, database), "the main chat's open still bumps")
}
