package sources

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rivo/uniseg"
)

// Go twins of OwnerAskSliceTests: the window, the snapshot, payload and text
// caps, the Mac-computed quick answer and the spec reviewer's line.

var askOptional = []string{
	"session_id", "target_id", "withdrawn_reason", "previous_ask_id", "answered_at", "delivered_at",
	"title_clipped", "summary_clipped", "changes_clipped", "payload", "payload_clipped", "doc_path_clipped",
	"doc_snapshot", "doc_clipped", "doc_bytes", "answer", "quick", "spec_review",
}

func questionPayload(options [][2]any, multi bool, questions int) string {
	var opts []string
	for _, o := range options {
		opts = append(opts, fmt.Sprintf(`{"label": %q, "recommended": %v}`, o[0], o[1]))
	}
	var qs []string
	for i := 1; i <= questions; i++ {
		qs = append(qs, fmt.Sprintf(`{"id": "q%d", "question": "Which?", "multi": %v, "options": [%s]}`, i, multi, strings.Join(opts, ", ")))
	}
	return `{"focus": [], "questions": [` + strings.Join(qs, ", ") + `], "checklist": []}`
}

func askID(id int64) string { return strconv.FormatInt(id, 10) }

func TestOwnerAskOpenQuestionMatchesTheKitFixture(t *testing.T) {
	d := openDB(t)
	project := seedWorkbench(t, d, "Acme")
	session := seedSession(t, d, project, "claude")
	target := execID(t, d, `INSERT INTO targets (text, period_start, period_end) VALUES ('t', '2026-10-01', '2026-10-31')`)
	id := seedAsk(t, d, askSpec{project: project, session: session, target: target, title: "Which release?",
		payload: questionPayload([][2]any{{"v0.11", true}, {"v0.10", false}}, false, 1)})
	execID(t, d, `UPDATE owner_asks SET summary = 'Pick one.' WHERE id = ?`, id)

	p := payloadsByKey(t, OwnerAsk(d, nil))[askID(id)]
	assertKitKeys(t, p, "owner_ask.json", askOptional...)
	if p["workbench_name"] != "Acme" || p["status"] != "open" || p["target_id"] != float64(target) || p["session_id"] != float64(session) {
		t.Errorf("payload %v", p)
	}
	for _, k := range []string{"withdrawn_reason", "answer", "answered_at", "doc_snapshot"} {
		if _, ok := p[k]; ok {
			t.Errorf("%s published on an open question", k)
		}
	}
}

func TestOwnerAskCarriesSpecReviewLine(t *testing.T) {
	d := openDB(t)
	project := seedWorkbench(t, d, "acme")
	result := `{"agreements":[{"key":"a","status":"as_agreed"},{"key":"b","status":"differs"}],"blind_spots":[{"key":"c"}]}`
	cases := []struct{ status, result, reason, line string }{
		{"done", result, "", "1 as agreed · 1 differs · 1 blind spot"},
		{"queued", "", "", "Reviewer is reading…"},
		{"running", "", "", "Reviewer is reading…"},
		{"failed", "", "timed out", "Reviewer failed: timed out"},
		{"skipped", "", "", "Reviewer skipped"},
	}
	src := OwnerAsk(d, nil)
	for _, c := range cases {
		id := seedAsk(t, d, askSpec{project: project, kind: "review"})
		execID(t, d, `INSERT INTO spec_reviews (ask_id, status, result, reason, queued_at) VALUES (?, ?, ?, ?, '2026-10-25T10:00:00Z')`,
			id, c.status, c.result, c.reason)
		review, _ := payloadsByKey(t, src)[askID(id)]["spec_review"].(map[string]any)
		if review["status"] != c.status || review["line"] != c.line {
			t.Errorf("%s: spec_review %v", c.status, review)
		}
	}
	plain := seedAsk(t, d, askSpec{project: project, kind: "review"})
	if _, ok := payloadsByKey(t, src)[askID(plain)]["spec_review"]; ok {
		t.Error("no reviewer row, yet a spec_review")
	}
}

