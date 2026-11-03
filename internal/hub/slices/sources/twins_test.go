package sources

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/hub/state"
	"watchtower/internal/logcanary"
	"watchtower/internal/sessionreport"
)

// Go twins of Swift slice tests that had none (Task 24): SliceClipTests,
// CalendarEventSliceTests, RecordingJobSliceTests, OwnerAskSliceTests,
// MeetingTranscriptSliceTests.

// graphemes splits s into its grapheme clusters.
func graphemes(s string) []string {
	var out []string
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		out = append(out, g.Str())
	}
	return out
}

// twin of SliceClipTests.testReviewFocus4ClipsAtAGraphemeBoundary: RTL text,
// a ZWJ family emoji and combining accents, each n graphemes long, at a cap
// of n (kept) and n − 1, n − 2 (clipped). A clip never breaks a grapheme:
// the kept part is a whole-cluster prefix of the original, and the ellipsis
// counts toward the cap.
func TestClipTextReviewFocus4ClipsAtAGraphemeBoundary(t *testing.T) {
	family := "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466"
	accent := "é"
	samples := []struct{ name, text string }{
		{"rtl", "שלום עולם مرحبا"},
		{"zwj", strings.Repeat(family, 6)},
		{"combining", strings.Repeat(accent, 6) + "ạ̈"},
		{"mixed", "a" + family + accent + "ש" + family},
	}
	for _, s := range samples {
		clusters := graphemes(s.text)
		n := len(clusters)
		if text, clipped := clipText(s.text, n); text != s.text || clipped != nil {
			t.Errorf("%s: n graphemes at a cap of n = %q %v", s.name, text, clipped)
		}
		for _, limit := range []int{n - 1, n - 2} {
			text, clipped := clipText(s.text, limit)
			got := graphemes(text)
			if clipped == nil || !*clipped {
				t.Errorf("%s at %d: not flagged", s.name, limit)
			}
			if len(got) != limit || got[len(got)-1] != ellipsis {
				t.Errorf("%s at %d: %q, %d graphemes: the ellipsis counts toward the cap", s.name, limit, text, len(got))
				continue
			}
			kept := strings.TrimSuffix(text, ellipsis)
			if !slices.Equal(graphemes(kept), clusters[:limit-1]) || !strings.HasPrefix(s.text, kept) {
				t.Errorf("%s at %d: kept %q is not a whole-grapheme prefix", s.name, limit, kept)
			}
		}
	}
}

// twin of SliceClipTests.testListWithinTheCapHasNoMore (and the over-the-cap
// case beside it).
func TestClipListWithinTheCapHasNoMore(t *testing.T) {
	items, more := clipList([]int{1, 2, 3}, 3)
	if !slices.Equal(items, []int{1, 2, 3}) || more != nil {
		t.Errorf("within the cap = %v, more %v: an uncapped list carries no _more", items, more)
	}
	var all []int
	for i := 1; i <= 25; i++ {
		all = append(all, i)
	}
	items, more = clipList(all, 20)
	if !slices.Equal(items, all[:20]) || more == nil || *more != 5 {
		t.Errorf("over the cap = %v, more %v", items, more)
	}
}

// twin of CalendarEventSliceTests.testUnreadableAttendeesWarnOncePerContent:
// a second tick does not warn again; changed content warns again.
func TestCalendarUnreadableAttendeesWarnOncePerContent(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newCalRig(t, time.UTC)
	r.event(t, evSeed{id: "bad", attendees: `{"email":"a@example.com"}`})
	if p := r.byID(t)["bad"]; len(p["attendees"].([]any)) != 0 {
		t.Fatalf("unreadable attendees published: %v", p["attendees"])
	}
	r.byID(t)
	warned := func() int { return strings.Count(sink.String(), "an unreadable attendees was left out") }
	if !r.cs.warns.has("attendees", "bad", `{"email":"a@example.com"}`) || r.cs.warns.count("bad") != 1 || warned() != 1 {
		t.Fatalf("warned %d times, count %d: a second tick must not warn again", warned(), r.cs.warns.count("bad"))
	}
	exec(t, r.d, `UPDATE calendar_events SET attendees = '[1]' WHERE id = 'bad'`)
	r.byID(t)
	if r.cs.warns.count("bad") != 2 || warned() != 2 {
		t.Fatalf("warned %d times, count %d: changed content warns again", warned(), r.cs.warns.count("bad"))
	}
}

