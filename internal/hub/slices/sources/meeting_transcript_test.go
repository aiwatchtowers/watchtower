package sources

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
)

type trRig struct {
	d   *db.DB
	src hubslices.Source
	ts  *transcriptSource
	dir string
	now time.Time
}

func newTrRig(t *testing.T, st *state.Store) *trRig {
	t.Helper()
	r := &trRig{d: openDB(t), dir: filepath.Join(t.TempDir(), "assets"), now: calNow}
	exec(t, r.d, `INSERT INTO calendar_calendars (id, name) VALUES ('cal', 'Work')`)
	src, err := MeetingTranscript(r.d, TranscriptOptions{
		CalendarOptions: CalendarOptions{Now: func() time.Time { return r.now }, Location: time.UTC}, AssetDir: r.dir, Store: st,
	})
	if err != nil {
		t.Fatal(err)
	}
	r.src, r.ts = src, src.(*transcriptSource)
	return r
}

type trSeed struct {
	title, event, segments, text, summary, chapters string
	created, updated                                time.Time
	private                                         bool
	duration                                        int
}

func (r *trRig) transcript(t *testing.T, s trSeed) int64 {
	t.Helper()
	if s.title == "" {
		s.title = "Weekly sync"
	}
	if s.created.IsZero() {
		s.created = calNow.Add(-24 * time.Hour)
	}
	if s.updated.IsZero() {
		s.updated = s.created
	}
	var ev, seg, sum, ch any
	if s.event != "" {
		ev = s.event
	}
	if s.segments != "" {
		seg = s.segments
	}
	if s.summary != "" {
		sum = s.summary
	}
	if s.chapters != "" {
		ch = s.chapters
	}
	return execID(t, r.d, `INSERT INTO meeting_transcripts (event_id, title, transcript_text, segments_json, summary_json, chapters_json,
		duration_sec, created_at, updated_at, private, notes_md, speakers_json, audio_path)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'private notes', '[[0.1]]', '/audio/x.m4a')`,
		ev, s.title, s.text, seg, sum, ch, s.duration, isoStamp(s.created), isoStamp(s.updated), s.private)
}

func (r *trRig) items(t *testing.T) []hubslices.Item {
	t.Helper()
	items, err := r.src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return items
}

func (r *trRig) one(t *testing.T, id int64) (map[string]any, string) {
	t.Helper()
	for _, it := range r.items(t) {
		if it.ID == fmt.Sprint(id) {
			return decode(t, it.Payload), r.asset(t, it)
		}
	}
	t.Fatalf("transcript %d not published", id)
	return nil, ""
}

// asset opens an item's sealed asset.
func (r *trRig) asset(t *testing.T, it hubslices.Item) string {
	t.Helper()
	sealed, err := os.ReadFile(it.AssetPath)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := secure.DecryptAsset(sealed, *it.Asset)
	if err != nil {
		t.Fatal(err)
	}
	return string(plain)
}

const recapJSON = `{"summary":"S","key_decisions":["d1"],"action_items":["a1","a2"],"open_questions":[]}`

