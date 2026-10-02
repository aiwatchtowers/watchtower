package customtracks

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// scanTS returns an ISO8601 second-resolution timestamp n minutes after base.
func scanTS(base time.Time, n int) string {
	return base.Add(time.Duration(n) * time.Minute).Format("2006-01-02T15:04:05Z")
}

// newScanFixture opens a DB with one custom track whose watermark sits two
// hours in the past, and returns the track id plus the watermark time; seeded
// activity is placed after it relative to time.Now().
func newScanFixture(t *testing.T) (*db.DB, int, time.Time) {
	t.Helper()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	id := newCustomTrack(t, d, "watch the refund")
	base := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Second)
	if err := d.SetTrackLastRun(id, scanTS(base, 0)); err != nil {
		t.Fatalf("set watermark: %v", err)
	}
	return d, id, base
}

func seedInboxAt(t *testing.T, d *db.DB, snippet, createdAt string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('C1', ?, 'U2', 'mention', ?, ?)`, snippet, snippet, createdAt)
	if err != nil {
		t.Fatalf("seed inbox: %v", err)
	}
	id, _ := res.LastInsertId()
	return int(id)
}

func watermark(t *testing.T, d *db.DB, id int) string {
	t.Helper()
	tr, err := d.GetTrackByID(id)
	if err != nil {
		t.Fatalf("load track: %v", err)
	}
	return tr.LastRunAt
}

func eventSummaries(t *testing.T, d *db.DB, id int) []string {
	t.Helper()
	evs, err := d.GetTrackEvents(id, 100)
	if err != nil {
		t.Fatalf("load events: %v", err)
	}
	var out []string
	for _, e := range evs {
		out = append(out, e.Summary)
	}
	return out
}

// TestRunOneCapHitAdvancesWatermarkToCappedAt pins the cap path: a window with
// more rows than the per-source cap advances the watermark to the last loaded
// row, not to now, and the next run picks up exactly the overflow. Swapping the
// watermark back to now silently loses the overflow.
func TestRunOneCapHitAdvancesWatermarkToCappedAt(t *testing.T) {
	d, id, base := newScanFixture(t)
	for i := 1; i <= defaultActivityLimit; i++ {
		seedInboxAt(t, d, fmt.Sprintf("row-%02d", i), scanTS(base, i))
	}
	seedInboxAt(t, d, "overflow-row", scanTS(base, defaultActivityLimit+1))

	mock := &mockGenerator{out: `{"events":[]}`}
	p := New(d, mock, "", nil)
	if _, err := p.RunForTrack(context.Background(), id); err != nil {
		t.Fatalf("first run: %v", err)
	}
	if strings.Contains(mock.lastUser, "overflow-row") {
		t.Fatal("first run fed the row past the cap")
	}
	if got, want := watermark(t, d, id), scanTS(base, defaultActivityLimit); got != want {
		t.Fatalf("watermark after cap hit = %q; want the last loaded row %q", got, want)
	}

	if _, err := p.RunForTrack(context.Background(), id); err != nil {
		t.Fatalf("second run: %v", err)
	}
	if !strings.Contains(mock.lastUser, "overflow-row") || strings.Contains(mock.lastUser, "row-01") {
		t.Fatalf("second run did not feed exactly the overflow:\n%s", mock.lastUser)
	}
	if got := watermark(t, d, id); got <= scanTS(base, defaultActivityLimit+1) {
		t.Fatalf("watermark after uncapped run = %q; want now", got)
	}
}

// TestRunOneParseFailureKeepsWatermark pins that an unparseable reply leaves
// the window to be re-read: no events, watermark unchanged, error returned.
func TestRunOneParseFailureKeepsWatermark(t *testing.T) {
	d, id, base := newScanFixture(t)
	seedInboxAt(t, d, "activity", scanTS(base, 1))
	before := watermark(t, d, id)

	p := New(d, &mockGenerator{out: "not json"}, "", nil)
	if _, err := p.RunForTrack(context.Background(), id); err == nil {
		t.Fatal("RunForTrack succeeded on an unparseable reply")
	}
	if got := watermark(t, d, id); got != before {
		t.Fatalf("watermark moved to %q on parse failure; want %q", got, before)
	}
	if got := eventSummaries(t, d, id); len(got) != 0 {
		t.Fatalf("events created on parse failure: %v", got)
	}
}

// TestRunOneInsertFailureFreezesWatermark pins the insert-failure freeze: one
// event failing to persist keeps the watermark, so the next run re-reads the
// window; the events that did persist are not duplicated on that retry.
func TestRunOneInsertFailureFreezesWatermark(t *testing.T) {
	d, id, base := newScanFixture(t)
	seedInboxAt(t, d, "activity", scanTS(base, 1))
	if _, err := d.Exec(`CREATE TRIGGER fail_boom BEFORE INSERT ON track_events
		WHEN NEW.summary = 'boom' BEGIN SELECT RAISE(ABORT, 'boom refused'); END`); err != nil {
		t.Fatalf("create trigger: %v", err)
	}
	before := watermark(t, d, id)

	mock := &mockGenerator{out: `{"events":[{"summary":"kept"},{"summary":"boom"}]}`}
	p := New(d, mock, "", nil)
	if _, err := p.RunForTrack(context.Background(), id); err == nil {
		t.Fatal("RunForTrack succeeded although an insert failed")
	}
	if got := watermark(t, d, id); got != before {
		t.Fatalf("watermark moved to %q after an insert failure; want %q", got, before)
	}

	// The retry re-reads the window; "kept" is deduped, "boom" now persists.
	if _, err := d.Exec(`DROP TRIGGER fail_boom`); err != nil {
		t.Fatalf("drop trigger: %v", err)
	}
	if _, err := p.RunForTrack(context.Background(), id); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if !strings.Contains(mock.lastUser, "activity") {
		t.Fatalf("retry did not re-read the frozen window:\n%s", mock.lastUser)
	}
	got := eventSummaries(t, d, id)
	if len(got) != 2 {
		t.Fatalf("events after retry = %v; want kept + boom once each", got)
	}
	if watermark(t, d, id) == before {
		t.Fatal("watermark not advanced after a clean retry")
	}
}

// TestRunOneDedupsExactSummaries pins summary dedup: an event whose trimmed
// summary already exists on the track, or repeats within one reply, is not
// re-created; an empty summary is dropped.
func TestRunOneDedupsExactSummaries(t *testing.T) {
	d, id, base := newScanFixture(t)
	seedInboxAt(t, d, "activity", scanTS(base, 1))
	if _, err := d.InsertTrackEvent(db.TrackEvent{TrackID: id, Summary: "refund approved", SourceRefs: "[]", ActionStatus: "none"}); err != nil {
		t.Fatalf("seed event: %v", err)
	}

	mock := &mockGenerator{out: `{"events":[
		{"summary":"  refund approved "},
		{"summary":"refund paid"},
		{"summary":"refund paid"},
		{"summary":"   "}
	]}`}
	created, err := New(d, mock, "", nil).RunForTrack(context.Background(), id)
	if err != nil {
		t.Fatalf("RunForTrack: %v", err)
	}
	if len(created) != 1 || created[0].Summary != "refund paid" {
		t.Fatalf("created = %+v; want only one \"refund paid\"", created)
	}
	if got := eventSummaries(t, d, id); len(got) != 2 {
		t.Fatalf("stored events = %v; want 2", got)
	}
}

// routingGenerator answers stage-1 (title) prompts with shortlist and stage-2
// prompts with an empty event list, recording each prompt by stage.
type routingGenerator struct {
	shortlist  string
	shortCalls []string
	extract    []string
}

func (g *routingGenerator) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	if strings.Contains(user, "ACTIVITY TITLES:") {
		g.shortCalls = append(g.shortCalls, user)
		return g.shortlist, &digest.Usage{}, "", nil
	}
	g.extract = append(g.extract, user)
	return `{"events":[]}`, &digest.Usage{}, "", nil
}

// TestBackfillRoutesShortlistedIDsByKind pins the two-stage backfill: stage 2
// loads exactly the shortlisted items from their own source, an unknown kind or
// a custom track id loads nothing, and the backfill advances the watermark.
func TestBackfillRoutesShortlistedIDsByKind(t *testing.T) {
	d, id, base := newScanFixture(t)
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, created_at)
		VALUES ('C1', 1, 2, 'channel', 'digest-picked', ?)`, scanTS(base, 1))
	if err != nil {
		t.Fatalf("seed digest: %v", err)
	}
	dg, _ := res.LastInsertId()
	res, err = d.Exec(`INSERT INTO tracks (text, updated_at) VALUES ('track-picked', ?)`, scanTS(base, 1))
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}
	tr, _ := res.LastInsertId()
	in := seedInboxAt(t, d, "inbox-picked", scanTS(base, 2))
	seedInboxAt(t, d, "inbox-not-picked", scanTS(base, 3))

	g := &routingGenerator{shortlist: fmt.Sprintf(`{"refs":[
		{"kind":"digest","id":%d},{"kind":"track","id":%d},{"kind":"inbox","id":%d},
		{"kind":"track","id":%d},{"kind":"bogus","id":1}]}`, dg, tr, in, id)}
	since := time.Now().UTC().Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z")
	if _, err := New(d, g, "", nil).RunForTrackSince(context.Background(), id, since); err != nil {
		t.Fatalf("RunForTrackSince: %v", err)
	}
	if len(g.shortCalls) != 1 || len(g.extract) != 1 {
		t.Fatalf("calls = %d shortlist / %d extract; want 1/1", len(g.shortCalls), len(g.extract))
	}
	ex := g.extract[0]
	for _, want := range []string{"digest-picked", "track-picked", "inbox-picked"} {
		if !strings.Contains(ex, want) {
			t.Errorf("extract prompt missing %q:\n%s", want, ex)
		}
	}
	if strings.Contains(ex, "inbox-not-picked") || strings.Contains(ex, fmt.Sprintf("[track id=%d]", id)) {
		t.Errorf("extract prompt carries an unselected item or the custom track itself:\n%s", ex)
	}
	if got := watermark(t, d, id); got <= scanTS(base, 3) {
		t.Errorf("watermark after backfill = %q; want now", got)
	}
}

