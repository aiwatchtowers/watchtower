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

// expandSystemPrompt drives the per-theme pass that turns one skeleton into a
// reviewable narrative with priority and a suggested action.
const expandSystemPrompt = `You are a chief-of-staff writing the catch-up entry for ONE theme the operator missed.

You receive the theme's title and the source items that belong to it (digests, tracks, inbox mentions, briefings), each with a short snippet. Write a tight, concrete account of what happened and what (if anything) the operator must do.

Stay strictly within the supplied sources. Do not invent facts, names, or decisions that are not present.

Produce:
- narrative: 2-4 sentences telling the operator what happened and why it matters. Specific, not generic.
- priority: "high" | "medium" | "low".
- needs_you: true only if the operator personally must act or decide; false if it is purely informational.
- suggested_action: one short imperative next step, or "" when none is needed.

If an OPERATOR CORRECTION is present, treat it as authoritative and rewrite accordingly.

Respond with ONLY a JSON object, no markdown fences:
{"narrative": "...", "priority": "medium", "needs_you": false, "suggested_action": "..."}`

// buildExpandUserMessage renders one theme's title + source snippets (and an
// optional operator correction for regen) into the expand user message.
func buildExpandUserMessage(theme db.CatchupTheme, sources []expandSource, comment string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "THEME: %s\n\n", theme.Title)
	b.WriteString("SOURCES:\n")
	if len(sources) == 0 {
		b.WriteString("(no source snippets available)\n")
	}
	for _, s := range sources {
		fmt.Fprintf(&b, "- [%s #%d] %s — %s\n", s.Area, s.ID, s.Title, oneLine(s.Snippet))
	}
	if strings.TrimSpace(comment) != "" {
		fmt.Fprintf(&b, "\nOPERATOR CORRECTION: %s\n", strings.TrimSpace(comment))
	}
	return b.String()
}

// learnSystemPrompt drives the learning interpreter: given a theme the operator
// reviewed plus their free-text comment and rating, derive targeted learned-rules
// addressed to whichever pipeline(s) produced the theme's sources.
const learnSystemPrompt = `You are the learning interpreter for a chief-of-staff catch-up review tool.

The operator just reviewed ONE theme (a cross-source cluster of unread items) and left a rating (+1 like / -1 dislike) and a free-text comment. The theme's source refs tell you which underlying pipeline produced each item:
- area "digests"   → pipeline "digest"
- area "tracks"    → pipeline "tracks"
- area "inbox"     → pipeline "inbox"
- area "briefings" → pipeline "briefing"
A correction about how the theme itself was clustered, titled, or phrased belongs to pipeline "catchup".

Your job is to turn the comment into durable, targeted learned-rules so the right system surfaces things better next time. Be conservative: only derive a rule when the comment expresses a clear, generalizable preference (e.g. "this channel is noise", "always show me anything from Jane"). Vague approval/disapproval with no actionable signal yields no rules.

For each rule produce:
- pipeline: "digest" | "tracks" | "inbox" | "briefing" | "catchup".
- rule_type: "source_mute" (suppress/down-rank) or "source_boost" (surface/up-rank).
- scope_key: a stable, pipeline-prefixed key identifying the target, e.g. "digest:channel:Cxxx", "inbox:sender:Uxxx". Prefix with the pipeline to keep keys unique across pipelines.
- weight: a float in [-1.0, 1.0]; negative mutes, positive boosts; magnitude = confidence.
- reason: one short sentence grounding the rule in the comment.

Also decide "regenerate": true only when the comment is a presentation correction about THIS theme (wrong title/narrative/priority/grouping) that should be re-rendered now; false when the comment is purely a forward-looking preference.

Respond with ONLY a JSON object, no markdown fences:
{"rules": [{"pipeline": "digest", "rule_type": "source_mute", "scope_key": "digest:channel:Cxxx", "weight": -1.0, "reason": "..."}], "regenerate": false}`

// buildLearnUserMessage renders a reviewed theme (title, narrative, refs with
// their areas) plus the operator's rating and comment into the learn user
// message.
func buildLearnUserMessage(theme db.CatchupTheme, refs []db.CatchupRef, rating int, comment string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "THEME: %s\n", theme.Title)
	if strings.TrimSpace(theme.Narrative) != "" {
		fmt.Fprintf(&b, "NARRATIVE: %s\n", oneLine(theme.Narrative))
	}
	fmt.Fprintf(&b, "THEME PRIORITY: %s\n", theme.Priority)
	b.WriteString("SOURCE REFS:\n")
	if len(refs) == 0 {
		b.WriteString("(none)\n")
	}
	for _, r := range refs {
		fmt.Fprintf(&b, "- area=%s id=%d label=%s\n", r.Area, r.ID, r.Label)
	}
	verdict := "dislike"
	if rating > 0 {
		verdict = "like"
	}
	fmt.Fprintf(&b, "\nOPERATOR RATING: %s\n", verdict)
	fmt.Fprintf(&b, "OPERATOR COMMENT: %s\n", strings.TrimSpace(comment))
	return b.String()
}

// expandSource is one resolved source record for a theme's expand call.
type expandSource struct {
	Area    string
	ID      int
	Title   string
	Snippet string
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
