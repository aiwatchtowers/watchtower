package asks

import (
	"fmt"
	"strings"
)

// Render is get_ask's answer_text: the answer as the agent reads it, in the
// ask's own order — the verdict, each question `→ labels / Other: text`,
// each check item `→ Works / Doesn't work / Didn't check` with its note
// after a colon (the Desktop's labels, so the agent reads what the owner
// pressed), each comment as `> quote`, its
// heading and its body, then the note. Sections are separated by a blank
// line; an empty section is left out.
func Render(kind string, p Payload, a Answer) string {
	var sections []string
	if kind == KindReview {
		sections = append(sections, "Verdict: "+verdictText(a.Verdict))
	}
	if len(p.Questions) > 0 {
		sections = append(sections, renderQuestions(p.Questions, a.Answers))
	}
	if len(p.Checklist) > 0 {
		sections = append(sections, renderChecklist(p.Checklist, a.Checklist))
	}
	if len(a.Comments) > 0 {
		sections = append(sections, renderComments(a.Comments))
	}
	if note := strings.TrimSpace(a.Note); note != "" {
		sections = append(sections, "Note: "+note)
	}
	return strings.Join(sections, "\n\n")
}

func verdictText(verdict string) string {
	switch verdict {
	case VerdictApproved:
		return "approved"
	case VerdictChanges:
		return "changes requested"
	}
	return "none"
}

func renderQuestions(questions []Question, answers []QuestionAnswer) string {
	byID := make(map[string]QuestionAnswer, len(answers))
	for _, ans := range answers {
		byID[ans.ID] = ans
	}
	lines := []string{"Answers:"}
	for _, q := range questions {
		ans := byID[q.ID]
		value := strings.Join(ans.Labels, ", ")
		if other := strings.TrimSpace(ans.Other); other != "" {
			if value != "" {
				value += " / "
			}
			value += "Other: " + other
		}
		if value == "" {
			value = "(no answer)"
		}
		lines = append(lines, fmt.Sprintf("- %s → %s", q.Question, value))
	}
	return strings.Join(lines, "\n")
}

func renderChecklist(items []ChecklistItem, marks []CheckAnswer) string {
	byID := make(map[string]CheckAnswer, len(marks))
	for _, m := range marks {
		byID[m.ID] = m
	}
	counts := map[string]int{}
	steps := make([]string, 0, len(items))
	for _, c := range items {
		m := byID[c.ID]
		label := checkLabel(m.State)
		counts[label]++
		value := label
		if note := strings.TrimSpace(m.Note); note != "" {
			value += ": " + strings.ReplaceAll(note, "\n", "\n  ")
		}
		steps = append(steps, fmt.Sprintf("- %s → %s", c.Text, value))
	}
	header := make([]string, 0, 3)
	for _, state := range []string{StateOK, StateBroken, StateSkipped} {
		header = append(header, fmt.Sprintf("%s %d", checkLabel(state), counts[checkLabel(state)]))
	}
	return strings.Join(append([]string{"Checklist: " + strings.Join(header, ", ")}, steps...), "\n")
}

// checkLabel is the Desktop's label of a check item state; an item with no
// state (a payload item the answer left out) reads as not checked, as the
// Desktop sends it.
func checkLabel(state string) string {
	switch state {
	case StateOK:
		return "Works"
	case StateBroken:
		return "Doesn't work"
	}
	return "Didn't check"
}

// checkCounts is the check's short form: `N ok, M broken, K skipped`.
func checkCounts(marks []CheckAnswer) string {
	counts := map[string]int{}
	for _, m := range marks {
		counts[m.State]++
	}
	return fmt.Sprintf("%d ok, %d broken, %d skipped", counts[StateOK], counts[StateBroken], counts[StateSkipped])
}

func renderComments(comments []Comment) string {
	blocks := make([]string, 0, len(comments))
	for _, c := range comments {
		var lines []string
		if quote := strings.TrimSpace(c.Quote); quote != "" {
			lines = append(lines, indent(quote, "> "))
		}
		if heading := strings.TrimSpace(c.Heading); heading != "" {
			lines = append(lines, "Under: "+heading)
		}
		lines = append(lines, strings.TrimSpace(c.Body))
		blocks = append(blocks, strings.Join(lines, "\n"))
	}
	return "Comments:\n" + strings.Join(blocks, "\n\n")
}

// indent prefixes every line of s.
func indent(s, prefix string) string {
	return prefix + strings.ReplaceAll(s, "\n", "\n"+prefix)
}