func TestOwnerAskDoneReviewLineIsKeptPerFinish(t *testing.T) {
	d := openDB(t)
	id := seedAsk(t, d, askSpec{project: seedWorkbench(t, d, "acme"), kind: "review"})
	execID(t, d, `INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at)
		VALUES (?, 'done', '{"blind_spots":[{"key":"c"}]}', '2026-10-25T10:00:00Z', '2026-10-25T10:05:00Z')`, id)
	src := OwnerAsk(d, nil)
	line := func() any {
		r, _ := payloadsByKey(t, src)[askID(id)]["spec_review"].(map[string]any)
		return r["line"]
	}
	if got := line(); got != "1 blind spot" {
		t.Fatalf("line %v", got)
	}
	execID(t, d, `UPDATE spec_reviews SET result = '{}' WHERE ask_id = ?`, id)
	if got := line(); got != "1 blind spot" {
		t.Fatalf("same finish: %v", got)
	}
	execID(t, d, `UPDATE spec_reviews SET finished_at = '2026-10-25T10:09:00Z' WHERE ask_id = ?`, id)
	if got := line(); got != "No findings" {
		t.Fatalf("a new finish: %v", got)
	}
}

func TestOwnerAskReviewAndClosedCheckMatchTheKitFixtures(t *testing.T) {
	d := openDB(t)
	project := seedWorkbench(t, d, "acme")
	review := seedAsk(t, d, askSpec{project: project, kind: "review"})
	execID(t, d, `UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?`, "# Plan\n\nStep 1.\n", review)
	answer := `{"verdict":"","answers":[],"checklist":[{"id":"1","state":"ok","note":""}],"comments":[],"note":""}`
	check := seedAsk(t, d, askSpec{project: project, kind: "check", status: "delivered", answer: answer,
		payload: `{"focus": [], "questions": [], "checklist": [{"id": "1", "text": "Launch the app"}]}`})
	stamp := dbStamp(time.Now())
	execID(t, d, `UPDATE owner_asks SET answered_at = ?, delivered_at = ? WHERE id = ?`, stamp, stamp, check)

	all := payloadsByKey(t, OwnerAsk(d, nil))
	r := all[askID(review)]
	assertKitKeys(t, r, "owner_ask_review.json", askOptional...)
	if r["doc_snapshot"] != "# Plan\n\nStep 1.\n" || r["doc_path"] != "docs/plan.md" || r["doc_clipped"] != nil || r["doc_bytes"] != nil {
		t.Errorf("review %v", r)
	}
	c := all[askID(check)]
	assertKitKeys(t, c, "owner_ask_closed.json", askOptional...)
	a, _ := c["answer"].(map[string]any)
	if list, _ := a["checklist"].([]any); len(list) != 1 || c["answered_at"] == nil || c["delivered_at"] == nil {
		t.Errorf("closed check %v", c)
	}
}

func TestOwnerAskA2MiBSnapshotIsCutAtTheLastNewlineBefore256KiB(t *testing.T) {
	full := strings.Repeat(strings.Repeat("x", 99)+"\n", 20_971) + strings.Repeat("y", 52)
	if len(full) != 2<<20 {
		t.Fatal(len(full))
	}
	text, clipped, total := clipSnapshot(full)
	if len(text) != 262_100 || !strings.HasPrefix(full, text) || !strings.HasSuffix(text, "\n") || !clipped || total != 2<<20 {
		t.Fatalf("len %d clipped %v total %d", len(text), clipped, total)
	}
}

func TestOwnerAskASnapshotWithNoNewlineIsCutAtAGraphemeBoundary(t *testing.T) {
	family := "👩‍👩‍👧"
	full := strings.Repeat(family, 20_000)
	text, clipped, total := clipSnapshot(full)
	n := uniseg.GraphemeClusterCount(text)
	if n != 256*1024/len(family) || text != strings.Repeat(family, n) || len(text) > 256*1024 || !clipped || total != len(full) {
		t.Fatalf("clusters %d len %d clipped %v", n, len(text), clipped)
	}
	// Combining marks at the cap stay with their letter.
	text, clipped, _ = clipSnapshot(strings.Repeat("é", 100_000))
	if len([]rune(text))%2 != 0 || !clipped {
		t.Fatalf("a letter lost its mark (%d runes)", len([]rune(text)))
	}
	// Exactly 256 KiB is not clipped.
	exact := strings.Repeat("a", 256*1024)
	if text, clipped, _ := clipSnapshot(exact); text != exact || clipped {
		t.Fatal("256 KiB was clipped")
	}
}

