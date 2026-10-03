package asks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validReview() Input {
	return Input{Kind: KindReview, Title: "Design doc", DocPath: "docs/design.md"}
}

func validCheck() Input {
	return Input{Kind: KindCheck, Title: "Try the build", Checklist: []ChecklistItem{{Text: "Launch the app"}}}
}

func validQuestion() Input {
	return Input{Kind: KindQuestion, Title: "Pick one", Questions: []Question{twoOptionQuestion("Which?")}}
}

func twoOptionQuestion(text string) Question {
	return Question{Question: text, Options: []Option{{Label: "A"}, {Label: "B"}}}
}

func wantField(t *testing.T, err error, field string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want error on %q, got nil", field)
	}
	if !strings.HasPrefix(err.Error(), field+": ") {
		t.Fatalf("want error on %q (field: reason), got %q", field, err)
	}
}

func TestValidateAcceptsEachKind(t *testing.T) {
	for _, in := range []Input{validReview(), validCheck(), validQuestion()} {
		if _, err := Validate(in); err != nil {
			t.Errorf("%s: %v", in.Kind, err)
		}
	}
}

func TestValidateKind(t *testing.T) {
	in := validQuestion()
	in.Kind = "poll"
	_, err := Validate(in)
	wantField(t, err, "kind")
}

