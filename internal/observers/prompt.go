package observers

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
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
		instr = DefaultObserverInstruction
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
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return nil, fmt.Errorf("no JSON object found")
	}
	var out aiOutput
	if err := json.Unmarshal([]byte(s[start:end+1]), &out); err != nil {
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
