package chat

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
)

// The question parser: the Go twin of Swift's ChatQuestionParser
// (WatchtowerChatText), pinned from both sides by
// testdata/question_parse_cases.json. The engine uses it for the fallback
// text of a reply that carries a ```watchtower-question card.

const questionFence = "```watchtower-question"

// QuestionOption is one option of a question card.
type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description"`
	Recommended bool   `json:"recommended"`
}

// Question is one question of a card: 2-4 options, single or multi select.
type Question struct {
	ID       string           `json:"id"`
	Question string           `json:"question"`
	Multi    bool             `json:"multi"`
	Options  []QuestionOption `json:"options"`
}

// QuestionCard is a ```watchtower-question block from an assistant reply:
// 1-4 questions the owner answers with a click.
type QuestionCard struct {
	Questions []Question `json:"questions"`
}

// ParseQuestionCard finds the question card in a reply and returns the text
// without the card's block. Only a block that decodes and stays within the
// bounds becomes a card; anything else stays in the text. final is false while
// the reply streams: no card is shown and an unclosed block is hidden; once
// final, an unclosed block stays visible. When several blocks are valid the
// last one is the card and the earlier ones stay in the text.
func ParseQuestionCard(text string, final bool) (rest string, card *QuestionCard) {
	if !strings.Contains(text, questionFence) {
		return text, nil
	}
	type span struct{ lo, hi int }
	var removals []span
	var cardSpan *span
	cursor := 0
	for {
		at := strings.Index(text[cursor:], questionFence)
		if at < 0 {
			break
		}
		open := cursor + at
		openEnd := open + len(questionFence)
		cursor = openEnd
		if open != 0 && text[open-1] != '\n' {
			continue
		}
		var lineEnd, closeLo, closeHi int
		nl := strings.IndexByte(text[openEnd:], '\n')
		found := false
		if nl >= 0 {
			lineEnd = openEnd + nl
			closeLo, closeHi, found = closingFence(text, lineEnd)
		}
		if !found {
			if !final {
				removals = append(removals, span{open, len(text)})
			}
			break
		}
		body := ""
		if closeLo > lineEnd {
			body = text[lineEnd+1 : closeLo]
		}
		cursor = closeHi
		if decoded := decodeQuestionCard([]byte(body)); decoded != nil {
			card = decoded
			cardSpan = &span{open, closeHi}
		}
	}
	if cardSpan != nil {
		removals = append(removals, *cardSpan)
	}
	// Few spans; insertion sort keeps the order the Swift twin sorts to.
	for i := 1; i < len(removals); i++ {
		for j := i; j > 0 && removals[j].lo < removals[j-1].lo; j-- {
			removals[j], removals[j-1] = removals[j-1], removals[j]
		}
	}
	if !final {
		card = nil
	}
	if len(removals) == 0 {
		return text, card
	}
	var visible strings.Builder
	kept := 0
	for _, r := range removals {
		visible.WriteString(text[kept:r.lo])
		kept = r.hi
	}
	visible.WriteString(text[kept:])
	return strings.TrimSpace(visible.String()), card
}

// QuestionReadableText is a finished reply as a person reads it (what Copy
// and Quote take): the prose, then the card's questions and options as plain
// lines instead of the raw JSON block.
func QuestionReadableText(text string) string {
	rest, card := ParseQuestionCard(text, true)
	if card == nil {
		return rest
	}
	var blocks []string
	if rest != "" {
		blocks = append(blocks, rest)
	}
	for _, q := range card.Questions {
		lines := []string{q.Question}
		for _, o := range q.Options {
			line := "- " + o.Label
			if o.Recommended {
				line += " (recommended)"
			}
			lines = append(lines, line)
		}
		blocks = append(blocks, strings.Join(lines, "\n"))
	}
	return strings.Join(blocks, "\n\n")
}

// closingFence is the line that is exactly ``` after start (a newline); the
// range covers the leading newline and the fence.
func closingFence(text string, start int) (lo, hi int, ok bool) {
	cursor := start
	for {
		at := strings.Index(text[cursor:], "\n```")
		if at < 0 {
			return 0, 0, false
		}
		lo = cursor + at
		hi = lo + len("\n```")
		if hi == len(text) || text[hi] == '\n' {
			return lo, hi, true
		}
		cursor = hi
	}
}

type rawQuestionCard struct {
	Questions *[]rawQuestion `json:"questions"`
}

type rawQuestion struct {
	ID       *string      `json:"id"`
	Question *string      `json:"question"`
	Multi    *bool        `json:"multi"`
	Options  *[]rawOption `json:"options"`
}

type rawOption struct {
	Label       *string `json:"label"`
	Description *string `json:"description"`
	Recommended *bool   `json:"recommended"`
}

// decodeQuestionCard is a card body ({"questions": [...]}, unknown keys
// ignored), or nil when it does not decode or breaks a bound: the same rules
// as Swift's ChatQuestionParser.decodeCard.
func decodeQuestionCard(body []byte) *QuestionCard {
	var raw rawQuestionCard
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&raw); err != nil || dec.More() || raw.Questions == nil {
		return nil
	}
	if n := len(*raw.Questions); n < 1 || n > 4 {
		return nil
	}
	card := &QuestionCard{}
	seen := map[string]bool{}
	for i, rq := range *raw.Questions {
		if rq.Question == nil || rq.Options == nil {
			return nil
		}
		q := Question{Question: strings.TrimSpace(*rq.Question), Multi: rq.Multi != nil && *rq.Multi}
		labels := map[string]bool{}
		for _, ro := range *rq.Options {
			if ro.Label == nil {
				return nil
			}
			o := QuestionOption{Label: strings.TrimSpace(*ro.Label), Recommended: ro.Recommended != nil && *ro.Recommended}
			if ro.Description != nil {
				o.Description = *ro.Description
			}
			if o.Label == "" || labels[o.Label] {
				return nil
			}
			labels[o.Label] = true
			q.Options = append(q.Options, o)
		}
		if q.Question == "" || len(q.Options) < 2 || len(q.Options) > 4 {
			return nil
		}
		q.ID = strconv.Itoa(i + 1)
		if rq.ID != nil && *rq.ID != "" {
			q.ID = *rq.ID
		}
		if seen[q.ID] {
			return nil
		}
		seen[q.ID] = true
		card.Questions = append(card.Questions, q)
	}
	return card
}