// westOfUTC is a fixed UTC−7 zone (the Swift tests' secondsFromGMT −7 h).
var westOfUTC = time.FixedZone("west", -7*3600)

func calSourceAt(t *testing.T, now time.Time, loc *time.Location) *calRig {
	t.Helper()
	r := newCalRig(t, loc)
	src := CalendarEvent(r.d, CalendarOptions{Now: func() time.Time { return now }, Location: loc})
	r.src, r.cs = src, src.(*calendarSource)
	return r
}

// twin of CalendarEventSliceTests.testAnAllDayEventKeepsItsDayWestOfUTC: an
// all-day day is stored as UTC midnight; on a UTC−7 Mac that instant is the
// evening before. The event keeps its day: it is published with the stored
// date when its day is the window's last, and left out when its day is just
// past it, though the raw instant falls inside.
func TestCalendarAllDayOnTheWindowsLastDayWestOfUTC(t *testing.T) {
	// Local 20:00, so the window ends at 20:00 on its last day — after 17:00,
	// where the next day's UTC midnight sits.
	evening := time.Date(2026, 10, 14, 20, 0, 0, 0, westOfUTC)
	end := calendarWindow(evening, westOfUTC).end
	stored := func(d time.Time) time.Time {
		y, m, dd := d.In(westOfUTC).Date()
		return time.Date(y, m, dd, 0, 0, 0, 0, time.UTC)
	}
	lastDay, nextDay := stored(end), stored(end.AddDate(0, 0, 1))
	r := calSourceAt(t, evening, westOfUTC)
	r.event(t, evSeed{id: "last-day", allDay: true, start: lastDay, end: nextDay})
	r.event(t, evSeed{id: "next-day", allDay: true, start: nextDay, end: stored(end.AddDate(0, 0, 2))})
	if !nextDay.Before(end) {
		t.Fatalf("the trap is gone: next day %v is not inside the window end %v", nextDay, end)
	}
	got := r.byID(t)
	if len(got) != 1 || got["last-day"] == nil {
		t.Fatalf("published %v, want only last-day", got)
	}
	if p := got["last-day"]; p["start_time"] != isoStamp(lastDay) || p["is_all_day"] != true {
		t.Errorf("start_time %v is_all_day %v: the stored day travels unchanged", p["start_time"], p["is_all_day"])
	}
}

// twin of CalendarEventSliceTests.testEventsAreOrderedByLocalStartThenID: local
// start first — an all-day event at its local midnight, not its stored UTC
// instant — then the id for equal starts, and a de-duplicated copy keeps its
// start.
func TestCalendarOrderUsesTheAllDayLocalMidnightWestOfUTC(t *testing.T) {
	noon := time.Date(2026, 10, 14, 12, 0, 0, 0, westOfUTC)
	today := time.Date(2026, 10, 14, 0, 0, 0, 0, westOfUTC)
	tomorrow := today.AddDate(0, 0, 1)
	r := calSourceAt(t, noon, westOfUTC)
	r.event(t, evSeed{id: "evt-c", start: tomorrow.Add(8 * time.Hour)})
	r.event(t, evSeed{id: "evt-e2", start: tomorrow.Add(9 * time.Hour)})
	r.event(t, evSeed{id: "evt-e1", start: tomorrow.Add(9 * time.Hour)})
	// Stored as tomorrow's UTC midnight: today 17:00 here, before evt-b.
	r.event(t, evSeed{id: "evt-z", allDay: true, start: time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC),
		end: time.Date(2026, 10, 16, 0, 0, 0, 0, time.UTC)})
	r.event(t, evSeed{id: "evt-b", start: today.Add(20 * time.Hour)})
	r.event(t, evSeed{id: "evt-a1", start: today.Add(14 * time.Hour), uid: "uid-1@example.com"})
	r.event(t, evSeed{id: "evt-a2", start: today.Add(14 * time.Hour), uid: "uid-1@example.com", conf: "https://meet.example.com/x"})
	want := "evt-a2,evt-b,evt-z,evt-c,evt-e1,evt-e2"
	if got := strings.Join(r.ids(t), ","); got != want {
		t.Errorf("order = %s, want %s", got, want)
	}
}

