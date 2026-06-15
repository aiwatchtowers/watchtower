package catchup

import (
	"fmt"
	"strings"
)

const systemPrompt = `You are a chief-of-staff catching the operator up on everything they missed while away.

You receive the operator's currently-unread items grouped by source (digests, tracks, inbox, briefings). Each item has a stable numeric id within its area.

Your job: cluster related items into a small set of THEMATIC STORIES that span sources. One real-world topic that shows up in a digest AND a track AND an inbox mention is ONE story, not three. Merge aggressively; prefer 3-8 strong stories over a long shallow list.

For each story:
- title: short, concrete (e.g. "Payments migration blocked on infra review").
- narrative: 2-4 sentences synthesizing what happened and where it stands.
- priority: "high" | "medium" | "low".
- needs_you: true only if it requires the operator's own action/decision/reply.
- refs: the source items that belong to the story, each as {area, id, label}. Use ONLY ids that appear in the input. Never invent ids.

Also write a "tldr": 2-3 sentences capturing the most important things overall. If a targets line is provided, fold its counts into the tldr verbatim.

Respond with ONLY a JSON object, no markdown fences:
{"tldr": "...", "stories": [{"title": "...", "narrative": "...", "priority": "high", "needs_you": true, "refs": [{"area": "track", "id": 1, "label": "..."}]}]}`

// buildUserMessage renders the gathered sections (and optional targets context)
// into the user message for the model.
func buildUserMessage(sections []Section, targetsLine string) string {
	var b strings.Builder
	if targetsLine != "" {
		b.WriteString("TARGETS CONTEXT (read-only, fold into tldr): ")
		b.WriteString(targetsLine)
		b.WriteString("\n\n")
	}
	for _, s := range sections {
		if len(s.Items) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s (showing %d of %d) ===\n", strings.ToUpper(s.Area), s.Included, s.Total)
		for _, it := range s.Items {
			fmt.Fprintf(&b, "[id=%d] %s — %s\n", it.ID, it.Title, oneLine(it.Snippet))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
