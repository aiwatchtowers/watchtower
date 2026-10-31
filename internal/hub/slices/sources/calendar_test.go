package sources

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
)

// calNow is Wed 2026-10-14 12:00 UTC.
var calNow = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)

type calRig struct {
	d   *db.DB
	src hubslices.Source
	cs  *calendarSource
}

func newCalRig(t *testing.T, loc *time.Location) *calRig {
	t.Helper()
	d := openDB(t)
	exec(t, d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal', 'Work')`)
	src := CalendarEvent(d, CalendarOptions{Now: func() time.Time { return calNow }, Location: loc})
	return &calRig{d: d, src: src, cs: src.(*calendarSource)}
}

type evSeed struct {
	id, title, uid, conf, status, attendees, desc, loc string
	start, end                                         time.Time
	allDay                                             bool
}

func (r *calRig) event(t *testing.T, s evSeed) {
	t.Helper()
	if s.start.IsZero() {
		s.start = calNow.Add(time.Hour)
	}
	if s.end.IsZero() {
		s.end = s.start.Add(time.Hour)
	}
	if s.status == "" {
		s.status = "confirmed"
	}
	if s.attendees == "" {
		s.attendees = "[]"
	}
	exec(t, r.d, `INSERT INTO calendar_events (id, calendar_id, title, description, location, start_time, end_time, attendees,
		is_all_day, event_status, conference_url, ical_uid, raw_json) VALUES (?, 'cal', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{"secret":"x"}')`,
		s.id, s.title, s.desc, s.loc, isoStamp(s.start), isoStamp(s.end), s.attendees, s.allDay, s.status, s.conf, s.uid)
}

func (r *calRig) byID(t *testing.T) map[string]map[string]any {
	t.Helper()
	items, err := r.src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, it := range items {
		out[it.ID] = decode(t, it.Payload)
	}
	return out
}

func (r *calRig) ids(t *testing.T) []string {
	t.Helper()
	items, err := r.src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, it := range items {
		out = append(out, it.ID)
	}
	return out
}

func TestCalendarPayloadShapeAndNoRawJSON(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e1", title: "Standup", loc: "Room 1", desc: "<p>Hello&nbsp;<b>team</b> &amp;lt;</p>", conf: "https://meet.example.com/x",
		attendees: `[{"email":"a@example.com","display_name":"A","response_status":"accepted"}]`})
	p := r.byID(t)["e1"]
	for _, k := range []string{"id", "start_time", "end_time", "is_all_day", "is_recurring", "event_status", "organizer_email", "html_link",
		"conference_url", "title", "location", "description", "attendees", "prep_bullets", "linked_targets"} {
		if _, ok := p[k]; !ok {
			t.Errorf("missing key %s", k)
		}
	}
	for _, k := range []string{"title_clipped", "attendees_more", "prep_bullets_more", "prep_generated_at", "linked_targets_more"} {
		if _, ok := p[k]; ok {
			t.Errorf("unexpected optional key %s", k)
		}
	}
	if p["description"] != "Hello team &lt;" {
		t.Errorf("description = %q", p["description"])
	}
	if strings.Contains(fmt.Sprint(p), "secret") {
		t.Error("raw_json leaked")
	}
}

func TestCalendarCancelledIsNeverPublishedNorWinsDedup(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "a", uid: "u", status: "cancelled", conf: "https://m.example.com/1"})
	r.event(t, evSeed{id: "b", uid: "u"})
	got := r.ids(t)
	if len(got) != 1 || got[0] != "b" {
		t.Fatalf("ids = %v", got)
	}
}

func TestCalendarDedupKeepsConferenceCopyElseLowestID(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "a1", uid: "u1"})
	r.event(t, evSeed{id: "a2", uid: "u1", conf: "https://m.example.com/2"})
	r.event(t, evSeed{id: "b1", uid: "u2", conf: "https://m.example.com/3"})
	r.event(t, evSeed{id: "b2", uid: "u2", conf: "https://m.example.com/4"})
	r.event(t, evSeed{id: "c2", uid: "u3"})
	r.event(t, evSeed{id: "c1", uid: "u3"})
	r.event(t, evSeed{id: "d1", uid: ""})
	r.event(t, evSeed{id: "d2", uid: ""})
	// A recurring instance with the same uid at another start stays separate.
	r.event(t, evSeed{id: "e1", uid: "u4"})
	r.event(t, evSeed{id: "e2", uid: "u4", start: calNow.Add(48 * time.Hour)})
	got := map[string]bool{}
	for _, id := range r.ids(t) {
		got[id] = true
	}
	for _, id := range []string{"a2", "b1", "c1", "d1", "d2", "e1", "e2"} {
		if !got[id] {
			t.Errorf("%s not published (%v)", id, got)
		}
	}
	for _, id := range []string{"a1", "b2", "c2"} {
		if got[id] {
			t.Errorf("%s published", id)
		}
	}
}

