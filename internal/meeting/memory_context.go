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
		name := a.DisplayName
		if name == "" {
			name = a.Email
		}
		if !add("### " + name) {
			break
		}

		node, ok := p.resolveAttendeeEntity(vault, a)
		if !ok {
			add("(no memory entity for this attendee)")
			continue
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
	}

	// len(attendees) > 0 (checked above) and the per-attendee "### name" header
	// always fits the 4 KB cap, so sb is never empty here.
	return strings.TrimRight(sb.String(), "\n")
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