// TestBackfillShortlistChunksAndCandidateCap pins stage-1 chunking: titles
// past one chunk go out in a second shortlist call, and once maxCandidates are
// selected no further chunk is sent and stage 2 gets at most maxCandidates.
func TestBackfillShortlistChunksAndCandidateCap(t *testing.T) {
	seed := func(t *testing.T) (*db.DB, int, []int) {
		d, id, base := newScanFixture(t)
		var ids []int
		for i := 0; i < shortlistChunk+1; i++ {
			// Distinct seconds keep the newest-first title order deterministic.
			ts := base.Add(time.Duration(i) * time.Second).Format("2006-01-02T15:04:05Z")
			ids = append(ids, seedInboxAt(t, d, fmt.Sprintf("item-%04d", i), ts))
		}
		return d, id, ids
	}
	since := time.Now().UTC().Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z")

	t.Run("few selected: every chunk is shortlisted", func(t *testing.T) {
		d, id, ids := seed(t)
		g := &routingGenerator{shortlist: fmt.Sprintf(`{"refs":[{"kind":"inbox","id":%d}]}`, ids[0])}
		if _, err := New(d, g, "", nil).RunForTrackSince(context.Background(), id, since); err != nil {
			t.Fatalf("RunForTrackSince: %v", err)
		}
		if len(g.shortCalls) != 2 {
			t.Fatalf("shortlist calls = %d; want 2 for %d titles", len(g.shortCalls), shortlistChunk+1)
		}
		if len(g.extract) != 1 || strings.Count(g.extract[0], "[inbox id=") != 1 {
			t.Fatalf("extract = %v; want one call with the one selected item", g.extract)
		}
	})

	t.Run("cap reached: later chunks are skipped", func(t *testing.T) {
		d, id, ids := seed(t)
		var refs []string
		for _, x := range ids[:maxCandidates+10] {
			refs = append(refs, fmt.Sprintf(`{"kind":"inbox","id":%d}`, x))
		}
		g := &routingGenerator{shortlist: `{"refs":[` + strings.Join(refs, ",") + `]}`}
		if _, err := New(d, g, "", nil).RunForTrackSince(context.Background(), id, since); err != nil {
			t.Fatalf("RunForTrackSince: %v", err)
		}
		if len(g.shortCalls) != 1 {
			t.Fatalf("shortlist calls = %d; want 1 once the candidate cap is reached", len(g.shortCalls))
		}
		if len(g.extract) != 1 {
			t.Fatalf("extract calls = %d; want 1", len(g.extract))
		}
		if n := strings.Count(g.extract[0], "[inbox id="); n != maxCandidates {
			t.Fatalf("extract fed %d items; want maxCandidates=%d", n, maxCandidates)
		}
	})
}

// TestBackfillNothingSelectedSkipsExtract pins that an empty shortlist makes no
// stage-2 call and still advances the watermark.
func TestBackfillNothingSelectedSkipsExtract(t *testing.T) {
	d, id, base := newScanFixture(t)
	seedInboxAt(t, d, "irrelevant", scanTS(base, 1))
	g := &routingGenerator{shortlist: `{"refs":[]}`}
	since := time.Now().UTC().Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z")
	if _, err := New(d, g, "", nil).RunForTrackSince(context.Background(), id, since); err != nil {
		t.Fatalf("RunForTrackSince: %v", err)
	}
	if len(g.shortCalls) != 1 || len(g.extract) != 0 {
		t.Fatalf("calls = %d shortlist / %d extract; want 1/0", len(g.shortCalls), len(g.extract))
	}
	if got := watermark(t, d, id); got <= scanTS(base, 1) {
		t.Fatalf("watermark = %q; want advanced to now", got)
	}
}
