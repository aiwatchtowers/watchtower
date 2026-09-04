// Package catchup builds an on-demand absence recap: one persisted document per
// time window composed from the summaries Watchtower already keeps (channel
// digests, Gmail/Jira stream digests, meeting recaps, the decisions ledger) plus
// the items that arrived for the owner in that window (inbox, tracks, targets).
package catchup

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// Body is the validated, persisted recap (catchup_recaps.body_json).
type Body struct {
	Topics    []Topic        `json:"topics"`
	Decisions []Entry        `json:"decisions"`
	Meetings  []MeetingEntry `json:"meetings"`
	NeedsYou  []NeedEntry    `json:"needs_you"`
}

// Topic is one "what happened" story with its provenance.
type Topic struct {
	Title     string          `json:"title"`
	Narrative string          `json:"narrative"`
	Priority  string          `json:"priority"`
	Refs      []db.CatchupRef `json:"refs"`
}

// Entry is a decision line with provenance.
type Entry struct {
	Text string          `json:"text"`
	Refs []db.CatchupRef `json:"refs"`
}

// MeetingEntry is one meeting that took place in the window.
type MeetingEntry struct {
	Title   string          `json:"title"`
	Summary string          `json:"summary"`
	Refs    []db.CatchupRef `json:"refs"`
}

// NeedEntry is something waiting for the owner personally.
type NeedEntry struct {
	Text string          `json:"text"`
	Kind string          `json:"kind"`
	Refs []db.CatchupRef `json:"refs"`
}

// Coverage records how far the summaries reached and whether the top-up ran
// (catchup_recaps.coverage_json).
type Coverage struct {
	SlackTo    float64 `json:"slack_to"`
	StreamsTo  float64 `json:"streams_to"`
	Meetings   int     `json:"meetings"`
	Topup      string  `json:"topup"` // ok | skipped | failed
	TopupError string  `json:"topup_error,omitempty"`
}

// IsEmpty reports whether the recap has nothing to show.
func (b Body) IsEmpty() bool {
	return len(b.Topics) == 0 && len(b.Decisions) == 0 && len(b.Meetings) == 0 && len(b.NeedsYou) == 0
}

// MarshalJSON guarantees "[]" (never null) for every list so the Swift decoder
// and `catchup show` never meet a null array.
func (b Body) MarshalJSON() ([]byte, error) {
	type alias Body
	a := alias(b)
	if a.Topics == nil {
		a.Topics = []Topic{}
	}
	if a.Decisions == nil {
		a.Decisions = []Entry{}
	}
	if a.Meetings == nil {
		a.Meetings = []MeetingEntry{}
	}
	if a.NeedsYou == nil {
		a.NeedsYou = []NeedEntry{}
	}
	return json.Marshal(a)
}

// --- model output (refs as "area#id" tags) ---

type rawTopic struct {
	Title     string   `json:"title"`
	Narrative string   `json:"narrative"`
	Priority  string   `json:"priority"`
	Refs      []string `json:"refs"`
}
type rawEntry struct {
	Text string   `json:"text"`
	Refs []string `json:"refs"`
}
type rawMeeting struct {
	Title   string   `json:"title"`
	Summary string   `json:"summary"`
	Refs    []string `json:"refs"`
}
type rawNeed struct {
	Text string   `json:"text"`
	Kind string   `json:"kind"`
	Refs []string `json:"refs"`
}
type composeResult struct {
	TLDR      string       `json:"tldr"`
	Topics    []rawTopic   `json:"topics"`
	Decisions []rawEntry   `json:"decisions"`
	Meetings  []rawMeeting `json:"meetings"`
	NeedsYou  []rawNeed    `json:"needs_you"`
}

// refKey indexes gathered items by (area, id).
type refKey struct {
	area string
	id   int
}

// recapAreas is the closed set of ref areas (spec §4).
var recapAreas = map[string]bool{
	"digests": true, "streams": true, "recaps": true, "transcripts": true,
	"decisions": true, "inbox": true, "tracks": true, "targets": true,
}