func TestTranscriptPayloadAndAsset(t *testing.T) {
	r := newTrRig(t, nil)
	id := r.transcript(t, trSeed{event: "", duration: 90, segments: `[
		{"idx":0,"start_sec":0,"end_sec":1.5,"speaker":"Ann","text":"hi / there"},
		{"idx":1,"start_sec":1.5,"end_sec":3,"speaker":"Bob","text":"gone","deleted":true},
		{"idx":2,"start_sec":3,"end_sec":4,"speaker":"","text":"anon"},
		{"idx":3,"start_sec":4,"end_sec":5,"speaker":"Ann","text":"again"}]`,
		summary: recapJSON, chapters: `{"overall_summary":"Overview text","chapters":[{"title":"c"}]}`})
	p, asset := r.one(t, id)
	if p["title"] != "Weekly sync" || num(p["duration_sec"]) != 90 || p["summary"] != "S" || p["overview"] != "Overview text" {
		t.Errorf("payload = %v", p)
	}
	if fmt.Sprint(p["speakers"]) != "[Ann]" || fmt.Sprint(p["key_decisions"]) != "[d1]" || len(p["open_questions"].([]any)) != 0 {
		t.Errorf("lists = %v %v", p["speakers"], p["key_decisions"])
	}
	for _, k := range []string{"event_id", "phone_recording_id", "segments_clipped", "title_clipped", "speakers_more"} {
		if _, ok := p[k]; ok {
			t.Errorf("unexpected key %s", k)
		}
	}
	want := `[{"end_sec":1.5,"speaker":"Ann","start_sec":0,"text":"hi \/ there"},{"end_sec":4,"speaker":"","start_sec":3,"text":"anon"},{"end_sec":5,"speaker":"Ann","start_sec":4,"text":"again"}]`
	if asset != want {
		t.Errorf("asset = %s", asset)
	}
	// Hidden columns are never published.
	for _, leak := range []string{"private notes", "0.1", "x.m4a", "audio"} {
		if strings.Contains(fmt.Sprint(p), leak) {
			t.Errorf("%q leaked", leak)
		}
	}
}

func TestTranscriptRecapPrecedence(t *testing.T) {
	r := newTrRig(t, nil)
	exec(t, r.d, `INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES ('ev', 'cal', 'M', ?, ?)`,
		isoStamp(calNow), isoStamp(calNow.Add(time.Hour)))
	id := r.transcript(t, trSeed{event: "ev", summary: `{"summary":"own summary","key_decisions":[],"action_items":[],"open_questions":[]}`})
	exec(t, r.d, `INSERT INTO meeting_recaps (event_id, source_text, recap_json) VALUES ('ev', '', ?)`, strings.Replace(recapJSON, `"S"`, `"event recap"`, 1))
	if p, _ := r.one(t, id); p["summary"] != "event recap" || p["event_id"] != "ev" {
		t.Errorf("event recap must beat summary_json: %v", p["summary"])
	}
	// The transcript's own link wins over the event's.
	exec(t, r.d, `INSERT INTO meeting_recaps (transcript_id, source_text, recap_json) VALUES (?, '', ?)`, id, strings.Replace(recapJSON, `"S"`, `"linked recap"`, 1))
	if p, _ := r.one(t, id); p["summary"] != "linked recap" {
		t.Errorf("transcript link must win: %v", p["summary"])
	}
	// An unreadable own recap falls back to the event's.
	exec(t, r.d, `UPDATE meeting_recaps SET recap_json = '{"summary":1}', updated_at = '2026-10-14T09:00:00Z' WHERE transcript_id = ?`, id)
	if p, _ := r.one(t, id); p["summary"] != "event recap" {
		t.Errorf("unreadable own recap must fall back: %v", p["summary"])
	}
	// Nothing readable falls back to summary_json.
	exec(t, r.d, `UPDATE meeting_recaps SET recap_json = 'bad', updated_at = '2026-10-14T10:00:00Z'`)
	if p, _ := r.one(t, id); p["summary"] != "own summary" {
		t.Errorf("summary_json fallback: %v", p["summary"])
	}
	exec(t, r.d, `UPDATE meeting_transcripts SET summary_json = NULL`)
	if p, _ := r.one(t, id); p["summary"] != nil {
		t.Errorf("no recap must omit summary: %v", p["summary"])
	}
}

func TestTranscriptRecapListsAreCapped(t *testing.T) {
	r := newTrRig(t, nil)
	var acts []string
	for i := 0; i < 51; i++ {
		acts = append(acts, fmt.Sprintf("%q", strings.Repeat("a", 501)))
	}
	id := r.transcript(t, trSeed{summary: `{"summary":"S","key_decisions":[],"open_questions":[],"action_items":[` + strings.Join(acts, ",") + `]}`})
	p, _ := r.one(t, id)
	a := p["action_items"].([]any)
	if len(a) != 50 || num(p["action_items_more"]) != 1 || runes(a[0]) != 500 {
		t.Errorf("action items = %d more %v", len(a), p["action_items_more"])
	}
}

