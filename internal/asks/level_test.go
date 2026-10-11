package asks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func optionsN(n int) []Option {
	out := make([]Option, n)
	for i := range out {
		out[i] = Option{Label: string(rune('A' + i))}
	}
	return out
}

func questionPayload(qs ...Question) Payload {
	return Payload{Focus: []Focus{}, Questions: qs, Checklist: []ChecklistItem{}}
}

// Every row of spec 2026-10-10, Part 3.2. Each payload goes through Validate
// first, so a row never classifies a shape ask_owner would refuse.
func TestLevelTable(t *testing.T) {
	recommended := optionsN(2)
	recommended[1].Recommended = true
	cases := []struct {
		name   string
		in     Input
		origin string
		want   string
	}{
		{"one question, 2 options", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: optionsN(2)}}}, OriginAgent, LevelQuick},
		{"3 options", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: optionsN(3)}}}, OriginAgent, LevelQuick},
		{"4 options", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: optionsN(4)}}}, OriginAgent, LevelFull},
		{"multi", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Multi: true, Options: optionsN(2)}}}, OriginAgent, LevelFull},
		{"two questions", Input{Kind: KindQuestion, Title: "T", Questions: []Question{twoOptionQuestion("Q1"), twoOptionQuestion("Q2")}}, OriginAgent, LevelFull},
		{"40-rune label", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: []Option{{Label: strings.Repeat("я", 40)}, {Label: "B"}}}}}, OriginAgent, LevelQuick},
		{"41-rune label", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: []Option{{Label: strings.Repeat("я", 41)}, {Label: "B"}}}}}, OriginAgent, LevelFull},
		{"100-rune description", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: []Option{{Label: "A", Description: strings.Repeat("я", 100)}, {Label: "B"}}}}}, OriginAgent, LevelQuick},
		{"101-rune description", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: []Option{{Label: "A", Description: strings.Repeat("я", 101)}, {Label: "B"}}}}}, OriginAgent, LevelFull},
		{"focus point", Input{Kind: KindQuestion, Title: "T", Focus: []Focus{{Text: "Look here"}}, Questions: []Question{twoOptionQuestion("Q")}}, OriginAgent, LevelFull},
		{"review", validReview(), OriginAgent, LevelFull},
		{"check", validCheck(), OriginAgent, LevelFull},
		{"0 options from chat", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q"}}}, OriginChat, LevelQuick},
		{"2 options from chat", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: optionsN(2)}}}, OriginChat, LevelQuick},
		{"4 options from chat", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: optionsN(4)}}}, OriginChat, LevelFull},
		{"recommended flag", Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q", Options: recommended}}}, OriginAgent, LevelQuick},
		{"long title and summary", Input{Kind: KindQuestion, Title: strings.Repeat("t", 120), Summary: strings.Repeat("s", 2000), Questions: []Question{twoOptionQuestion("Q")}}, OriginAgent, LevelQuick},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p, err := Validate(c.in, c.origin)
			if err != nil {
				t.Fatalf("Validate: %v", err)
			}
			if got := Level(c.in.Kind, p, c.origin); got != c.want {
				t.Errorf("Level = %q, want %q (note %q)", got, c.want, LevelNote(c.in.Kind, p, c.origin))
			}
		})
	}

	// 0 options from the agent is refused by Validate, never classified.
	zero := Input{Kind: KindQuestion, Title: "T", Questions: []Question{{Question: "Q"}}}
	_, err := Validate(zero, OriginAgent)
	wantField(t, err, "questions[0].options")
}