func TestValidateBounds(t *testing.T) {
	n := func(k int) string { return strings.Repeat("я", k) }
	focus := func(k int) []Focus {
		out := make([]Focus, k)
		for i := range out {
			out[i] = Focus{Text: "look here"}
		}
		return out
	}
	questions := func(k int) []Question {
		out := make([]Question, k)
		for i := range out {
			out[i] = twoOptionQuestion("Q?")
		}
		return out
	}
	options := func(k int) []Option {
		out := make([]Option, k)
		for i := range out {
			out[i] = Option{Label: string(rune('A' + i))}
		}
		return out
	}
	items := func(k int) []ChecklistItem {
		out := make([]ChecklistItem, k)
		for i := range out {
			out[i] = ChecklistItem{Text: "step"}
		}
		return out
	}
	cases := []struct {
		name   string
		mutate func(*Input)
		field  string // "" means accepted
	}{
		{"title 120", func(in *Input) { in.Title = n(120) }, ""},
		{"title 121", func(in *Input) { in.Title = n(121) }, "title"},
		{"title padded 120", func(in *Input) { in.Title = "  " + n(120) + "\n" }, ""},
		{"title blank", func(in *Input) { in.Title = " \t " }, "title"},
		{"summary 2000", func(in *Input) { in.Summary = n(2000) }, ""},
		{"summary 2001", func(in *Input) { in.Summary = n(2001) }, "summary"},
		{"changes 1000", func(in *Input) { in.PreviousAskID = 3; in.Changes = n(1000) }, ""},
		{"changes 1001", func(in *Input) { in.PreviousAskID = 3; in.Changes = n(1001) }, "changes"},
		{"focus 5", func(in *Input) { in.Focus = focus(5) }, ""},
		{"focus 6", func(in *Input) { in.Focus = focus(6) }, "focus"},
		{"focus text 300", func(in *Input) { in.Focus = []Focus{{Text: n(300)}} }, ""},
		{"focus text 301", func(in *Input) { in.Focus = []Focus{{Text: n(301)}} }, "focus[0].text"},
		{"focus text blank", func(in *Input) { in.Focus = []Focus{{Text: " "}} }, "focus[0].text"},
		{"focus heading 200", func(in *Input) { in.Focus = []Focus{{Text: "x", Heading: n(200)}} }, ""},
		{"focus heading 201", func(in *Input) { in.Focus = []Focus{{Text: "x", Heading: n(201)}} }, "focus[0].heading"},
		{"focus quote 300", func(in *Input) { in.Focus = []Focus{{Text: "x", Quote: n(300)}} }, ""},
		{"focus quote 301", func(in *Input) { in.Focus = []Focus{{Text: "x", Quote: n(301)}} }, "focus[0].quote"},
		{"questions 4", func(in *Input) { in.Questions = questions(4) }, ""},
		{"questions 5", func(in *Input) { in.Questions = questions(5) }, "questions"},
		{"options 1", func(in *Input) { in.Questions = []Question{{Question: "Q?", Options: options(1)}} }, "questions[0].options"},
		{"options 2", func(in *Input) { in.Questions = []Question{{Question: "Q?", Options: options(2)}} }, ""},
		{"options 4", func(in *Input) { in.Questions = []Question{{Question: "Q?", Options: options(4)}} }, ""},
		{"options 5", func(in *Input) { in.Questions = []Question{{Question: "Q?", Options: options(5)}} }, "questions[0].options"},
		{"label 80", func(in *Input) {
			in.Questions = []Question{{Question: "Q?", Options: []Option{{Label: n(80)}, {Label: "B"}}}}
		}, ""},
		{"label 81", func(in *Input) {
			in.Questions = []Question{{Question: "Q?", Options: []Option{{Label: n(81)}, {Label: "B"}}}}
		}, "questions[0].options[0].label"},
		{"description 300", func(in *Input) {
			in.Questions = []Question{{Question: "Q?", Options: []Option{{Label: "A", Description: n(300)}, {Label: "B"}}}}
		}, ""},
		{"description 301", func(in *Input) {
			in.Questions = []Question{{Question: "Q?", Options: []Option{{Label: "A", Description: n(301)}, {Label: "B"}}}}
		}, "questions[0].options[0].description"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := validReview()
			c.mutate(&in)
			_, err := Validate(in)
			if c.field == "" {
				if err != nil {
					t.Fatalf("want accepted, got %v", err)
				}
				return
			}
			wantField(t, err, c.field)
		})
	}

	t.Run("checklist 30", func(t *testing.T) {
		in := validCheck()
		in.Checklist = items(30)
		if _, err := Validate(in); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("checklist 31", func(t *testing.T) {
		in := validCheck()
		in.Checklist = items(31)
		_, err := Validate(in)
		wantField(t, err, "checklist")
	})
	t.Run("checklist text 301", func(t *testing.T) {
		in := validCheck()
		in.Checklist = []ChecklistItem{{Text: n(301)}}
		_, err := Validate(in)
		wantField(t, err, "checklist[0].text")
	})
	t.Run("checklist hint 301", func(t *testing.T) {
		in := validCheck()
		in.Checklist = []ChecklistItem{{Text: "x", Hint: n(301)}}
		_, err := Validate(in)
		wantField(t, err, "checklist[0].hint")
	})
}

func TestValidateKindRules(t *testing.T) {
	cases := []struct {
		name  string
		in    func() Input
		field string
	}{
		{"question without questions", func() Input { in := validQuestion(); in.Questions = nil; return in }, "questions"},
		{"checklist on review", func() Input {
			in := validReview()
			in.Checklist = []ChecklistItem{{Text: "x"}}
			return in
		}, "checklist"},
		{"checklist on question", func() Input {
			in := validQuestion()
			in.Checklist = []ChecklistItem{{Text: "x"}}
			return in
		}, "checklist"},
		{"check without checklist", func() Input { in := validCheck(); in.Checklist = nil; return in }, "checklist"},
		{"heading on check focus", func() Input {
			in := validCheck()
			in.Focus = []Focus{{Text: "x", Heading: "Intro"}}
			return in
		}, "focus[0].heading"},
		{"quote on question focus", func() Input {
			in := validQuestion()
			in.Focus = []Focus{{Text: "x", Quote: "some words"}}
			return in
		}, "focus[0].quote"},
		{"changes without previous_ask_id", func() Input { in := validReview(); in.Changes = "rewrote §2"; return in }, "changes"},
		{"review without doc_path", func() Input { in := validReview(); in.DocPath = " "; return in }, "doc_path"},
		{"doc_path on check", func() Input { in := validCheck(); in.DocPath = "a.md"; return in }, "doc_path"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := Validate(c.in())
			wantField(t, err, c.field)
		})
	}
}

func TestValidateFirstViolationOnly(t *testing.T) {
	in := Input{Kind: KindReview, Title: "", Summary: strings.Repeat("x", 2001)}
	_, err := Validate(in)
	wantField(t, err, "title")
	if strings.Contains(err.Error(), "summary") {
		t.Fatalf("want only the first violation, got %q", err)
	}
}