// claimedJob is a phone recording queued and claimed by the transcriber.
func claimedJob(t *testing.T) (*state.Store, time.Time) {
	t.Helper()
	st := openSidecar(t)
	t0 := time.Unix(1_800_000_000, 0)
	if err := st.QueueRecording("up-1", jobDevice, t0); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ClaimRecording("up-1", t0); err != nil {
		t.Fatal(err)
	}
	return st, t0
}

// twin of RecordingJobSliceTests.testFirstPhaseBeforeAnyWindowIsZeroPercent:
// a transcribing phase at 0 % publishes percent 0, not an absent percent.
func TestRecordingJobFirstPhaseBeforeAnyWindowIsZeroPercent(t *testing.T) {
	st, t0 := claimedJob(t)
	zero := 0
	if err := st.RecordingProgress("up-1", state.PhaseTranscribing, &zero); err != nil {
		t.Fatal(err)
	}
	p := jobPayloads(t, st, t0)["up-1"]
	if v, ok := p["percent"]; !ok || num(v) != 0 {
		t.Fatalf("payload %v: percent 0 must be published", p)
	}
}

// twin of RecordingJobSliceTests.testAPhaseAfterDoneIsIgnored: neither a phase
// nor a failure after done changes the job; it stays done.
func TestRecordingJobAPhaseAfterDoneIsIgnored(t *testing.T) {
	st, t0 := claimedJob(t)
	tid := int64(7)
	if _, err := st.FinishRecording("up-1", &tid, "", t0); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordingProgress("up-1", state.PhaseDiarizing, nil); !errors.Is(err, state.ErrJobState) {
		t.Errorf("a phase after done = %v, want ErrJobState", err)
	}
	if _, err := st.FinishRecording("up-1", nil, "late", t0); !errors.Is(err, state.ErrJobState) {
		t.Errorf("a failure after done = %v, want ErrJobState", err)
	}
	if p := jobPayloads(t, st, t0)["up-1"]; p["status"] != "done" || num(p["transcript_id"]) != 7 {
		t.Fatalf("payload %v, want done", p)
	}
}

// twin of OwnerAskSliceTests.testSpecReviewLinesCountsNotUseful: an owner's
// not_useful mark does not take a finding out of the line's counts.
func TestOwnerAskSpecReviewLineCountsNotUseful(t *testing.T) {
	d := openDB(t)
	id := seedAsk(t, d, askSpec{project: seedWorkbench(t, d, "acme"), kind: "review"})
	execID(t, d, `INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at)
		VALUES (?, 'done', '{"blind_spots":[{"key":"c"}]}', '2026-10-25T10:00:00Z', '2026-10-25T10:05:00Z')`, id)
	execID(t, d, `INSERT INTO spec_review_marks (ask_id, item_key, state, updated_at) VALUES (?, 'c', 'not_useful', '2026-10-25T10:06:00Z')`, id)
	r, _ := payloadsByKey(t, OwnerAsk(d, nil))[askID(id)]["spec_review"].(map[string]any)
	if r["line"] != "1 blind spot" {
		t.Fatalf("line %v, want 1 blind spot", r["line"])
	}
}