func TestTranscriptTitleSpeakersAndOverviewAreCapped(t *testing.T) {
	r := newTrRig(t, nil)
	var segs []string
	for i := 0; i < 21; i++ {
		segs = append(segs, fmt.Sprintf(`{"idx":%d,"start_sec":%d,"end_sec":%d,"speaker":"S%d","text":"t"}`, i, i, i+1, i))
	}
	id := r.transcript(t, trSeed{title: strings.Repeat("T", 301), segments: "[" + strings.Join(segs, ",") + "]",
		chapters: `{"overall_summary":"` + strings.Repeat("o", 2001) + `"}`})
	p, _ := r.one(t, id)
	if runes(p["title"]) != 300 || p["title_clipped"] != true || len(p["speakers"].([]any)) != 20 || num(p["speakers_more"]) != 1 ||
		runes(p["overview"]) != 2000 || p["overview_clipped"] != true {
		t.Errorf("caps wrong: %v", p)
	}
}

func TestTranscriptLegacyAndUnreadableSegments(t *testing.T) {
	r := newTrRig(t, nil)
	legacy := r.transcript(t, trSeed{text: "flat text", duration: 42})
	bad := r.transcript(t, trSeed{text: "fallback", segments: `not json`, duration: 7})
	wrongShape := r.transcript(t, trSeed{text: "ignored", segments: `{"a":1}`})
	allDeleted := r.transcript(t, trSeed{segments: `[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"A","text":"x","deleted":true}]`})
	items := map[string]string{}
	for _, it := range r.items(t) {
		items[it.ID] = r.asset(t, it)
	}
	if items[fmt.Sprint(legacy)] != `[{"end_sec":42,"speaker":"","start_sec":0,"text":"flat text"}]` {
		t.Errorf("legacy = %s", items[fmt.Sprint(legacy)])
	}
	if items[fmt.Sprint(bad)] != `[{"end_sec":7,"speaker":"","start_sec":0,"text":"fallback"}]` {
		t.Errorf("unreadable = %s", items[fmt.Sprint(bad)])
	}
	if items[fmt.Sprint(wrongShape)] != `[]` || items[fmt.Sprint(allDeleted)] != `[]` {
		t.Errorf("wrong shape %s, all deleted %s", items[fmt.Sprint(wrongShape)], items[fmt.Sprint(allDeleted)])
	}
}

func TestTranscriptAssetCapBoundary(t *testing.T) {
	segs := []segment{{0, 1, "A", "aaaa"}, {1, 2, "B", "bbbb"}}
	whole, clipped := encodeSegments(segs, 1<<20)
	if clipped != nil {
		t.Fatal("clipped without a cap")
	}
	if data, clipped := encodeSegments(segs, len(whole)); clipped != nil || string(data) != string(whole) {
		t.Error("an array exactly at the cap must not clip")
	}
	data, clipped := encodeSegments(segs, len(whole)-1)
	if clipped == nil || !*clipped {
		t.Fatal("one byte over must clip")
	}
	var back []segment
	if err := json.Unmarshal(data, &back); err != nil || len(back) != 1 {
		t.Errorf("clip must end after the last whole segment: %s %v", data, err)
	}
	if data, clipped := encodeSegments(segs, 1); string(data) != "[]" || clipped == nil {
		t.Errorf("tiny cap: %s", data)
	}
}

func TestTranscriptAssetOverCapSetsSegmentsClipped(t *testing.T) {
	r := newTrRig(t, nil)
	r.ts.maxAsset = 120
	id := r.transcript(t, trSeed{segments: `[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"A","text":"short"},
		{"idx":1,"start_sec":1,"end_sec":2,"speaker":"A","text":"` + strings.Repeat("w", 200) + `"}]`})
	p, asset := r.one(t, id)
	if p["segments_clipped"] != true || !strings.HasPrefix(asset, `[{"end_sec":1`) || strings.Contains(asset, "www") {
		t.Errorf("clipped = %v asset %s", p["segments_clipped"], asset)
	}
}