func TestCalendarKeptCopyCarriesPrepAndTargetsOfTheDroppedCopy(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "a1", uid: "u"})
	r.event(t, evSeed{id: "a2", uid: "u", conf: "https://m.example.com/2"})
	exec(t, r.d, `INSERT INTO meeting_prep_cache (event_id, result_json, generated_at) VALUES ('a1', '{"talking_points":[{"text":"tp1"},{"text":"  "}],"suggested_prep":["sp1"]}', '2026-10-14T08:00:00Z')`)
	tg := execID(t, r.d, `INSERT INTO targets (text, period_start, period_end) VALUES ('Ship it', '2026-10-01', '2026-10-31')`)
	board := execID(t, r.d, `INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('On a board', '2026-10-01', '2026-10-31', ?)`, seedWorkbench(t, r.d, "wb"))
	exec(t, r.d, `INSERT INTO meeting_transcripts (event_id, title, transcript_text, chapters_json, created_at) VALUES ('a1', 'T', '', ?, '2026-10-13T08:00:00Z')`,
		fmt.Sprintf(`{"overall_summary":"o","chapters":[{"action_items":[{"text":"x","converted_target_id":%d},"bare",{"text":"y","converted_target_id":%d},{"text":"z","converted_target_id":999}]}]}`, tg, board))
	p := r.byID(t)["a2"]
	if fmt.Sprint(p["prep_bullets"]) != "[tp1 sp1]" || p["prep_generated_at"] != "2026-10-14T08:00:00Z" {
		t.Errorf("prep = %v %v", p["prep_bullets"], p["prep_generated_at"])
	}
	lt := p["linked_targets"].([]any)
	if len(lt) != 1 || lt[0].(map[string]any)["text"] != "Ship it" {
		t.Errorf("linked = %v", lt)
	}
}

func TestCalendarPrivateRecordingLinksNoTargets(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e"})
	tg := execID(t, r.d, `INSERT INTO targets (text, period_start, period_end) VALUES ('Secret plan', '2026-10-01', '2026-10-31')`)
	exec(t, r.d, `INSERT INTO meeting_transcripts (event_id, title, transcript_text, chapters_json, private) VALUES ('e', 'T', '', ?, 1)`,
		fmt.Sprintf(`{"chapters":[{"action_items":[{"text":"x","converted_target_id":%d}]}]}`, tg))
	if lt := r.byID(t)["e"]["linked_targets"].([]any); len(lt) != 0 {
		t.Errorf("a private recording linked %v", lt)
	}
}

func TestCalendarPrepCapsAndUnreadableWarnsOnce(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e"})
	var tps []string
	for i := 0; i < 10; i++ {
		tps = append(tps, fmt.Sprintf(`{"text":"p%d"}`, i))
	}
	long := strings.Repeat("x", 400)
	exec(t, r.d, `INSERT INTO meeting_prep_cache (event_id, result_json) VALUES ('e', ?)`,
		`{"talking_points":[`+strings.Join(tps, ",")+`],"suggested_prep":["`+long+`","s2"]}`)
	p := r.byID(t)["e"]
	b := p["prep_bullets"].([]any)
	if len(b) != 8 || num(p["prep_bullets_more"]) != 4 || b[0] != "p0" {
		t.Errorf("bullets = %d more %v", len(b), p["prep_bullets_more"])
	}
	exec(t, r.d, `UPDATE meeting_prep_cache SET result_json = 'nope'`)
	r.byID(t)
	r.byID(t)
	if !r.cs.warns.has("meeting prep", "e", "nope") || r.cs.warns.count("e") != 1 {
		t.Error("unreadable prep not warned once")
	}
	if p := r.byID(t)["e"]; len(p["prep_bullets"].([]any)) != 0 {
		t.Error("unreadable prep published")
	}
	// A warning is forgotten once its event leaves the window.
	exec(t, r.d, `UPDATE calendar_events SET start_time = '2020-01-01T00:00:00Z', end_time = '2020-01-01T01:00:00Z'`)
	r.byID(t)
	if r.cs.warns.count("e") != 0 {
		t.Error("warning kept for an event outside the window")
	}
}

