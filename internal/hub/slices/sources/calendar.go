package sources

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
)

// The calendar_event slice's caps (CalendarEventSlice).
const (
	maxCalendarEvents  = 500
	maxAttendees       = 100
	maxPrepBullets     = 8
	maxLinkedTargets   = 20
	calendarDaysAhead  = 14
	maxEventTitle      = 300
	maxEventLocation   = 300
	maxEventDesc       = 2000
	maxPrepBulletText  = 300
	maxLinkedTargetTxt = 200
)

// CalendarOptions wires the calendar_event and meeting_transcript sources.
// Now (nil = time.Now) is the clock of the window; Location (nil = time.Local)
// decides local midnight, the Mac's calendar zone.
type CalendarOptions struct {
	Now      func() time.Time
	Location *time.Location
}

func (o CalendarOptions) now() time.Time {
	if o.Now == nil {
		return time.Now()
	}
	return o.Now()
}

func (o CalendarOptions) loc() *time.Location {
	if o.Location == nil {
		return time.Local
	}
	return o.Location
}

// CalendarEvent is the calendar_event slice (CalendarEventSlice, mobile POC
// spec §4.10), record calendar_event-<calendar_events.id>: a capped
// projection of each event in the window, never the raw row (raw_json is not
// even read).
//
// Window: events overlapping local today 00:00 − 1 day … now + 14 calendar
// days, not cancelled, ≤ 500, earliest first. An all-day event is placed by
// its stored calendar day (UTC midnight), read as local midnight. Same
// non-empty ical_uid and start_time (one event on two accounts' calendars)
// → one record: the copy with a conference_url, else the lowest id; prep and
// linked targets are read across all copies.
func CalendarEvent(d *db.DB, o CalendarOptions) hubslices.Source {
	return &calendarSource{d: d, o: o, warns: newWarnings()}
}

type calendarSource struct {
	d     *db.DB
	o     CalendarOptions
	warns *warnings
}

func (*calendarSource) Kind() hubslices.Kind { return "calendar_event" }

type attendee struct {
	Email          string `json:"email"`
	DisplayName    string `json:"display_name"`
	ResponseStatus string `json:"response_status"`
}

type linkedTarget struct {
	ID     int64  `json:"id"`
	Text   string `json:"text"`
	Status string `json:"status"`
}

// calendarPayload is the Kit mirror WatchtowerKit.CalendarEvent.
type calendarPayload struct {
	ID                 string         `json:"id"`
	StartTime          string         `json:"start_time"`
	EndTime            string         `json:"end_time"`
	IsAllDay           bool           `json:"is_all_day"`
	IsRecurring        bool           `json:"is_recurring"`
	EventStatus        string         `json:"event_status"`
	OrganizerEmail     string         `json:"organizer_email"`
	HTMLLink           string         `json:"html_link"`
	ConferenceURL      string         `json:"conference_url"`
	Title              string         `json:"title"`
	TitleClipped       *bool          `json:"title_clipped,omitempty"`
	Location           string         `json:"location"`
	LocationClipped    *bool          `json:"location_clipped,omitempty"`
	Description        string         `json:"description"`
	DescriptionClipped *bool          `json:"description_clipped,omitempty"`
	Attendees          []attendee     `json:"attendees"`
	AttendeesMore      *int           `json:"attendees_more,omitempty"`
	PrepBullets        []string       `json:"prep_bullets"`
	PrepBulletsMore    *int           `json:"prep_bullets_more,omitempty"`
	PrepGeneratedAt    *string        `json:"prep_generated_at,omitempty"`
	LinkedTargets      []linkedTarget `json:"linked_targets"`
	LinkedTargetsMore  *int           `json:"linked_targets_more,omitempty"`
}

// calEvent is one calendar_events row, without raw_json.
type calEvent struct {
	id, title, description, location, startTime, endTime string
	organizer, attendees, status, htmlLink, conference   string
	uid                                                  string
	recurring, allDay                                    bool
}

// calGroup is one published event with every copy's id (the published one first).
type calGroup struct {
	event   calEvent
	members []string
	start   time.Time
}