// twin of OwnerAskSliceTests.testTheAnchorFixturesClippedCaseIsTheEndOfASnapshotTheSliceCut
// (the slice's half): the shared fixture's doc_clipped case is what
// clipSnapshot keeps of an over-cap snapshot — cut right after the
// fixture's last shown line. The fixture's anchor over that text is
// handlers.TestAnchorFixtures.
func TestOwnerAskAnchorFixturesClippedCaseIsTheEndOfASnapshotTheSliceCut(t *testing.T) {
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			Markdown   string `json:"markdown"`
			DocClipped bool   `json:"doc_clipped"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	i := slices.IndexFunc(f.Cases, func(c struct {
		Markdown   string `json:"markdown"`
		DocClipped bool   `json:"doc_clipped"`
	}) bool {
		return c.DocClipped
	})
	if i < 0 {
		t.Fatal("no doc_clipped case in the fixture")
	}
	md := f.Cases[i].Markdown
	filler := "Filler paragraph for the acme snapshot.\n\n"
	shown := strings.Repeat(filler, (askMaxSnapshotBytes-len(md))/len(filler)) + md
	full := shown + strings.Repeat("z", askMaxSnapshotBytes-len(shown)+100)

	text, clipped, total := clipSnapshot(full)
	if text != shown || !clipped || total != len(full) {
		t.Fatalf("clipped %v total %d, text ends %q: cut right after the fixture's last shown line", clipped, total, text[max(0, len(text)-60):])
	}
}

// twin of MeetingTranscriptSliceTests.testNoTranscriptsPublishNothing.
func TestTranscriptNoTranscriptsPublishNothing(t *testing.T) {
	r := newTrRig(t, nil)
	if items := r.items(t); len(items) != 0 {
		t.Fatalf("published %d records with no transcript", len(items))
	}
}

// twin of SlicePublisherTests.testARecordLeavingTheWindowRemovesItsStagedFile:
// a transcript that left the window loses its staged file (at the next call,
// so the file is never removed while the cycle that returned it uploads it),
// and the transcript still in the window keeps its own.
func TestTranscriptLeavingTheWindowRemovesItsStagedFile(t *testing.T) {
	r := newTrRig(t, nil)
	gone := r.transcript(t, trSeed{text: "seven", created: calNow.Add(-2 * time.Hour)})
	kept := r.transcript(t, trSeed{text: "eight", created: calNow.Add(-time.Hour)})
	paths := map[string]string{}
	for _, it := range r.items(t) {
		paths[it.ID] = it.AssetPath
	}
	if len(paths) != 2 {
		t.Fatalf("staged %v", paths)
	}
	exec(t, r.d, `DELETE FROM meeting_transcripts WHERE id = ?`, gone)
	r.items(t)
	r.items(t)
	if fileExists(paths[fmt.Sprint(gone)]) {
		t.Error("the staged file of a transcript that left the window was kept")
	}
	if !fileExists(paths[fmt.Sprint(kept)]) {
		t.Error("the staged file of a transcript still in the window was removed")
	}
}

// --- terminal_session report_* fields (SessionReportSummaryRunner) ---

// summaryRig is a report rig whose summary fetch is the test's (summary
// timeout 50 ms).
func summaryRig(t *testing.T, fetch SummaryFetch) (*reportRig, *SessionReportRunner) {
	t.Helper()
	r := newReportRig(t)
	run, err := SessionReport(r.d, SessionReportOptions{
		Sessions: r.sessions(), Store: r.st, Sealer: r.k,
		Fetch: func(_ context.Context, _, id int64, _ bool) (sessionreport.Report, error) { return cliReport(t, id), nil },
		Summaries: fetch, Now: r.clock,
		Timing: ReportTiming{Every: 120 * time.Second, StateSpacing: 5 * time.Second, RequestSpacing: time.Minute,
			Timeout: 5 * time.Second, Idle: 5 * time.Second, SummaryEvery: time.Minute, SummarySpacing: 5 * time.Second,
			SummaryTimeout: 50 * time.Millisecond},
	})
	if err != nil {
		t.Fatal(err)
	}
	return r, run
}

// twin of TerminalSessionSliceTests.testTheSummaryJSONMapsToTheReportFieldsAndAFailureKeepsTheLastValues.
func TestSessionSummaryMapsToTheReportFieldsAndAFailureKeepsTheLastValues(t *testing.T) {
	var (
		session int64
		calls   []int64
		failing bool
	)
	r, run := summaryRig(t, func(_ context.Context, wb int64) ([]sessionreport.Summary, error) {
		calls = append(calls, wb)
		if failing {
			return nil, errors.New("cli failed")
		}
		return []sessionreport.Summary{{SessionID: session, TargetID: ptr(int64(415)), Done: 1, Total: 2, PRLine: "PR #175 open"}}, nil
	})
	project, s := r.seed()
	session = s
	r.setLive(session, true)
	payload := func() map[string]any { return payloads(t, r.source([]int64{session}, time.Time{}, run.Summary))[session] }
	if p := payload(); p["report_target_id"] != nil || p["report_done"] != nil {
		t.Fatalf("report fields before the first summary run: %v", p)
	}

	run.RunDue(context.Background())
	p := payload()
	if num(p["report_target_id"]) != 415 || num(p["report_done"]) != 1 || num(p["report_total"]) != 2 || p["report_pr_line"] != "PR #175 open" {
		t.Fatalf("mapped = %v", p)
	}

	failing = true
	r.advance(60 * time.Second)
	run.RunDue(context.Background())
	if !slices.Equal(calls, []int64{project, project}) {
		t.Fatalf("summary calls %v: the failing run did run", calls)
	}
	if p := payload(); num(p["report_target_id"]) != 415 || p["report_pr_line"] != "PR #175 open" {
		t.Fatalf("kept = %v: a summary failure keeps the last values", p)
	}
}

// twin of TerminalSessionSliceTests.testAHungSummaryTimesOutAndKeepsTheLastValues.
func TestSessionSummaryAHungRunTimesOutAndKeepsTheLastValues(t *testing.T) {
	r, run := summaryRig(t, func(ctx context.Context, _ int64) ([]sessionreport.Summary, error) {
		<-ctx.Done()
		return []sessionreport.Summary{{SessionID: 1, Done: 9, Total: 9}}, ctx.Err()
	})
	project, session := r.seed()
	r.setLive(session, true)
	start := time.Now()
	run.RunDue(context.Background())
	if time.Since(start) > 5*time.Second {
		t.Fatal("the hung summary was not cut at its timeout")
	}
	if _, ok := run.Summary(project, 1); ok {
		t.Fatal("a hung summary stored a value")
	}
}

// twin of TerminalSessionSliceTests.testAStopMidPassRunsTheUnfinishedWorkbenchesAgainAfterARestart:
// nothing the stop cut waits for the next 60 s.
func TestSessionSummaryAStopMidPassRunsTheUnfinishedWorkbenchesAgain(t *testing.T) {
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	var calls []int64
	r, run := summaryRig(t, func(c context.Context, wb int64) ([]sessionreport.Summary, error) {
		calls = append(calls, wb)
		if len(calls) == 1 {
			stop() // the hub stops while the first run is in flight
			<-c.Done()
			return nil, c.Err()
		}
		return nil, nil
	})
	var ids []int64
	for _, name := range []string{"acme", "beta", "gamma"} {
		wb := insertWorkbench(t, r.d, name, "/tmp/"+name)
		r.setLive(insertSession(t, r.d, wb, sessionSeed{lastActive: r.now}), true)
		ids = append(ids, wb)
	}
	run.RunDue(ctx)
	run.RunDue(context.Background())
	if want := []int64{ids[0], ids[0], ids[1], ids[2]}; !slices.Equal(calls, want) {
		t.Fatalf("summary calls %v, want %v", calls, want)
	}
}

// twin of TerminalSessionSliceTests.testAWorkbenchThatLeavesThePublishedListIsForgotten:
// its summaries are dropped and its pending request runs nothing.
func TestSessionSummaryAWorkbenchThatLeavesThePublishedListIsForgotten(t *testing.T) {
	var calls []int64
	r, run := summaryRig(t, func(_ context.Context, wb int64) ([]sessionreport.Summary, error) {
		calls = append(calls, wb)
		return []sessionreport.Summary{{SessionID: 1, Done: 1, Total: 2}}, nil
	})
	project := insertWorkbench(t, r.d, "acme", "/tmp/acme")
	run.SessionStateChanged(project)
	run.RunDue(context.Background())
	if _, ok := run.Summary(project, 1); !ok {
		t.Fatal("no summary stored")
	}

	exec(t, r.d, `DELETE FROM projects WHERE id = ?`, project)
	run.SessionStateChanged(project)
	r.advance(10 * time.Second)
	run.RunDue(context.Background())
	if _, ok := run.Summary(project, 1); ok {
		t.Error("the summaries of a workbench no longer published were kept")
	}
	if !slices.Equal(calls, []int64{project}) {
		t.Errorf("summary calls %v: the pending request must run nothing", calls)
	}
}