func TestCalendarLongPrepBulletClips(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e"})
	exec(t, r.d, `INSERT INTO meeting_prep_cache (event_id, result_json) VALUES ('e', ?)`, `{"suggested_prep":["`+strings.Repeat("y", 400)+`"]}`)
	if got := runes(r.byID(t)["e"]["prep_bullets"].([]any)[0]); got != 300 {
		t.Errorf("bullet length = %d", got)
	}
}

func TestCalendarAttendees(t *testing.T) {
	r := newCalRig(t, time.UTC)
	var many []string
	for i := 0; i < 101; i++ {
		many = append(many, fmt.Sprintf(`{"email":"p%d@example.com"}`, i))
	}
	r.event(t, evSeed{id: "many", attendees: "[" + strings.Join(many, ",") + "]"})
	r.event(t, evSeed{id: "null", attendees: "null"})
	r.event(t, evSeed{id: "bad", attendees: `{"x":1}`})
	got := r.byID(t)
	if len(got["many"]["attendees"].([]any)) != 100 || num(got["many"]["attendees_more"]) != 1 {
		t.Error("101 attendees must keep 100 and report 1 more")
	}
	if a := got["many"]["attendees"].([]any)[0].(map[string]any); a["display_name"] != "" || a["response_status"] != "" {
		t.Errorf("missing attendee keys must read empty: %v", a)
	}
	if len(got["null"]["attendees"].([]any)) != 0 || r.cs.warns.has("attendees", "null", "null") {
		t.Error("null attendees are an empty list without a warning")
	}
	if len(got["bad"]["attendees"].([]any)) != 0 || !r.cs.warns.has("attendees", "bad", `{"x":1}`) {
		t.Error("unreadable attendees must publish empty and warn")
	}
}

func TestCalendarTitleLocationDescriptionClip(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e", title: strings.Repeat("t", 301), loc: strings.Repeat("l", 300), desc: strings.Repeat("d", 2001)})
	p := r.byID(t)["e"]
	if runes(p["title"]) != 300 || p["title_clipped"] != true {
		t.Error("title must clip at 300")
	}
	if _, ok := p["location_clipped"]; ok {
		t.Error("a 300-grapheme location is not clipped")
	}
	if runes(p["description"]) != 2000 || p["description_clipped"] != true {
		t.Error("description must clip at 2000")
	}
}

func TestCalendarWindowEdgesAndCap(t *testing.T) {
	r := newCalRig(t, time.UTC)
	// Window: 2026-10-13 00:00 UTC … 2026-10-28 12:00 UTC.
	r.event(t, evSeed{id: "before", start: time.Date(2026, 10, 12, 22, 0, 0, 0, time.UTC), end: time.Date(2026, 10, 12, 23, 0, 0, 0, time.UTC)})
	r.event(t, evSeed{id: "ends-at-start", start: time.Date(2026, 10, 12, 23, 0, 0, 0, time.UTC), end: time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)})
	r.event(t, evSeed{id: "over-midnight", start: time.Date(2026, 10, 12, 23, 0, 0, 0, time.UTC), end: time.Date(2026, 10, 13, 1, 0, 0, 0, time.UTC)})
	r.event(t, evSeed{id: "starts-at-end", start: time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)})
	r.event(t, evSeed{id: "after", start: time.Date(2026, 10, 28, 12, 0, 1, 0, time.UTC)})
	got := map[string]bool{}
	for _, id := range r.ids(t) {
		got[id] = true
	}
	want := map[string]bool{"ends-at-start": true, "over-midnight": true, "starts-at-end": true}
	if len(got) != len(want) {
		t.Fatalf("published %v, want %v", got, want)
	}
	for id := range want {
		if !got[id] {
			t.Errorf("%s missing", id)
		}
	}
}

func TestCalendarFiveHundredAndOneKeepTheEarliest(t *testing.T) {
	r := newCalRig(t, time.UTC)
	for i := 0; i < 501; i++ {
		r.event(t, evSeed{id: fmt.Sprintf("e%03d", i), start: calNow.Add(time.Duration(i) * time.Minute)})
	}
	ids := r.ids(t)
	if len(ids) != 500 || ids[0] != "e000" || ids[499] != "e499" {
		t.Fatalf("got %d first %s", len(ids), ids[0])
	}
}

