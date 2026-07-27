package meeting

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// noMemoryContext is the sentinel rendered into the ATTENDEE MEMORY placeholder
// when the gate is off, no vault exists, an open error occurs, or there are no
// attendees. The template instructs the model to ignore attendee memory entirely
// when it sees this text, so the placeholder is always safe to pass as a Sprintf
// arg (arg count stays fixed).
const noMemoryContext = "(no memory context)"

// memoryContextCap bounds the whole ATTENDEE MEMORY block so a large vault page
// cannot dominate the meeting prompt (the Swift Discuss MEMORY-block precedent).
const memoryContextCap = 4096

// maxAttendeeFacts / maxAttendeeBeliefs cap the per-attendee excerpt so the
// block stays a brief, model-mediated aide-mémoire rather than a full dump.
const (
	maxAttendeeFacts   = 5
	maxAttendeeBeliefs = 3
)

// gatherMemoryContext builds the ATTENDEE MEMORY block: per attendee, the
// secretary's entity page excerpt (## What / ## Current first lines + up to five
// ## Facts bullets) plus up to three beliefs whose subject is that entity. It is
// a pure reader of the vault (MEM-14): it never creates a vault
// (OpenExistingVault), never writes, and always returns a string safe to pass as
// a Sprintf arg — the sentinel when the gate is off, no vault exists, or there are
// no attendees. An attendee with no entity yields a clean per-attendee absence
// line, never an error.
//
// The block is framed model-mediated in the template ("notes and beliefs the
// secretary derived from Slack/mail/calendar — model-mediated, not the attendee's
// own words"), never as the attendee's own words.
func (p *Pipeline) gatherMemoryContext(attendees []attendeeEntry) string {
	if !p.cfg.Memory.Surfaces.MeetingPrep || len(attendees) == 0 {
		return noMemoryContext
	}

	vault, err := memory.OpenExistingVault(filepath.Join(p.cfg.WorkspaceDir(), "memory"))
	if err != nil {
		// ErrVaultNotInitialized is the benign "memory never run" case — degrade
		// silently. Any OTHER open failure is logged before degrading, so a real
		// problem is not swallowed as if the vault simply did not exist (P3).
		// meeting.New normalizes a nil logger, so p.logger is always non-nil here.
		if !errors.Is(err, memory.ErrVaultNotInitialized) {
			p.logger.Printf("meeting: opening memory vault for attendee context: %v", err)
		}
		return noMemoryContext
	}

	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		p.logger.Printf("meeting: error listing memory nodes: %v", err)
		return noMemoryContext
	}

	var sb strings.Builder
	add := func(s string) bool {
		if sb.Len()+len(s)+1 > memoryContextCap {
			return false
		}
		sb.WriteString(s)
		sb.WriteString("\n")
		return true
	}

	for _, a := range attendees {
		if !p.renderAttendeeMemory(vault, nodes, a, add) {
			break
		}
	}

	// len(attendees) > 0 (checked above) and the per-attendee "### name" header
	// always fits the 4 KB cap, so sb is never empty here.
	return strings.TrimRight(sb.String(), "\n")
}