// parseCompose extracts the compose object, tolerating markdown fences.
func parseCompose(raw string) (composeResult, error) {
	var out composeResult
	if err := json.Unmarshal([]byte(trimToJSONObject(raw)), &out); err != nil {
		return composeResult{}, fmt.Errorf("parsing catchup compose output: %w", err)
	}
	return out, nil
}

// parseRefTag decodes "area#id" (optionally bracketed) into a refKey.
func parseRefTag(s string) (refKey, bool) {
	s = strings.Trim(strings.TrimSpace(s), "[]")
	area, idStr, ok := strings.Cut(s, "#")
	if !ok || !recapAreas[area] {
		return refKey{}, false
	}
	id, err := strconv.Atoi(idStr)
	if err != nil || id <= 0 {
		return refKey{}, false
	}
	return refKey{area: area, id: id}, true
}

// validateBody keeps only refs present in the gathered set, filling labels from
// the gathered item, drops entries left with no valid refs, and normalises the
// enum fields. rejected counts every dropped ref (CATCHUP-04).
func validateBody(res composeResult, known map[refKey]db.CatchupItem) (Body, int) {
	rejected := 0
	resolve := func(tags []string) []db.CatchupRef {
		var refs []db.CatchupRef
		for _, tag := range tags {
			k, ok := parseRefTag(tag)
			if !ok {
				rejected++
				continue
			}
			item, ok := known[k]
			if !ok {
				rejected++
				continue
			}
			refs = append(refs, db.CatchupRef{Area: k.area, ID: k.id, Label: item.Title})
		}
		return refs
	}
	var body Body
	for _, t := range res.Topics {
		if refs := resolve(t.Refs); len(refs) > 0 {
			body.Topics = append(body.Topics, Topic{Title: t.Title, Narrative: t.Narrative, Priority: normalizePriority(t.Priority, "medium"), Refs: refs})
		}
	}
	for _, d := range res.Decisions {
		if refs := resolve(d.Refs); len(refs) > 0 {
			body.Decisions = append(body.Decisions, Entry{Text: d.Text, Refs: refs})
		}
	}
	for _, m := range res.Meetings {
		if refs := resolve(m.Refs); len(refs) > 0 {
			body.Meetings = append(body.Meetings, MeetingEntry{Title: m.Title, Summary: m.Summary, Refs: refs})
		}
	}
	for _, n := range res.NeedsYou {
		if refs := resolve(n.Refs); len(refs) > 0 {
			body.NeedsYou = append(body.NeedsYou, NeedEntry{Text: n.Text, Kind: normalizeKind(n.Kind), Refs: refs})
		}
	}
	return body, rejected
}

func normalizePriority(p, fallback string) string {
	switch p {
	case "high", "medium", "low":
		return p
	}
	return fallback
}

func normalizeKind(k string) string {
	switch k {
	case "mention", "dm", "email", "track", "target_due":
		return k
	}
	return "mention"
}

// trimToJSONObject narrows a model response to the outermost {...}.
func trimToJSONObject(raw string) string {
	s := raw
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j >= i {
			s = s[i : j+1]
		}
	}
	return s
}

// learnResult is the shape the learning interpreter returns: the derived rules
// addressed to specific pipelines plus whether this theme should be regenerated.
type learnResult struct {
	Rules      []learnRule `json:"rules"`
	Regenerate bool        `json:"regenerate"`
}

// learnRule is one targeted learned-rule derived from operator feedback.
type learnRule struct {
	Pipeline string  `json:"pipeline"`
	RuleType string  `json:"rule_type"`
	ScopeKey string  `json:"scope_key"`
	Weight   float64 `json:"weight"`
	Reason   string  `json:"reason"`
}

// parseLearn extracts the learning-interpreter object, tolerating markdown fences.
func parseLearn(raw string) (learnResult, error) {
	var out learnResult
	s := trimToJSONObject(raw)
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return learnResult{}, fmt.Errorf("parsing catchup learn output: %w", err)
	}
	return out, nil
}