func TestTranscriptWindow(t *testing.T) {
	r := newTrRig(t, nil)
	old := calNow.Add(-40 * 24 * time.Hour)
	oldPlain := r.transcript(t, trSeed{created: old})
	exec(t, r.d, `INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES ('ev', 'cal', 'M', ?, ?)`,
		isoStamp(calNow), isoStamp(calNow.Add(time.Hour)))
	oldInWindow := r.transcript(t, trSeed{created: old, event: "ev"})
	fresh := r.transcript(t, trSeed{created: calNow.Add(-29 * 24 * time.Hour)})
	got := map[string]bool{}
	var order []string
	for _, it := range r.items(t) {
		got[it.ID] = true
		order = append(order, it.ID)
	}
	if got[fmt.Sprint(oldPlain)] || !got[fmt.Sprint(oldInWindow)] || !got[fmt.Sprint(fresh)] {
		t.Errorf("window = %v", got)
	}
	if order[0] != fmt.Sprint(fresh) {
		t.Errorf("newest first expected, got %v", order)
	}
}

func TestTranscriptWindowKeepsTheNewest200(t *testing.T) {
	r := newTrRig(t, nil)
	for i := 0; i < 201; i++ {
		r.transcript(t, trSeed{created: calNow.Add(-time.Duration(i+1) * time.Minute), text: "x"})
	}
	if n := len(r.items(t)); n != 200 {
		t.Errorf("published %d", n)
	}
}

func TestTranscriptUnchangedCycleBuildsAndReadsNothing(t *testing.T) {
	r := newTrRig(t, nil)
	id := r.transcript(t, trSeed{text: "hello", created: calNow.Add(-time.Hour)})
	first := r.items(t)
	if r.ts.builds.Load() != 1 || r.ts.fullReads.Load() != 1 {
		t.Fatalf("builds %d full reads %d", r.ts.builds.Load(), r.ts.fullReads.Load())
	}
	// The first cycle's light key was stored (the row had settled); the second reads no big column.
	second := r.items(t)
	if r.ts.builds.Load() != 1 || r.ts.fullReads.Load() != 1 {
		t.Errorf("an unchanged cycle read/built again: builds %d full reads %d", r.ts.builds.Load(), r.ts.fullReads.Load())
	}
	if string(first[0].Payload) != string(second[0].Payload) || first[0].AssetPath != second[0].AssetPath || first[0].Asset.PlaintextDigest != second[0].Asset.PlaintextDigest {
		t.Error("an unchanged transcript must publish the same record")
	}
	// A change republishes (and the old staged file goes at the next cycle).
	exec(t, r.d, `UPDATE meeting_transcripts SET title = 'Renamed', updated_at = ? WHERE id = ?`, isoStamp(calNow.Add(-30*time.Minute)), id)
	third := r.items(t)
	if r.ts.builds.Load() != 2 || !strings.Contains(string(third[0].Payload), "Renamed") {
		t.Errorf("a rename must rebuild: %d", r.ts.builds.Load())
	}
	r.items(t)
	if fileExists(first[0].AssetPath) && first[0].AssetPath != third[0].AssetPath {
		t.Error("a superseded staged file must be removed")
	}
	// A missing staged file is rebuilt.
	if err := os.Remove(third[0].AssetPath); err != nil {
		t.Fatal(err)
	}
	r.items(t)
	if r.ts.builds.Load() != 3 {
		t.Errorf("a lost staged file must rebuild: %d", r.ts.builds.Load())
	}
}