func (s *calendarSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	now := s.o.now()
	loc := s.o.loc()
	var items []hubslices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		groups, err := windowEvents(ctx, tx, calendarWindow(now, loc), loc, true)
		if err != nil {
			return err
		}
		var ids []string
		for _, g := range groups {
			ids = append(ids, g.members...)
		}
		s.warns.forget(ids)
		prep, err := s.prep(ctx, tx, ids)
		if err != nil {
			return err
		}
		linked, err := s.linkedTargets(ctx, tx, ids)
		if err != nil {
			return err
		}
		for _, g := range groups {
			var p *prepResult
			var targets [][]linkedTarget
			for _, m := range g.members {
				if p == nil {
					p = prep[m]
				}
				targets = append(targets, linked[m])
			}
			b, err := wire.Marshal(s.payload(g.event, p, unionTargets(targets)))
			if err != nil {
				return err
			}
			items = append(items, hubslices.Item{ID: g.event.id, Payload: b})
		}
		return nil
	})
	return items, err
}

func (s *calendarSource) payload(e calEvent, prep *prepResult, linked []linkedTarget) calendarPayload {
	title, titleClipped := clipText(e.title, maxEventTitle)
	location, locationClipped := clipText(e.location, maxEventLocation)
	desc, descClipped := clipText(stripHTML(e.description), maxEventDesc)
	attendees, attendeesMore := clipList(s.attendees(e), maxAttendees)
	var bullets []string
	var generated *string
	if prep != nil {
		bullets, generated = prep.bullets, &prep.generatedAt
	}
	bullets, bulletsMore := clipList(bullets, maxPrepBullets)
	targets, targetsMore := clipList(linked, maxLinkedTargets)
	out := make([]string, 0, len(bullets))
	for _, b := range bullets {
		t, _ := clipText(b, maxPrepBulletText)
		out = append(out, t)
	}
	return calendarPayload{
		ID: e.id, StartTime: e.startTime, EndTime: e.endTime, IsAllDay: e.allDay, IsRecurring: e.recurring,
		EventStatus: e.status, OrganizerEmail: e.organizer, HTMLLink: e.htmlLink, ConferenceURL: e.conference,
		Title: title, TitleClipped: titleClipped, Location: location, LocationClipped: locationClipped,
		Description: desc, DescriptionClipped: descClipped,
		Attendees: nonNil(attendees), AttendeesMore: attendeesMore,
		PrepBullets: out, PrepBulletsMore: bulletsMore, PrepGeneratedAt: generated,
		LinkedTargets: nonNil(targets), LinkedTargetsMore: targetsMore,
	}
}

func nonNil[T any](v []T) []T {
	if v == nil {
		return []T{}
	}
	return v
}

// attendees is the stored attendees JSON reduced to three keys. null and ""
// are an empty list; an unreadable list is logged once and published empty.
func (s *calendarSource) attendees(e calEvent) []attendee {
	if strings.TrimSpace(e.attendees) == "" {
		return nil
	}
	var out []attendee
	if err := json.Unmarshal([]byte(e.attendees), &out); err != nil {
		s.warns.warn("attendees", e.id, e.id, e.attendees)
		return nil
	}
	return out
}

// calendarWindowBounds are the window's instants.
type calendarWindowBounds struct{ start, end time.Time }

// calendarWindow is local 00:00 of yesterday to now + 14 calendar days.
func calendarWindow(now time.Time, loc *time.Location) calendarWindowBounds {
	n := now.In(loc)
	y, m, d := n.Date()
	return calendarWindowBounds{
		start: time.Date(y, m, d-1, 0, 0, 0, 0, loc),
		end:   n.AddDate(0, 0, calendarDaysAhead),
	}
}

// calendarWindowEventIDs is every event id the calendar window holds (each
// copy of a de-duplicated event included): meeting_transcript publishes the
// transcripts of these events whatever their age (spec §4.11).
func calendarWindowEventIDs(ctx context.Context, tx *sql.Tx, now time.Time, loc *time.Location) ([]string, error) {
	groups, err := windowEvents(ctx, tx, calendarWindow(now, loc), loc, false)
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, g := range groups {
		ids = append(ids, g.members...)
	}
	return ids, nil
}

