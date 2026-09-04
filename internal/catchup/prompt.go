package catchup

import (
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// Per-item body caps, in runes (spec §5.3). A longer body is truncated with "…".
const (
	capDigests   = 900
	capStreams   = 600
	capMeetings  = 800
	capDecisions = 300
	capInbox     = 280
	capTracks    = 280
	capTargets   = 200
)

// windowTimeFormat renders the window header in the operator's local time.
const windowTimeFormat = "Mon 2 Jan 15:04"

// gathered is everything the window produced, one list per ref area, plus the
// (area, id) index the ref validator resolves the model's tags against.
type gathered struct {
	Digests, Streams, Meetings, Decisions, Inbox, Tracks, Targets []db.CatchupItem
	byRef                                                         map[refKey]db.CatchupItem
}

// lists returns every item list, in render order.
func (g gathered) lists() [][]db.CatchupItem {
	return [][]db.CatchupItem{g.Digests, g.Streams, g.Meetings, g.Decisions, g.Inbox, g.Tracks, g.Targets}
}

// isEmpty reports whether the window produced nothing to compose from.
func (g gathered) isEmpty() bool {
	for _, l := range g.lists() {
		if len(l) > 0 {
			return false
		}
	}
	return true
}

// index (re)builds byRef from every list, so it always describes exactly what
// the prompt rendered.
func (g *gathered) index() {
	g.byRef = make(map[refKey]db.CatchupItem)
	for _, l := range g.lists() {
		for _, it := range l {
			g.byRef[refKey{area: it.Area, id: it.ID}] = it
		}
	}
}

// promptInput is the non-source half of the compose user message.
type promptInput struct {
	Window     Window
	Profile    string // workspace.secretary_profile
	Prefs      string // LearnedPreferencesBlock output
	Correction string // regen only
}

// buildComposeUserMessage renders the compose user message and returns it with
// the gathered set it actually rendered (indexed by ref). budget <= 0 means
// unlimited; over budget, trailing items are dropped list by list in the fixed
// order streams → tracks → decisions → digests until the message fits or those
// four lists are empty — inbox, targets and meetings are never trimmed, so an
// untrimmable message is returned over budget rather than looping forever.
func buildComposeUserMessage(in promptInput, g gathered, budget int) (string, gathered) {
	for {
		msg := renderCompose(in, g)
		if budget <= 0 || len(msg) <= budget || !dropLastItem(&g) {
			g.index()
			return msg, g
		}
	}
}

// dropLastItem removes the last item of the first non-empty trimmable list,
// reporting false when there is nothing left to drop.
func dropLastItem(g *gathered) bool {
	for _, l := range []*[]db.CatchupItem{&g.Streams, &g.Tracks, &g.Decisions, &g.Digests} {
		if n := len(*l); n > 0 {
			*l = (*l)[:n-1]
			return true
		}
	}
	return false
}

// renderCompose writes the header blocks and every non-empty section.
func renderCompose(in promptInput, g gathered) string {
	var b strings.Builder
	fmt.Fprintf(&b, "WINDOW: %s → %s\n", in.Window.From.Format(windowTimeFormat), in.Window.To.Format(windowTimeFormat))
	profile := strings.TrimSpace(in.Profile)
	if profile == "" {
		profile = "(none)"
	}
	fmt.Fprintf(&b, "OPERATOR PROFILE:\n%s\n", profile)
	if prefs := strings.TrimSpace(in.Prefs); prefs != "" {
		fmt.Fprintf(&b, "\n%s\n", prefs)
	}
	if c := strings.TrimSpace(in.Correction); c != "" {
		fmt.Fprintf(&b, "\nOPERATOR CORRECTION: %s\n", c)
	}
	renderSection(&b, "SLACK DIGESTS", g.Digests, capDigests)
	renderSection(&b, "EMAIL / JIRA STREAMS", g.Streams, capStreams)
	renderSection(&b, "MEETINGS", g.Meetings, capMeetings)
	renderSection(&b, "DECISIONS", g.Decisions, capDecisions)
	renderSection(&b, "FOR YOU — INBOX", g.Inbox, capInbox)
	renderSection(&b, "TRACKS UPDATED", g.Tracks, capTracks)
	renderSection(&b, "TARGETS DUE", g.Targets, capTargets)
	return b.String()
}

// renderSection writes one "=== HEADER (n) ===" block: per item a tagged
// "[area#id] Title — Meta" line (the tail omitted when Meta is empty) followed
// by its body, capped to bodyCap runes and indented two spaces per line. An
// empty section is omitted entirely.
func renderSection(b *strings.Builder, header string, items []db.CatchupItem, bodyCap int) {
	if len(items) == 0 {
		return
	}
	fmt.Fprintf(b, "\n=== %s (%d) ===\n", header, len(items))
	for _, it := range items {
		fmt.Fprintf(b, "[%s#%d] %s", it.Area, it.ID, oneLine(it.Title))
		if meta := oneLine(it.Meta); meta != "" {
			b.WriteString(" — " + meta)
		}
		b.WriteString("\n")
		for _, line := range strings.Split(truncateRunes(it.Body, bodyCap), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			b.WriteString("  " + line + "\n")
		}
	}
}

// truncateRunes caps s at n runes, marking a cut with a trailing "…".
func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// learnSystemPrompt drives the learning interpreter: given a recap topic the
// operator reviewed plus their free-text comment and rating, derive targeted
// learned-rules addressed to whichever pipeline(s) produced the topic's sources.
const learnSystemPrompt = `You are the learning interpreter for a chief-of-staff catch-up review tool.

The operator just reviewed ONE topic (a cross-source cluster of items from a time window) and left a rating (+1 like / -1 dislike) and a free-text comment. The topic's source refs tell you which underlying pipeline produced each item:
- area "digests"     → pipeline "digest"
- area "streams"     → pipeline "digest"   (Gmail/Jira stream digests)
- area "inbox"       → pipeline "inbox"
- area "tracks"      → pipeline "tracks"
- areas "recaps", "transcripts", "decisions", "targets" → no source pipeline; only "catchup" rules apply
A correction about how the recap itself grouped, titled, or phrased things belongs to pipeline "catchup".

Your job is to turn the comment into durable, targeted learned-rules so the right system surfaces things better next time. Be conservative: only derive a rule when the comment expresses a clear, generalizable preference (e.g. "this channel is noise", "always show me anything from Jane"). Vague approval/disapproval with no actionable signal yields no rules.

For each rule produce:
- pipeline: "digest" | "tracks" | "inbox" | "briefing" | "catchup".
- rule_type: "source_mute" (suppress/down-rank) or "source_boost" (surface/up-rank).
- scope_key: build it ONLY from the channel_id / sender_user_id supplied with the relevant ref below — never invent ids. For the "inbox" pipeline use a BARE key, exactly "sender:<sender_user_id>" or "channel:<channel_id>", so it matches how inbox looks rules up. For every other pipeline ("digest"/"tracks"/"briefing"/"catchup") PREFIX the key with the pipeline, e.g. "digest:channel:<channel_id>". If no usable id is supplied for a target, emit no rule for it rather than guessing.
- weight: a float in [-1.0, 1.0]; negative mutes, positive boosts; magnitude = confidence.
- reason: one short sentence grounding the rule in the comment.

Also decide "regenerate": true only when the comment is a presentation correction about THIS recap (wrong title/narrative/priority/grouping) that should be re-rendered now; false when the comment is purely a forward-looking preference.

Respond with ONLY a JSON object, no markdown fences:
{"rules": [{"pipeline": "digest", "rule_type": "source_mute", "scope_key": "digest:channel:Cxxx", "weight": -1.0, "reason": "..."}], "regenerate": false}`

// buildLearnUserMessage renders a reviewed topic (title, narrative, refs with
// their areas and source ids) plus the operator's rating and comment into the
// learn user message.
func buildLearnUserMessage(topic Topic, refs []learnRef, rating int, comment string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "TOPIC: %s\n", topic.Title)
	if strings.TrimSpace(topic.Narrative) != "" {
		fmt.Fprintf(&b, "NARRATIVE: %s\n", oneLine(topic.Narrative))
	}
	fmt.Fprintf(&b, "TOPIC PRIORITY: %s\n", topic.Priority)
	b.WriteString("SOURCE REFS (use the supplied ids to build scope keys):\n")
	if len(refs) == 0 {
		b.WriteString("(none)\n")
	}
	for _, r := range refs {
		b.WriteString("- area=" + r.Area)
		if r.ChannelID != "" {
			b.WriteString(" channel_id=" + r.ChannelID)
		}
		if r.SenderID != "" {
			b.WriteString(" sender_user_id=" + r.SenderID)
		}
		if r.Label != "" {
			b.WriteString(" label=" + r.Label)
		}
		b.WriteString("\n")
	}
	verdict := "dislike"
	if rating > 0 {
		verdict = "like"
	}
	fmt.Fprintf(&b, "\nOPERATOR RATING: %s\n", verdict)
	fmt.Fprintf(&b, "OPERATOR COMMENT: %s\n", strings.TrimSpace(comment))
	return b.String()
}

// learnRef is a recap ref enriched with the source item's real Slack ids, so the
// learning interpreter can form scope keys the consuming pipelines match on.
type learnRef struct {
	Area      string
	ChannelID string
	SenderID  string
	Label     string
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