func TestOwnerAskClosedAsksCarryNoSnapshot(t *testing.T) {
	d := openDB(t)
	id := seedAsk(t, d, askSpec{project: seedWorkbench(t, d, "acme"), kind: "review", status: "answered"})
	execID(t, d, `UPDATE owner_asks SET doc_snapshot = '# Plan' WHERE id = ?`, id)
	p := payloadsByKey(t, OwnerAsk(d, nil))[askID(id)]
	if p["doc_snapshot"] != nil || p["doc_clipped"] != nil || p["doc_bytes"] != nil || p["doc_path"] != "docs/plan.md" {
		t.Fatalf("closed review %v", p)
	}
}

func TestOwnerAskPayloadCap(t *testing.T) {
	d := openDB(t)
	project := seedWorkbench(t, d, "acme")
	question := `{"id": "q", "question": "Which?", "options": [{"label": "A", "recommended": true}, {"label": "B"}]}`
	big := seedAsk(t, d, askSpec{project: project,
		payload: `{"focus": [{"text": "` + strings.Repeat("f", 65*1024) + `"}], "questions": [` + question + `], "checklist": []}`})
	small := seedAsk(t, d, askSpec{project: project, payload: questionPayload([][2]any{{"A", true}, {"B", false}}, false, 1)})
	all := payloadsByKey(t, OwnerAsk(d, nil))
	if p := all[askID(big)]; p["payload_clipped"] != true || p["payload"] != nil || p["quick"] != nil {
		t.Errorf("over 64 KiB: %v", keysOf(p))
	}
	if p := all[askID(small)]; p["payload_clipped"] != nil || p["payload"] == nil {
		t.Errorf("under 64 KiB: %v", keysOf(p))
	}
}

func TestOwnerAskTextFieldsAreClipped(t *testing.T) {
	d := openDB(t)
	id := seedAsk(t, d, askSpec{project: seedWorkbench(t, d, "acme")})
	execID(t, d, `UPDATE owner_asks SET title = ?, summary = ?, changes = ? WHERE id = ?`,
		strings.Repeat("t", 201), strings.Repeat("s", 4001), strings.Repeat("c", 4001), id)
	p := payloadsByKey(t, OwnerAsk(d, nil))[askID(id)]
	for field, limit := range map[string]int{"title": 200, "summary": 4000, "changes": 4000} {
		s, _ := p[field].(string)
		if uniseg.GraphemeClusterCount(s) != limit || !strings.HasSuffix(s, "…") || p[field+"_clipped"] != true {
			t.Errorf("%s: %d clusters, clipped %v", field, uniseg.GraphemeClusterCount(s), p[field+"_clipped"])
		}
	}
}

func TestOwnerAskQuick(t *testing.T) {
	d := openDB(t)
	project := seedWorkbench(t, d, "acme")
	three := seedAsk(t, d, askSpec{project: project, payload: questionPayload([][2]any{{"A", false}, {"B", true}, {"C", false}}, false, 1)})
	cases := map[string]string{
		"multi-select":          questionPayload([][2]any{{"A", true}, {"B", false}, {"C", false}}, true, 1),
		"no recommended option": questionPayload([][2]any{{"A", false}, {"B", false}, {"C", false}}, false, 1),
		"1 option":              questionPayload([][2]any{{"A", true}}, false, 1),
		"5 options":             questionPayload([][2]any{{"A", true}, {"B", false}, {"C", false}, {"D", false}, {"E", false}}, false, 1),
		"2 questions":           questionPayload([][2]any{{"A", true}, {"B", false}}, false, 2),
	}
	ids := map[string]int64{}
	for name, raw := range cases {
		ids[name] = seedAsk(t, d, askSpec{project: project, payload: raw})
	}
	check := seedAsk(t, d, askSpec{project: project, kind: "check", payload: questionPayload([][2]any{{"A", true}, {"B", false}}, false, 1)})
	all := payloadsByKey(t, OwnerAsk(d, nil))

	q, _ := all[askID(three)]["quick"].(map[string]any)
	opts, _ := q["options"].([]any)
	if q["question_id"] != "q1" || len(opts) != 3 {
		t.Fatalf("quick %v", q)
	}
	for i, want := range [][2]any{{"A", false}, {"B", true}, {"C", false}} {
		o := opts[i].(map[string]any)
		if o["label"] != want[0] || o["recommended"] != want[1] {
			t.Errorf("option %d = %v", i, o)
		}
	}
	for name, id := range ids {
		if p := all[askID(id)]; p["quick"] != nil || p["payload"] == nil {
			t.Errorf("%s: quick %v", name, p["quick"])
		}
	}
	if all[askID(check)]["quick"] != nil {
		t.Error("a check got quick")
	}
}