const (
	eventPayloadColumns = `id, title, description, location, start_time, end_time, organizer_email, attendees,
		is_recurring, is_all_day, event_status, html_link, conference_url, ical_uid`
	// The window, the dedup and the order read no text column a payload needs.
	eventWindowColumns = `id, '', '', '', start_time, end_time, '', '', 0, is_all_day, '', '', conference_url, ical_uid`
)

// windowEvents is the window's events grouped and ordered (earliest local
// start, then id), at most 500. full false reads only the columns the
// window itself needs.
func windowEvents(ctx context.Context, tx *sql.Tx, w calendarWindowBounds, loc *time.Location, full bool) ([]calGroup, error) {
	cols := eventWindowColumns
	if full {
		cols = eventPayloadColumns
	}
	// A day of slack on each side for all-day rows (stored as UTC midnight);
	// the exact test runs below on local dates.
	var events []calEvent
	err := scanRows(ctx, tx, `SELECT `+cols+` FROM calendar_events
		WHERE event_status != 'cancelled' AND start_time <= ? AND end_time >= ?`,
		[]any{isoStamp(w.end.Add(24 * time.Hour)), isoStamp(w.start.Add(-24 * time.Hour))},
		func(r *sql.Rows) error {
			var e calEvent
			var rec, all int
			if err := r.Scan(&e.id, &e.title, &e.description, &e.location, &e.startTime, &e.endTime, &e.organizer,
				&e.attendees, &rec, &all, &e.status, &e.htmlLink, &e.conference, &e.uid); err != nil {
				return err
			}
			e.recurring, e.allDay = rec != 0, all != 0
			events = append(events, e)
			return nil
		})
	if err != nil {
		return nil, err
	}
	type located struct {
		e     calEvent
		start time.Time
	}
	var inside []located
	for _, e := range events {
		start := localStart(e, loc)
		if inWindow(e, start, w, loc) {
			inside = append(inside, located{e, start})
		}
	}
	// Lowest id first, so a later copy replaces the kept one only for a
	// conference link.
	sort.Slice(inside, func(i, j int) bool { return inside[i].e.id < inside[j].e.id })
	var groups []calGroup
	byKey := map[string]int{}
	for _, l := range inside {
		g := calGroup{event: l.e, members: []string{l.e.id}, start: l.start}
		if l.e.uid == "" {
			groups = append(groups, g)
			continue
		}
		key := l.e.uid + "\x00" + l.e.startTime
		i, ok := byKey[key]
		if !ok {
			byKey[key] = len(groups)
			groups = append(groups, g)
			continue
		}
		if groups[i].event.conference == "" && l.e.conference != "" {
			groups[i].event, groups[i].start = l.e, l.start
			groups[i].members = append([]string{l.e.id}, groups[i].members...)
		} else {
			groups[i].members = append(groups[i].members, l.e.id)
		}
	}
	sort.SliceStable(groups, func(i, j int) bool {
		if !groups[i].start.Equal(groups[j].start) {
			return groups[i].start.Before(groups[j].start)
		}
		return groups[i].event.id < groups[j].event.id
	})
	if len(groups) > maxCalendarEvents {
		groups = groups[:maxCalendarEvents]
	}
	return groups, nil
}

// inWindow is the overlap with the window: a timed event by its instants
// (end inclusive), an all-day event by its local days (end exclusive).
func inWindow(e calEvent, start time.Time, w calendarWindowBounds, loc *time.Location) bool {
	if !e.allDay {
		return !start.After(w.end) && !parseEventTime(e.endTime).Before(w.start)
	}
	end := localMidnightOfUTCDay(parseEventTime(e.endTime), loc)
	return !start.After(w.end) && end.After(w.start)
}

func localStart(e calEvent, loc *time.Location) time.Time {
	t := parseEventTime(e.startTime)
	if e.allDay {
		return localMidnightOfUTCDay(t, loc)
	}
	return t
}