func TestLevelNoteNamesTheFirstFailedRule(t *testing.T) {
	long := strings.Repeat("x", 41)
	cases := []struct {
		name   string
		kind   string
		p      Payload
		origin string
		want   string
	}{
		{"quick", KindQuestion, questionPayload(Question{Options: optionsN(2)}), OriginAgent, ""},
		{"review", KindReview, Payload{}, OriginAgent, "a review is always a Full ask"},
		{"check", KindCheck, Payload{Checklist: []ChecklistItem{{Text: "x"}}}, OriginAgent, "a check is always a Full ask"},
		{"two questions before multi", KindQuestion, questionPayload(Question{Multi: true, Options: optionsN(4)}, Question{Options: optionsN(2)}), OriginAgent, "2 questions: a Quick ask has one"},
		{"multi before options", KindQuestion, questionPayload(Question{Multi: true, Options: optionsN(4)}), OriginAgent, "a multi-choice question: a Quick ask takes one answer"},
		{"4 options before a long label", KindQuestion, questionPayload(Question{Options: []Option{{Label: long}, {Label: "B"}, {Label: "C"}, {Label: "D"}}}), OriginAgent, "4 options: a Quick ask has 2-3"},
		{"4 options from chat", KindQuestion, questionPayload(Question{Options: optionsN(4)}), OriginChat, "4 options: a Quick ask has 0, 2 or 3"},
		{"0 options from the agent", KindQuestion, questionPayload(Question{}), OriginAgent, "0 options: a Quick ask has 2-3"},
		{"long label before a long description", KindQuestion, questionPayload(Question{Options: []Option{{Label: "A", Description: strings.Repeat("d", 101)}, {Label: long}}}), OriginAgent, `option "` + long + `": a Quick ask's labels are at most 40 characters`},
		{"long description", KindQuestion, questionPayload(Question{Options: []Option{{Label: "A", Description: strings.Repeat("d", 101)}, {Label: "B"}}}), OriginAgent, `option "A" description: a Quick ask's descriptions are at most 100 characters`},
		{"focus", KindQuestion, Payload{Focus: []Focus{{Text: "x"}}, Questions: []Question{{Options: optionsN(2)}}}, OriginAgent, "focus points: a Quick ask has none"},
		{"checklist", KindQuestion, Payload{Questions: []Question{{Options: optionsN(2)}}, Checklist: []ChecklistItem{{Text: "x"}}}, OriginAgent, "a checklist: a Quick ask has none"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := LevelNote(c.kind, c.p, c.origin); got != c.want {
				t.Errorf("LevelNote = %q, want %q", got, c.want)
			}
			wantLevel := LevelFull
			if c.want == "" {
				wantLevel = LevelQuick
			}
			if got := Level(c.kind, c.p, c.origin); got != wantLevel {
				t.Errorf("Level = %q, want %q", got, wantLevel)
			}
		})
	}
}

// The shared owner_ask_zero_options fixture: a question with no options is
// stored only when Watchtower raises it from chat. One option is refused
// from either origin, and an unknown origin is refused outright.
func TestValidateZeroOptionsOnlyFromChat(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "cards", "owner_ask_zero_options.json"))
	if err != nil {
		t.Fatal(err)
	}
	var card struct {
		Questions []Question `json:"questions"`
	}
	if err := json.Unmarshal(raw, &card); err != nil {
		t.Fatal(err)
	}
	in := Input{Kind: KindQuestion, Title: "Staging host", Questions: card.Questions}

	p, err := Validate(in, OriginChat)
	if err != nil {
		t.Fatalf("origin chat: %v", err)
	}
	if len(p.Questions) != 1 || len(p.Questions[0].Options) != 0 {
		t.Fatalf("payload questions = %+v", p.Questions)
	}
	if got := Level(KindQuestion, p, OriginChat); got != LevelQuick {
		t.Errorf("Level = %q, want quick", got)
	}

	_, err = Validate(in, OriginAgent)
	wantField(t, err, "questions[0].options")

	one := Input{Kind: KindQuestion, Title: "One", Questions: []Question{{Question: "Q", Options: optionsN(1)}}}
	for _, origin := range []string{OriginAgent, OriginChat} {
		_, err := Validate(one, origin)
		wantField(t, err, "questions[0].options")
	}

	_, err = Validate(in, "")
	wantField(t, err, "origin")
}