// renderAttendeeMemory appends one attendee's memory excerpt (header,
// What/Current lines, facts, beliefs, or a bare absence line when
// unresolved) via add, plus the Slice B Task 10 dark retrieval-compare
// shadow diff. It returns false only when even the "### name" header did not
// fit the cap, signalling gatherMemoryContext to stop walking further
// attendees; a resolved-but-truncated attendee still returns true.
func (p *Pipeline) renderAttendeeMemory(vault *memory.Vault, nodes []db.MemoryNodeRow, a attendeeEntry, add func(string) bool) bool {
	name := a.DisplayName
	if name == "" {
		name = a.Email
	}
	if !add("### " + name) {
		return false
	}

	node, ok := p.resolveAttendeeEntity(vault, a)
	if !ok {
		add("(no memory entity for this attendee)")
		return true
	}

	if what := firstSectionLine(node.Body, "What"); what != "" {
		add("What: " + what)
	}
	if cur := firstSectionLine(node.Body, "Current"); cur != "" {
		add("Current: " + cur)
	}
	facts := memory.SectionBullets(node.Body, "Facts")
	if len(facts) > maxAttendeeFacts {
		facts = facts[:maxAttendeeFacts]
	}
	for _, f := range facts {
		if !add("- " + f) {
			break
		}
	}
	for _, line := range beliefLinesFor(nodes, node.ID) {
		if !add(line) {
			break
		}
	}

	// Slice B Task 10 dark retrieval-compare (memory.retrieve.meeting_prep_compare):
	// runs RetrieveBySubject for this attendee and shadow-diffs it against
	// beliefIDsFor's legacy selection above (same cap). The rendered
	// ATTENDEE MEMORY block is unaffected by the flag in every case.
	if p.cfg.Memory.Retrieve.MeetingPrepCompare {
		legacyIDs := beliefIDsFor(nodes, node.ID)
		if _, err := memory.CompareSubject(p.db, p.db, node.ID, legacyIDs, maxAttendeeBeliefs, meetingPrepShortTermSampleLimit); err != nil {
			p.logger.Printf("meeting: retrieve compare (subject %s): %v", node.ID, err)
		}
	}
	return true
}

// resolveAttendeeEntity resolves an attendee to their person entity via the
// Slack user id, falling back to the lower-cased email (both are person-entity
// aliases via seedPeople/seedGmailSenders). ErrNotFound is an ordinary absence;
// any other resolve error is logged and treated as absence so a prep run never
// fails on memory.
func (p *Pipeline) resolveAttendeeEntity(vault *memory.Vault, a attendeeEntry) (memory.Node, bool) {
	var refs []string
	if a.SlackUserID != "" {
		refs = append(refs, a.SlackUserID)
	}
	if a.Email != "" {
		refs = append(refs, strings.ToLower(a.Email))
	}
	for _, ref := range refs {
		node, err := memory.Resolve(vault, p.db, ref)
		if err == nil {
			return node, true
		}
		if !errors.Is(err, memory.ErrNotFound) {
			p.logger.Printf("meeting: resolving attendee %q in memory: %v", ref, err)
		}
	}
	return memory.Node{}, false
}

// beliefLinesFor renders up to maxAttendeeBeliefs active-or-shaken belief lines
// whose subject is entityID. A shaken belief is rendered as shaken (the honesty
// requirement); retired/tombstoned beliefs are omitted (not live).
func beliefLinesFor(nodes []db.MemoryNodeRow, entityID string) []string {
	var lines []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != entityID {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		title := strings.TrimSpace(n.Title)
		if title == "" {
			title = n.ID
		}
		lines = append(lines, fmt.Sprintf("- belief: %s (confidence %.1f, %s)", title, n.Confidence, n.Status))
		if len(lines) >= maxAttendeeBeliefs {
			break
		}
	}
	return lines
}

// beliefIDsFor returns the same subset+cap beliefLinesFor renders, as bare
// ids — the legacy side of Task 10's retrieval compare. Kept in lockstep
// with beliefLinesFor's filter (type=belief, subject match, active/shaken,
// same maxAttendeeBeliefs cap) by construction: both walk the same nodes
// slice with the same predicate, so the two can never silently drift.
func beliefIDsFor(nodes []db.MemoryNodeRow, entityID string) []string {
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != entityID {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		ids = append(ids, n.ID)
		if len(ids) >= maxAttendeeBeliefs {
			break
		}
	}
	return ids
}

// meetingPrepShortTermSampleLimit bounds CompareSubject's shortTerm episode
// sample — purely additive telemetry with no legacy equivalent to size
// against, so this is just a reasonable exercise cap, not a rendered limit.
const meetingPrepShortTermSampleLimit = 5

// firstSectionLine returns the first non-empty content line under the given
// "## <heading>" section, or "" when the section is absent or empty.
func firstSectionLine(body, heading string) string {
	want := "## " + heading
	in := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			in = trimmed == want
			continue
		}
		if !in || trimmed == "" {
			continue
		}
		return strings.TrimPrefix(trimmed, "- ")
	}
	return ""
}