func TestTranscriptRowStillSettlingIsReadInFullAgain(t *testing.T) {
	r := newTrRig(t, nil)
	r.transcript(t, trSeed{text: "x", created: calNow, updated: calNow})
	r.items(t)
	r.items(t)
	if r.ts.fullReads.Load() != 2 {
		t.Errorf("a row updated within the settle time must be read in full each cycle: %d", r.ts.fullReads.Load())
	}
}

func TestTranscriptSpeakerRenameRepublishes(t *testing.T) {
	r := newTrRig(t, nil)
	id := r.transcript(t, trSeed{segments: `[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Speaker 1","text":"x"}]`})
	p, _ := r.one(t, id)
	exec(t, r.d, `UPDATE meeting_transcripts SET segments_json = replace(segments_json, 'Speaker 1', 'Ann'), updated_at = ? WHERE id = ?`,
		isoStamp(calNow.Add(-time.Minute)), id)
	p2, _ := r.one(t, id)
	if fmt.Sprint(p["speakers"]) != "[Speaker 1]" || fmt.Sprint(p2["speakers"]) != "[Ann]" {
		t.Errorf("speakers %v → %v", p["speakers"], p2["speakers"])
	}
}

func TestTranscriptPhoneRecordingIDFromTheQueue(t *testing.T) {
	st := openSidecar(t)
	r := newTrRig(t, st)
	id := r.transcript(t, trSeed{text: "x"})
	other := r.transcript(t, trSeed{text: "y"})
	if err := st.QueueRecording("up-1", "AAAAAAAA-0000-4000-8000-000000000001", calNow); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ClaimRecording("up-1", calNow); err != nil {
		t.Fatal(err)
	}
	if _, err := st.FinishRecording("up-1", &id, "", calNow); err != nil {
		t.Fatal(err)
	}
	if p, _ := r.one(t, id); p["phone_recording_id"] != "up-1" {
		t.Errorf("phone id = %v", p["phone_recording_id"])
	}
	if p, _ := r.one(t, other); p["phone_recording_id"] != nil {
		t.Errorf("a Mac recording has no phone id: %v", p["phone_recording_id"])
	}
}

// MEETPRIV-01..05: a private recording and the recap it owns are never published.
func TestTranscriptPrivateRecordingAndItsRecapAreNeverPublished(t *testing.T) {
	r := newTrRig(t, nil)
	exec(t, r.d, `INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES ('ev', 'cal', 'M', ?, ?)`,
		isoStamp(calNow), isoStamp(calNow.Add(time.Hour)))
	priv := r.transcript(t, trSeed{event: "ev", private: true, text: "secret words", summary: recapJSON})
	pub := r.transcript(t, trSeed{event: "ev", text: "public words"})
	// A recap owned by the private recording is attached to the event too: the
	// public sibling must not borrow it.
	exec(t, r.d, `INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json) VALUES ('ev', ?, '', ?)`, priv, recapJSON)
	items := r.items(t)
	if len(items) != 1 || items[0].ID != fmt.Sprint(pub) {
		t.Fatalf("published %d items, want only the public one", len(items))
	}
	if p := decode(t, items[0].Payload); p["summary"] != nil {
		t.Errorf("the public sibling borrowed the private recording's recap: %v", p["summary"])
	}
	if strings.Contains(r.asset(t, items[0]), "secret") {
		t.Error("private text in a public asset")
	}
	// Making a published recording private removes its record.
	exec(t, r.d, `UPDATE meeting_transcripts SET private = 1 WHERE id = ?`, pub)
	if n := len(r.items(t)); n != 0 {
		t.Errorf("%d items after the flip", n)
	}
}

func TestTranscriptSourceNeedsItsInputs(t *testing.T) {
	if _, err := MeetingTranscript(nil, TranscriptOptions{AssetDir: t.TempDir()}); err == nil {
		t.Error("no database must be refused")
	}
	if _, err := MeetingTranscript(openDB(t), TranscriptOptions{}); err == nil {
		t.Error("no asset directory must be refused")
	}
}