// parseEventTime is CalendarEvent.startDate: ISO 8601 without fractional
// seconds; anything else is the zero time (Swift's distantPast).
func parseEventTime(s string) time.Time {
	if strings.Contains(s, ".") {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// localMidnightOfUTCDay is local midnight of the UTC calendar day t falls on.
func localMidnightOfUTCDay(t time.Time, loc *time.Location) time.Time {
	if t.IsZero() {
		return time.Time{}
	}
	y, m, d := t.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, loc)
}

// isoStamp is the database's UTC `YYYY-MM-DDTHH:MM:SSZ` form of t.
func isoStamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

// --- prep and linked targets ---

type prepResult struct {
	bullets     []string
	generatedAt string
}

// prep is event id → its meeting_prep_cache bullets. An empty result_json is
// no prep; an unreadable one is logged once and left out.
func (s *calendarSource) prep(ctx context.Context, tx *sql.Tx, ids []string) (map[string]*prepResult, error) {
	out := map[string]*prepResult{}
	if len(ids) == 0 {
		return out, nil
	}
	ph, args := inListStrings(ids)
	err := scanRows(ctx, tx, `SELECT event_id, result_json, generated_at FROM meeting_prep_cache
		WHERE result_json != '' AND event_id IN (`+ph+`)`, args, func(r *sql.Rows) error {
		var id, js, gen string
		if err := r.Scan(&id, &js, &gen); err != nil {
			return err
		}
		var res struct {
			TalkingPoints []struct {
				Text *string `json:"text"`
			} `json:"talking_points"`
			SuggestedPrep []string `json:"suggested_prep"`
		}
		if err := json.Unmarshal([]byte(js), &res); err != nil {
			s.warns.warn("meeting prep", id, id, js)
			return nil //nolint:nilerr // an unreadable prep is left out, logged once
		}
		var bullets []string
		for _, tp := range res.TalkingPoints {
			if tp.Text != nil {
				bullets = append(bullets, *tp.Text)
			}
		}
		bullets = append(bullets, res.SuggestedPrep...)
		kept := bullets[:0]
		for _, b := range bullets {
			if strings.TrimSpace(b) != "" {
				kept = append(kept, b)
			}
		}
		out[id] = &prepResult{bullets: kept, generatedAt: gen}
		return nil
	})
	return out, err
}

// chapterItem decodes both the persisted object form of a chapter action
// item and a bare string (ChapterActionItem.init(from:)).
type chapterItem struct{ converted *int64 }

func (c *chapterItem) UnmarshalJSON(b []byte) error {
	var bare string
	if json.Unmarshal(b, &bare) == nil {
		return nil
	}
	var obj struct {
		Text      *string `json:"text"`
		Converted *int64  `json:"converted_target_id"`
	}
	if err := json.Unmarshal(b, &obj); err != nil {
		return err
	}
	c.converted = obj.Converted
	return nil
}

// linkedTargets is event id → the targets converted from its transcripts'
// chapter action items, oldest transcript first. Not on a board only
// (project_id IS NULL, PROJ-01); a deleted target drops out.
func (s *calendarSource) linkedTargets(ctx context.Context, tx *sql.Tx, ids []string) (map[string][]linkedTarget, error) {
	out := map[string][]linkedTarget{}
	if len(ids) == 0 {
		return out, nil
	}
	ph, args := inListStrings(ids)
	type conv struct {
		event  string
		target int64
	}
	var converted []conv
	err := scanRows(ctx, tx, `SELECT id, event_id, chapters_json FROM meeting_transcripts
		WHERE chapters_json IS NOT NULL AND chapters_json != '' AND event_id IN (`+ph+`)
		ORDER BY created_at, id`, args, func(r *sql.Rows) error {
		var id int64
		var event, js string
		if err := r.Scan(&id, &event, &js); err != nil {
			return err
		}
		var ch struct {
			Chapters []struct {
				ActionItems []chapterItem `json:"action_items"`
			} `json:"chapters"`
		}
		if err := json.Unmarshal([]byte(js), &ch); err != nil {
			s.warns.warn("chapters_json", strconv.FormatInt(id, 10), event, js)
			return nil //nolint:nilerr // unreadable chapters link nothing, logged once
		}
		for _, c := range ch.Chapters {
			for _, it := range c.ActionItems {
				if it.converted != nil {
					converted = append(converted, conv{event, *it.converted})
				}
			}
		}
		return nil
	})
	if err != nil || len(converted) == 0 {
		return out, err
	}
	seen := map[int64]bool{}
	var targetIDs []int64
	for _, c := range converted {
		if !seen[c.target] {
			seen[c.target] = true
			targetIDs = append(targetIDs, c.target)
		}
	}
	tph, targs := inList(targetIDs)
	targets := map[int64]linkedTarget{}
	err = scanRows(ctx, tx, `SELECT id, text, status FROM targets WHERE project_id IS NULL AND id IN (`+tph+`)`,
		targs, func(r *sql.Rows) error {
			var t linkedTarget
			if err := r.Scan(&t.ID, &t.Text, &t.Status); err != nil {
				return err
			}
			t.Text, _ = clipText(t.Text, maxLinkedTargetTxt)
			targets[t.ID] = t
			return nil
		})
	if err != nil {
		return nil, err
	}
	for _, c := range converted {
		if t, ok := targets[c.target]; ok {
			out[c.event] = append(out[c.event], t)
		}
	}
	return out, nil
}

// unionTargets is the lists in order, each target once.
func unionTargets(lists [][]linkedTarget) []linkedTarget {
	seen := map[int64]bool{}
	var out []linkedTarget
	for _, l := range lists {
		for _, t := range l {
			if !seen[t.ID] {
				seen[t.ID] = true
				out = append(out, t)
			}
		}
	}
	return out
}

func inListStrings(ids []string) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return strings.TrimSuffix(strings.Repeat("?,", len(ids)), ","), args
}