func TestOwnerAskClosedWindow(t *testing.T) {
	d := openDB(t)
	now := time.Now()
	project := seedWorkbench(t, d, "acme")
	var closed []int64
	for i := 0; i < 51; i++ {
		closed = append(closed, seedAsk(t, d, askSpec{project: project, status: "answered",
			createdAt: dbStamp(now.Add(-time.Duration(i) * time.Hour))}))
	}
	old := seedAsk(t, d, askSpec{project: project, status: "withdrawn", createdAt: dbStamp(now.Add(-8 * 24 * time.Hour))})
	open := seedAsk(t, d, askSpec{project: project, createdAt: dbStamp(now.Add(-30 * 24 * time.Hour))})
	all := payloadsByKey(t, OwnerAsk(d, func() time.Time { return now }))
	n := 0
	for _, id := range closed {
		if _, ok := all[askID(id)]; ok {
			n++
		}
	}
	if _, ok := all[askID(closed[50])]; n != 50 || ok {
		t.Errorf("closed published %d, oldest present %v", n, ok)
	}
	if _, ok := all[askID(old)]; ok {
		t.Error("closed 8 days ago is published")
	}
	if _, ok := all[askID(open)]; !ok {
		t.Error("an old open ask is not published")
	}

	// The closed cap is per workbench.
	second := seedWorkbench(t, d, "acme-2")
	for i := 0; i < 50; i++ {
		seedAsk(t, d, askSpec{project: second, status: "answered", createdAt: dbStamp(now.Add(-time.Duration(i) * time.Minute))})
	}
	if got := len(payloadsByKey(t, OwnerAsk(d, func() time.Time { return now }))); got != 50+1+50 {
		t.Errorf("%d published, want 101", got)
	}
}

func TestOwnerAskNoWorkbenchesAndAuthorLoop(t *testing.T) {
	d := openDB(t)
	if got := payloadsByKey(t, OwnerAsk(d, nil)); len(got) != 0 {
		t.Fatalf("no workbenches: %d asks", len(got))
	}
	project := seedWorkbench(t, d, "acme")
	hidden := seedAsk(t, d, askSpec{project: project, kind: "review"})
	owner := seedAsk(t, d, askSpec{project: project, kind: "review"})
	execID(t, d, `INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES
		(?, 'running', '2026-10-26T10:00:00Z', 'author'), (?, 'done', '2026-10-26T10:00:00Z', 'owner')`, hidden, owner)
	all := payloadsByKey(t, OwnerAsk(d, nil))
	if _, ok := all[askID(hidden)]; ok {
		t.Error("an author-loop ask is published")
	}
	if _, ok := all[askID(owner)]; !ok {
		t.Error("the owner-turn ask is not published")
	}
}

func TestOwnerAskPhoneLineForLoopRow(t *testing.T) {
	d := openDB(t)
	id := seedAsk(t, d, askSpec{project: seedWorkbench(t, d, "acme"), kind: "review"})
	ledger := `[{"key":"a","kind":"agreement","text":"t","verdict":"resolved"},
		{"key":"b","kind":"blind_spot","text":"t","verdict":"disputed"},
		{"key":"c","kind":"agreement","text":"t","verdict":"unsettled"},
		{"key":"d","kind":"check","text":"t","verdict":"resolved"}]`
	execID(t, d, `INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at, loop, ledger, loop_end)
		VALUES (?, 'done', '{}', '2026-10-26T10:00:00Z', '2026-10-26T10:05:00Z', 'owner', ?, 'settled')`, id, ledger)
	src := OwnerAsk(d, nil)
	line := func() any {
		r, _ := payloadsByKey(t, src)[askID(id)]["spec_review"].(map[string]any)
		return r["line"]
	}
	if got := line(); got != "Reviewer and author disagree on 1 · 1 not answered · 2 fixed by the author" {
		t.Fatalf("line %v", got)
	}
	execID(t, d, `UPDATE spec_reviews SET ledger = '[{"key":"a","kind":"agreement","text":"t","verdict":"resolved"}]',
		loop_end = 'cap' WHERE ask_id = ?`, id)
	if got := line(); got != "1 fixed by the author" {
		t.Fatalf("a changed loop_end: %v", got)
	}
}
