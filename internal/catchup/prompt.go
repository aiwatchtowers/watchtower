package catchup

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// outlineSystemPrompt drives the cheap clustering pass that produces theme
// skeletons (no narrative yet — that is the per-theme expand pass).
const outlineSystemPrompt = `You are a chief-of-staff catching the operator up on everything they missed while away.

You receive the operator's currently-unread items grouped by source (digests, tracks, inbox, briefings). Each item has a stable numeric id within its area.

Your job: cluster related items into a small set of NON-OVERLAPPING THEMES that span sources. One real-world topic that shows up in a digest AND a track AND an inbox mention is ONE theme, not three. Merge aggressively; prefer 3-8 strong themes over a long shallow list. Every theme must reference at least one provided item; do not leave items unclustered if they belong somewhere.

Rank themes by importance (most important first).

For each theme produce ONLY a skeleton (the narrative is written later):
- title: short, concrete (e.g. "Payments migration blocked on infra review").
- priority: "high" | "medium" | "low".
- refs: the source items that belong to the theme, each as {area, id, label}. Use ONLY ids that appear in the input. Never invent ids. label is a short human-readable name for the item.

Respond with ONLY a JSON object, no markdown fences:
{"themes": [{"title": "...", "priority": "high", "refs": [{"area": "tracks", "id": 1, "label": "..."}]}]}`

// buildOutlineUserMessage renders the gathered unread items (and optional
// targets context) into the outline user message.
func buildOutlineUserMessage(sections []gatheredSection, targetsLine string) string {
	var b strings.Builder
	if targetsLine != "" {
		b.WriteString("TARGETS CONTEXT (read-only): ")
		b.WriteString(targetsLine)
		b.WriteString("\n\n")
	}
	for _, s := range sections {
		if len(s.items) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s (showing %d of %d) ===\n", strings.ToUpper(s.area), len(s.items), s.total)
		for _, it := range s.items {
			fmt.Fprintf(&b, "[id=%d] %s — %s\n", it.ID, it.Title, oneLine(it.Snippet))
		}
		b.WriteString("\n")
	}
	return b.String()
}

// refLabel builds a fallback label for a source item when the model omits one.
func refLabel(area string, it db.UnreadItem) string {
	if it.Title != "" {
		return it.Title
	}
	return fmt.Sprintf("%s #%d", area, it.ID)
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
