package asks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// answerFixture is one testdata/answers file: an answer to an ask of kind
// with payload. A valid_* file pins the canonical JSON (sorted keys, compact
// — what the Swift encoder reproduces byte for byte) and, through
// testdata/render/<name>.txt, the readable rendering; an invalid_* file pins
// the error.
type answerFixture struct {
	Kind      string          `json:"kind"`
	Payload   Payload         `json:"payload"`
	Answer    json.RawMessage `json:"answer"`
	Canonical string          `json:"canonical"`
	Error     string          `json:"error"`
}

func loadAnswerFixtures(t *testing.T) map[string]answerFixture {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("testdata", "answers", "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no answer fixtures: %v", err)
	}
	out := map[string]answerFixture{}
	for _, path := range files {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var f answerFixture
		if err := json.Unmarshal(raw, &f); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		out[strings.TrimSuffix(filepath.Base(path), ".json")] = f
	}
	return out
}

// checkAnswer is how get_ask takes an answer: parse, then check it against
// the ask it answers.
func checkAnswer(f answerFixture) (Answer, error) {
	a, err := ParseAnswer(f.Answer)
	if err != nil {
		return Answer{}, err
	}
	return a, ValidateAnswer(f.Kind, f.Payload, a)
}

func TestAnswerFixtures(t *testing.T) {
	for name, f := range loadAnswerFixtures(t) {
		t.Run(name, func(t *testing.T) {
			a, err := checkAnswer(f)
			if strings.HasPrefix(name, "invalid_") {
				if err == nil || err.Error() != f.Error {
					t.Fatalf("error = %v, want %q", err, f.Error)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got, err := json.Marshal(a)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != f.Canonical {
				t.Fatalf("canonical JSON\n got: %s\nwant: %s", got, f.Canonical)
			}
		})
	}
}

func TestParseAnswerFillsMissingLists(t *testing.T) {
	a, err := ParseAnswer([]byte(`{"verdict":"approved","answers":[{"id":"1","other":"x"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"answers":[{"id":"1","labels":[],"other":"x"}],"checklist":[],"comments":[],"note":"","verdict":"approved"}`
	if string(got) != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestParseAnswerRejects(t *testing.T) {
	cases := []struct {
		name, raw, field string
	}{
		{"not json", `{"verdict":`, "answer"},
		{"unknown verdict", `{"verdict":"maybe"}`, "verdict"},
		{"unknown state", `{"checklist":[{"id":"1","state":"fine"}]}`, "checklist[0].state"},
		{"empty state", `{"checklist":[{"id":"1"}]}`, "checklist[0].state"},
		{"broken without note", `{"checklist":[{"id":"1","state":"ok"},{"id":"2","state":"broken"}]}`, "checklist[1].note"},
		{"note too long", `{"note":"` + strings.Repeat("я", 4001) + `"}`, "note"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := ParseAnswer([]byte(c.raw))
			wantField(t, err, c.field)
		})
	}
	if _, err := ParseAnswer([]byte(`{"note":"` + strings.Repeat("я", 4000) + `"}`)); err != nil {
		t.Errorf("note of 4000 runes: %v", err)
	}
}

func TestValidateAnswerRejects(t *testing.T) {
	review := Payload{Focus: []Focus{}, Questions: []Question{}, Checklist: []ChecklistItem{}}
	question := Payload{
		Focus: []Focus{},
		Questions: []Question{
			{ID: "1", Question: "One?", Options: []Option{{Label: "A"}, {Label: "B"}}},
			{ID: "2", Question: "Many?", Multi: true, Options: []Option{{Label: "A"}, {Label: "B"}}},
		},
		Checklist: []ChecklistItem{},
	}
	check := Payload{Focus: []Focus{}, Questions: []Question{}, Checklist: []ChecklistItem{{ID: "1", Text: "Launch"}}}
	ok := `{"id":"1","state":"ok"}`
	cases := []struct {
		name, kind string
		payload    Payload
		raw, field string
	}{
		{"review without verdict", KindReview, review, `{}`, "verdict"},
		{"verdict on a check", KindCheck, check, `{"verdict":"approved","checklist":[` + ok + `]}`, "verdict"},
		{"comments on a question", KindQuestion, question,
			`{"answers":[{"id":"1","labels":["A"]},{"id":"2","labels":["A"]}],"comments":[{"quote":"q","body":"b"}]}`, "comments"},
		{"comment without body", KindReview, review, `{"verdict":"approved","comments":[{"quote":"q","body":" "}]}`, "comments[0].body"},
		{"question unanswered", KindQuestion, question, `{"answers":[{"id":"1","labels":["A"]}]}`, "answers"},
		{"empty answer", KindQuestion, question, `{"answers":[{"id":"1","labels":["A"]},{"id":"2","other":" "}]}`, "answers[1]"},
		{"unknown label", KindQuestion, question, `{"answers":[{"id":"1","labels":["C"]},{"id":"2","labels":["A"]}]}`, "answers[0].labels"},
		{"two labels on single select", KindQuestion, question,
			`{"answers":[{"id":"1","labels":["A","B"]},{"id":"2","labels":["A"]}]}`, "answers[0].labels"},
		{"unknown question id", KindQuestion, question,
			`{"answers":[{"id":"1","labels":["A"]},{"id":"2","labels":["A"]},{"id":"9","labels":["A"]}]}`, "answers[2].id"},
		{"duplicate question answer", KindQuestion, question,
			`{"answers":[{"id":"1","labels":["A"]},{"id":"1","labels":["B"]},{"id":"2","labels":["A"]}]}`, "answers[1].id"},
		{"check item unmarked", KindCheck, check, `{}`, "checklist"},
		{"unknown check item", KindCheck, check, `{"checklist":[` + ok + `,{"id":"7","state":"ok"}]}`, "checklist[1].id"},
		{"duplicate check item", KindCheck, check, `{"checklist":[` + ok + `,` + ok + `]}`, "checklist[1].id"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, err := ParseAnswer([]byte(c.raw))
			if err != nil {
				t.Fatal(err)
			}
			wantField(t, ValidateAnswer(c.kind, c.payload, a), c.field)
		})
	}
	t.Run("other alone answers a question", func(t *testing.T) {
		a, err := ParseAnswer([]byte(`{"answers":[{"id":"1","other":"neither"},{"id":"2","labels":["A","B"]}]}`))
		if err != nil {
			t.Fatal(err)
		}
		if err := ValidateAnswer(KindQuestion, question, a); err != nil {
			t.Fatal(err)
		}
	})
}
