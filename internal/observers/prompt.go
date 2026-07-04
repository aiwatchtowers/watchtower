package observers

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// aiEvent mirrors one event in the observer AI output.
type aiEvent struct {
	Summary        string          `json:"summary"`
	Detail         string          `json:"detail"`
	SourceType     string          `json:"source_type"`
	SourceID       string          `json:"source_id"`
	SourceRefs     []string        `json:"source_refs"`
	Decision       json.RawMessage `json:"decision"`
	ProposedAction json.RawMessage `json:"proposed_action"`
}

type aiOutput struct {
	Events []aiEvent `json:"events"`
}

// buildObserverPrompt renders the watch instruction, the target context, and the
// recent cross-source activity into the user message.
func buildObserverPrompt(o db.Observer, target *db.Target, act db.ObserverActivity) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Today: %s\n\n", time.Now().Format("2006-01-02"))

	b.WriteString("WATCH INSTRUCTION:\n")
	instr := strings.TrimSpace(o.Instruction)
	if instr == "" {
		instr = "Track updates relevant to this target."
	}
	b.WriteString(instr + "\n\n")

	b.WriteString("TARGET:\n")
	fmt.Fprintf(&b, "- text: %s\n", target.Text)
	if target.Intent != "" {
		fmt.Fprintf(&b, "- why: %s\n", target.Intent)
	}
	fmt.Fprintf(&b, "- status: %s | priority: %s | ownership: %s\n", target.Status, target.Priority, target.Ownership)
	if target.DueDate != "" {
		fmt.Fprintf(&b, "- due: %s\n", target.DueDate)
	}
	b.WriteString("\nRECENT ACTIVITY:\n")

	if len(act.Digests) == 0 && len(act.Tracks) == 0 && len(act.Inbox) == 0 {
		b.WriteString("(none)\n")
		return b.String()
	}
	for _, dgt := range act.Digests {
		fmt.Fprintf(&b, "- [digest id=%d ch=%s] %s\n", dgt.ID, dgt.ChannelID, truncate(dgt.Summary, 400))
		if dgt.Decisions != "" && dgt.Decisions != "[]" {
			fmt.Fprintf(&b, "    decisions: %s\n", truncate(dgt.Decisions, 400))
		}
	}
	for _, tr := range act.Tracks {
		fmt.Fprintf(&b, "- [track id=%d] %s — %s\n", tr.ID, tr.Text, truncate(tr.Context, 240))
	}
	for _, in := range act.Inbox {
		fmt.Fprintf(&b, "- [inbox id=%d %s] %s\n", in.ID, in.TriggerType, truncate(in.Snippet, 240))
	}
	return b.String()
}

// titleRef is one shortlisted activity item carried from stage 1 to stage 2.
type titleRef struct {
	Kind string `json:"kind"`
	ID   int    `json:"id"`
}

type shortlistOutput struct {
	Refs []titleRef `json:"refs"`
}

// buildShortlistPrompt renders the watch instruction, target, selection cap, and
// a numbered list of activity TITLES for the cheap stage-1 relevance filter.
func buildShortlistPrompt(o db.Observer, target *db.Target, titles []db.ActivityTitle, limit int) string {
	var b strings.Builder
	b.WriteString("WATCH INSTRUCTION:\n")
	instr := strings.TrimSpace(o.Instruction)
	if instr == "" {
		instr = "Track updates relevant to this target."
	}
	b.WriteString(instr + "\n\n")

	b.WriteString("TARGET:\n")
	fmt.Fprintf(&b, "- text: %s\n", target.Text)
	if target.Intent != "" {
		fmt.Fprintf(&b, "- why: %s\n", target.Intent)
	}
	fmt.Fprintf(&b, "\nSelect at most %d items.\n\n", limit)

	b.WriteString("ACTIVITY TITLES:\n")
	for _, t := range titles {
		fmt.Fprintf(&b, "- [%s id=%d] %s\n", t.Kind, t.ID, truncate(t.Title, 160))
	}
	return b.String()
}

// parseShortlistOutput extracts the {refs:[{kind,id}]} array from a raw AI
// response, tolerating markdown fences and surrounding prose.
func parseShortlistOutput(raw string) ([]titleRef, error) {
	obj, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return nil, err
	}
	var out shortlistOutput
	if err := json.Unmarshal([]byte(obj), &out); err != nil {
		return nil, err
	}
	return out.Refs, nil
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// parseObserverOutput extracts the events array from a raw AI response,
// tolerating markdown fences and surrounding prose. A missing/empty array is
// not an error.
func parseObserverOutput(raw string) ([]aiEvent, error) {
	obj, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return nil, err
	}
	var out aiOutput
	if err := json.Unmarshal([]byte(obj), &out); err != nil {
		return nil, err
	}
	return out.Events, nil
}

// rawJSONOrEmpty returns the compacted JSON object string if m is a non-empty
// JSON object, else "". Used to drop null/empty decision/proposed_action.
func rawJSONOrEmpty(m json.RawMessage) string {
	t := strings.TrimSpace(string(m))
	if t == "" || t == "null" || t == "{}" {
		return ""
	}
	var probe map[string]any
	if err := json.Unmarshal(m, &probe); err != nil || len(probe) == 0 {
		return ""
	}
	return t
}

// ComposeResult is the AI-drafted observer name + watch instruction.
type ComposeResult struct {
	Name        string `json:"name"`
	Instruction string `json:"instruction"`
}

// buildComposePrompt renders the target context + the operator's free-text
// request into the user message for the observer.compose prompt.
func buildComposePrompt(target *db.Target, input string) string {
	var b strings.Builder
	b.WriteString("TARGET:\n")
	fmt.Fprintf(&b, "- text: %s\n", target.Text)
	if target.Intent != "" {
		fmt.Fprintf(&b, "- why: %s\n", target.Intent)
	}
	b.WriteString("\nUSER REQUEST (what to watch for):\n")
	b.WriteString(strings.TrimSpace(input) + "\n")
	return b.String()
}

// parseComposeOutput extracts the {name, instruction} object from a raw AI
// response, tolerating markdown fences and surrounding prose. A blank name
// defaults to "Observer"; a blank instruction is an error.
func parseComposeOutput(raw string) (ComposeResult, error) {
	obj, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return ComposeResult{}, err
	}
	var r ComposeResult
	if err := json.Unmarshal([]byte(obj), &r); err != nil {
		return ComposeResult{}, err
	}
	r.Name = strings.TrimSpace(r.Name)
	r.Instruction = strings.TrimSpace(r.Instruction)
	if r.Instruction == "" {
		return ComposeResult{}, fmt.Errorf("compose returned empty instruction")
	}
	if r.Name == "" {
		r.Name = "Observer"
	}
	return r, nil
}

// encodeRefs marshals source refs to a JSON array string, never "".
func encodeRefs(refs []string) string {
	if len(refs) == 0 {
		return "[]"
	}
	b, err := json.Marshal(refs)
	if err != nil {
		return "[]"
	}
	return string(b)
}