func TestValidateIDs(t *testing.T) {
	t.Run("missing ids default to position", func(t *testing.T) {
		in := validCheck()
		in.Questions = []Question{twoOptionQuestion("1?"), {ID: "scope", Question: "2?", Options: []Option{{Label: "A"}, {Label: "B"}}}, twoOptionQuestion("3?")}
		in.Checklist = []ChecklistItem{{Text: "a"}, {ID: "login", Text: "b"}, {Text: "c"}}
		p, err := Validate(in)
		if err != nil {
			t.Fatal(err)
		}
		var qIDs, cIDs []string
		for _, q := range p.Questions {
			qIDs = append(qIDs, q.ID)
		}
		for _, c := range p.Checklist {
			cIDs = append(cIDs, c.ID)
		}
		if got := strings.Join(qIDs, ","); got != "1,scope,3" {
			t.Errorf("question ids = %s", got)
		}
		if got := strings.Join(cIDs, ","); got != "1,login,3" {
			t.Errorf("checklist ids = %s", got)
		}
	})
	t.Run("duplicate question ids", func(t *testing.T) {
		in := validQuestion()
		in.Questions = []Question{{ID: "2", Question: "a", Options: []Option{{Label: "A"}, {Label: "B"}}}, twoOptionQuestion("b")}
		_, err := Validate(in)
		wantField(t, err, "questions[1].id")
	})
	t.Run("duplicate checklist ids", func(t *testing.T) {
		in := validCheck()
		in.Checklist = []ChecklistItem{{ID: "x", Text: "a"}, {ID: "x", Text: "b"}}
		_, err := Validate(in)
		wantField(t, err, "checklist[1].id")
	})
	t.Run("duplicate option labels", func(t *testing.T) {
		in := validQuestion()
		in.Questions = []Question{{Question: "Q?", Options: []Option{{Label: "A"}, {Label: " A"}}}}
		_, err := Validate(in)
		wantField(t, err, "questions[0].options[1].label")
	})
}

func TestValidateNormalizesPayload(t *testing.T) {
	in := validReview()
	in.Focus = []Focus{{Text: "  look  ", Heading: " Intro ", Quote: " some words "}}
	in.Questions = []Question{{Question: " Q? ", Options: []Option{{Label: " A ", Description: " first "}, {Label: "B"}}}}
	p, err := Validate(in)
	if err != nil {
		t.Fatal(err)
	}
	if f := p.Focus[0]; f.Text != "look" || f.Heading != "Intro" || f.Quote != "some words" {
		t.Errorf("focus = %+v", f)
	}
	if q := p.Questions[0]; q.Question != "Q?" || q.Options[0].Label != "A" || q.Options[0].Description != "first" {
		t.Errorf("question = %+v", q)
	}
	if p.Checklist == nil {
		t.Error("checklist is nil; want an empty list so the stored JSON is []")
	}
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"checklist":[]`) {
		t.Errorf("payload JSON = %s", raw)
	}
}

// Every testdata/cards file is a ```watchtower-question body. Go runs it as
// the questions of a question ask; the Swift Core test runs the same file
// through ChatQuestionCard's decoder, and both must agree with the file name.
func TestCardFixtures(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("testdata", "cards", "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no card fixtures: %v", err)
	}
	for _, path := range files {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			cardErr := validateCard(raw)
			switch {
			case strings.HasPrefix(name, "valid_") && cardErr != nil:
				t.Fatalf("want accepted, got %v", cardErr)
			case strings.HasPrefix(name, "invalid_") && cardErr == nil:
				t.Fatal("want rejected, got accepted")
			case !strings.HasPrefix(name, "valid_") && !strings.HasPrefix(name, "invalid_"):
				t.Fatal("fixture name must start with valid_ or invalid_")
			}
		})
	}
}

func validateCard(raw []byte) error {
	var card struct {
		Questions []Question `json:"questions"`
	}
	if err := json.Unmarshal(raw, &card); err != nil {
		return err
	}
	_, err := Validate(Input{Kind: KindQuestion, Title: "Card", Questions: card.Questions})
	return err
}