// --- HTML to plain text (CalendarEvent.stripHTML) ---

var (
	reBR    = regexp.MustCompile(`(?i)<\s*br\s*/?\s*>`)
	reP     = regexp.MustCompile(`(?i)</\s*p\s*>`)
	reDiv   = regexp.MustCompile(`(?i)</\s*div\s*>`)
	reLI    = regexp.MustCompile(`(?i)</\s*li\s*>`)
	reHR    = regexp.MustCompile(`(?i)<\s*hr\s*/?\s*>`)
	reTag   = regexp.MustCompile(`<[^>]+>`)
	reBlank = regexp.MustCompile(`\n{3,}`)
	// entities replaces &amp; last so "&amp;lt;" stays the text "&lt;".
	entities = strings.NewReplacer("&nbsp;", " ", "&lt;", "<", "&gt;", ">", "&quot;", `"`, "&#39;", "'", "&apos;", "'", "&amp;", "&")
)

func stripHTML(in string) string {
	if in == "" {
		return ""
	}
	s := reBR.ReplaceAllString(in, "\n")
	s = reP.ReplaceAllString(s, "\n\n")
	s = reDiv.ReplaceAllString(s, "\n")
	s = reLI.ReplaceAllString(s, "\n")
	s = reHR.ReplaceAllString(s, "\n")
	s = reTag.ReplaceAllString(s, "")
	s = entities.Replace(s)
	s = reBlank.ReplaceAllString(s, "\n\n")
	return strings.TrimSpace(s)
}

// --- warn once (CalendarEventSlice.warnOnce) ---

// warnings logs an unreadable source once per row and content: the 30 s
// tick re-reads it, and a changed value warns again. The log names the
// source only, never a row id or content (FILES-01).
type warnings struct {
	mu   sync.Mutex
	seen map[string]string // key → the event the row belongs to
}

func newWarnings() *warnings { return &warnings{seen: map[string]string{}} }

func warnKey(what, id, content string) string {
	sum := sha256.Sum256([]byte(content))
	return what + "\x00" + id + "\x00" + hex.EncodeToString(sum[:8])
}

func (w *warnings) warn(what, id, event, content string) {
	k := warnKey(what, id, content)
	w.mu.Lock()
	_, dup := w.seen[k]
	w.seen[k] = event
	w.mu.Unlock()
	if !dup {
		log.Printf("hub slices: an unreadable %s was left out", what)
	}
}

// forget keeps only the warnings of events still in the window.
func (w *warnings) forget(events []string) {
	keep := make(map[string]bool, len(events))
	for _, e := range events {
		keep[e] = true
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for k, e := range w.seen {
		if !keep[e] {
			delete(w.seen, k)
		}
	}
}

func (w *warnings) has(what, id, content string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	_, ok := w.seen[warnKey(what, id, content)]
	return ok
}

func (w *warnings) count(event string) int {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := 0
	for _, e := range w.seen {
		if e == event {
			n++
		}
	}
	return n
}
