package specreview

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

const answerFixturePath = "testdata/answer_marks.json"

// answerCase is one case of testdata/answer_marks.json, the cases Core's
// SpecReviewAnswer.build runs too (SpecReviewAnswerFixtureTests): both sides
// must give `want` for the same input. `ledger` null is a review without an
// author loop, `[]` a finished loop with an empty ledger.
type answerCase struct {
	Name   string `json:"name"`
	Result *Result
	Ledger []LedgerEntry
	Marks  map[string]struct {
		State string `json:"state"`
		Body  string `json:"body"`
		About string `json:"about"`
	}
	Base     asks.Answer
	Verdict  string
	Snapshot string
	Want     json.RawMessage
}

func (c *answerCase) UnmarshalJSON(raw []byte) error {
	var f struct {
		Name     string          `json:"name"`
		Result   *Result         `json:"result"`
		Ledger   []LedgerEntry   `json:"ledger"`
		Marks    json.RawMessage `json:"marks"`
		Base     asks.Answer     `json:"base"`
		Verdict  string          `json:"verdict"`
		Snapshot string          `json:"snapshot"`
		Want     json.RawMessage `json:"want"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		return err
	}
	*c = answerCase{Name: f.Name, Result: f.Result, Ledger: f.Ledger, Base: f.Base,
		Verdict: f.Verdict, Snapshot: f.Snapshot, Want: f.Want}
	return json.Unmarshal(f.Marks, &c.Marks)
}

func (c answerCase) marks() map[string]db.SpecReviewMark {
	out := map[string]db.SpecReviewMark{}
	for k, m := range c.Marks {
		out[k] = db.SpecReviewMark{State: m.State, Body: m.Body, About: m.About}
	}
	return out
}

func (c answerCase) build() asks.Answer {
	return BuildAnswer(c.Result, c.marks(), c.Ledger, c.Base, c.Verdict, c.Snapshot)
}

func TestBuildAnswer_FixtureCases(t *testing.T) {
	raw, err := os.ReadFile(answerFixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []answerCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	if *update {
		var rewritten []map[string]json.RawMessage
		var fields []map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			t.Fatal(err)
		}
		for i, c := range cases {
			want, err := json.Marshal(c.build())
			if err != nil {
				t.Fatal(err)
			}
			fields[i]["want"] = want
			rewritten = append(rewritten, fields[i])
		}
		out, err := json.MarshalIndent(rewritten, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(answerFixturePath, append(out, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := json.Marshal(c.build())
			if err != nil {
				t.Fatal(err)
			}
			var want asks.Answer
			if err := json.Unmarshal(c.Want, &want); err != nil || len(c.Want) == 0 {
				t.Fatalf("want: %v (%s)", err, c.Want)
			}
			wantJSON, _ := json.Marshal(want)
			if string(got) != string(wantJSON) {
				t.Fatalf("got  %s\nwant %s", got, wantJSON)
			}
		})
	}
}

func answerFixtureResult(t *testing.T) (*Result, string) {
	t.Helper()
	raw, err := os.ReadFile(answerFixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var cases []answerCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		if c.Name == "comment_marks_in_findings_order_with_margin_and_verdict" {
			return c.Result, c.Snapshot
		}
	}
	t.Fatal("fixture case missing")
	return nil, ""
}

var answerAt = time.Date(2026, 11, 18, 9, 30, 0, 0, time.UTC)

func TestAnswerMarks_DropsUnknownKeys(t *testing.T) {
	result, snapshot := answerFixtureResult(t)
	twin := []TwinMark{
		{Key: "ag:1", State: "comment", Body: "per channel only"},
		{Key: "nope:1", State: "comment", Body: "invented"},
		{Key: "da:1", State: "bogus"},
		{Key: "bs:1", State: "not_useful"},
	}
	ans, marks := AnswerMarks(7, result, nil, twin, "changes", snapshot, answerAt)
	if len(marks) != 2 || marks[0].Key != "ag:1" || marks[1].Key != "bs:1" {
		t.Fatalf("marks = %+v", marks)
	}
	if len(ans.Comments) != 1 || ans.Comments[0].ItemKey != "ag:1" {
		t.Fatalf("comments = %+v", ans.Comments)
	}
	if ans.Verdict != "changes" {
		t.Fatalf("verdict = %q", ans.Verdict)
	}
	if m := marks[0]; m.AskID != 7 || m.About != "Mute is per channel" || m.UpdatedAt != "2026-11-18T09:30:00Z" {
		t.Fatalf("mark = %+v", m)
	}
	if marks[1].About != "" {
		t.Fatalf("only a comment keeps its finding text: %+v", marks[1])
	}
}

// A ledger-only key (a finding the loop carried that the result no longer
// has) is known, so a twin mark on it stays.
func TestAnswerMarks_LedgerKeysAreKnown(t *testing.T) {
	result, snapshot := answerFixtureResult(t)
	loop := []LedgerEntry{{AuthorItem: AuthorItem{Key: "gone:1", Text: "Ledger only"}, Verdict: VerdictUnsettled}}
	ans, marks := AnswerMarks(1, result, loop, []TwinMark{{Key: "gone:1", State: "comment", Body: "still open"}}, "", snapshot, answerAt)
	if len(marks) != 1 || len(ans.Comments) != 1 || ans.Comments[0].ItemKey != "gone:1" {
		t.Fatalf("marks %+v comments %+v", marks, ans.Comments)
	}
}

// The answer's comments are what the marks would produce at the Mac: the same
// BuildAnswer over the stored marks, whatever order or repeats the twin sent.
func TestAnswerMarks_CommentsMatchBuildAnswer(t *testing.T) {
	result, snapshot := answerFixtureResult(t)
	twin := []TwinMark{
		{Key: "ck:1", State: "comment", Body: "yes"},
		{Key: "ag:1", State: "ok"},
		{Key: "ag:1", State: "comment", Body: "second click wins"},
		{Key: "da:1", State: "comment"},
	}
	ans, marks := AnswerMarks(3, result, nil, twin, "approved", snapshot, answerAt)
	stored := map[string]db.SpecReviewMark{}
	for _, m := range marks {
		stored[m.Key] = m
	}
	want := BuildAnswer(result, stored, nil, asks.Answer{}, "approved", snapshot)
	got, _ := json.Marshal(ans)
	wantJSON, _ := json.Marshal(want)
	if string(got) != string(wantJSON) {
		t.Fatalf("got  %s\nwant %s", got, wantJSON)
	}
	if len(marks) != 3 || len(ans.Comments) != 3 {
		t.Fatalf("marks %d comments %d", len(marks), len(ans.Comments))
	}
	if marks[0].Key != "ck:1" || marks[1].Key != "ag:1" || marks[1].State != "comment" || marks[1].Body != "second click wins" {
		t.Fatalf("marks = %+v", marks)
	}
}