func TestCalendarOrderIsLocalStartThenID(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "b", start: calNow.Add(2 * time.Hour)})
	r.event(t, evSeed{id: "c", start: calNow.Add(time.Hour)})
	r.event(t, evSeed{id: "a", start: calNow.Add(time.Hour)})
	if got := strings.Join(r.ids(t), ","); got != "a,c,b" {
		t.Errorf("order = %s", got)
	}
}

func TestCalendarAllDayKeepsItsDayWestOfUTC(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip("no tz database")
	}
	r := newCalRig(t, la)
	// All-day on 2026-10-12 (stored UTC midnight → local midnight Oct 12 in LA):
	// the window starts at LA midnight Oct 13 (now is Oct 14 05:00 LA), so Oct 12 is out
	// and the one-day event on Oct 13 is in.
	day := func(d int) time.Time { return time.Date(2026, 10, d, 0, 0, 0, 0, time.UTC) }
	r.event(t, evSeed{id: "oct12", allDay: true, start: day(12), end: day(13)})
	r.event(t, evSeed{id: "oct13", allDay: true, start: day(13), end: day(14)})
	got := strings.Join(r.ids(t), ",")
	if got != "oct13" {
		t.Errorf("published %s, want oct13", got)
	}
}

func TestCalendarAllDayBeforeWindowStaysOutEastOfUTC(t *testing.T) {
	tokyo, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Skip("no tz database")
	}
	r := newCalRig(t, tokyo)
	day := func(d int) time.Time { return time.Date(2026, 10, d, 0, 0, 0, 0, time.UTC) }
	// Window starts at Tokyo midnight Oct 13; an all-day Oct 12 ends (exclusive) there.
	r.event(t, evSeed{id: "oct12", allDay: true, start: day(12), end: day(13)})
	r.event(t, evSeed{id: "oct13", allDay: true, start: day(13), end: day(14)})
	if got := strings.Join(r.ids(t), ","); got != "oct13" {
		t.Errorf("published %s, want oct13", got)
	}
}

func TestCalendarWindowStartsAtLocalMidnightAcrossDST(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip("no tz database")
	}
	// 2026-11-01 is the fall-back day in LA: yesterday's midnight is 24+ hours
	// before the start of today, a calendar step, not 24 hours.
	now := time.Date(2026, 11, 2, 9, 0, 0, 0, la)
	w := calendarWindow(now, la)
	if want := time.Date(2026, 11, 1, 0, 0, 0, 0, la); !w.start.Equal(want) {
		t.Errorf("start = %v, want %v", w.start, want)
	}
	if want := time.Date(2026, 11, 16, 9, 0, 0, 0, la); !w.end.Equal(want) {
		t.Errorf("end = %v, want %v", w.end, want)
	}
}

func TestCalendarLinkedTargetsCapAtTwentyAndClipText(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e"})
	var items []string
	for i := 0; i < 21; i++ {
		id := execID(t, r.d, `INSERT INTO targets (text, period_start, period_end) VALUES (?, '2026-10-01', '2026-10-31')`, strings.Repeat("z", 250))
		items = append(items, fmt.Sprintf(`{"text":"i","converted_target_id":%d}`, id))
	}
	exec(t, r.d, `INSERT INTO meeting_transcripts (event_id, title, transcript_text, chapters_json) VALUES ('e', 'T', '', ?)`,
		`{"chapters":[{"action_items":[`+strings.Join(items, ",")+`]}]}`)
	p := r.byID(t)["e"]
	lt := p["linked_targets"].([]any)
	if len(lt) != 20 || num(p["linked_targets_more"]) != 1 || runes(lt[0].(map[string]any)["text"]) != 200 {
		t.Errorf("linked = %d more %v", len(lt), p["linked_targets_more"])
	}
}

func TestCalendarUnreadableChaptersWarnAndLinkNothing(t *testing.T) {
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "e"})
	id := execID(t, r.d, `INSERT INTO meeting_transcripts (event_id, title, transcript_text, chapters_json) VALUES ('e', 'T', '', 'zz')`)
	r.byID(t)
	if !r.cs.warns.has("chapters_json", fmt.Sprint(id), "zz") {
		t.Error("unreadable chapters_json not warned")
	}
}
