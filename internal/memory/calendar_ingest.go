package memory

// This file is the mechanical calendar past-event → episode builder (behind
// memory.sources.calendar). Unlike the Slack/Gmail extractors it makes NO AI
// call (resolved ambiguity #1): one ENDED calendar_events row becomes at most
// one episode built straight from the structured row (title, time, organizer,
// attendees, location, description), and — where a meeting_recaps row exists —
// that already-AI-produced recap's summary/decisions/actions fold into
// Story/Outcome (reused, never re-synthesized). It runs as a mechanical Run step
// (3b), after SeedEntities (participants + series seeded first) and before Slack
// extraction.
//
// Idempotency is alias-keyed (calevent:<event_id>, the gmailthread: precedent):
// a re-scan UPDATEs the episode in place, and a content-equality check makes an
// unchanged re-scan a no-op (no empty git commit — the interaction-ingest dirty
// precedent). Because the calendar sync retains only ~24h of past events, the
// loader re-scans a bounded lookback overlap so a recap/edit landing after the
// watermark passed a still-present event refreshes its episode. Its own
// watermark: memory_calendar_last_extracted_ts (MEM-04-adapted).

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// calendarEventAliasPrefix marks an episode's stable per-event identity alias
// ("calevent:<event_id>") — the idempotency key that makes re-processing an
// event (a re-sync, an edit, a recap landing after the meeting) UPDATE the
// existing episode instead of minting a duplicate.
const calendarEventAliasPrefix = "calevent:"

func calendarEventAlias(eventID string) string { return calendarEventAliasPrefix + eventID }

// calendarReprocessLookbackDays is the bounded re-scan overlap (resolved
// ambiguity #3): each run re-scans ended events back this many days below the
// watermark so a late recap/edit on a still-present event refreshes its episode
// via the calevent: alias. The calendar sync keeps only ~24h of past events, so
// two days comfortably covers the retention window. A code const, like the
// retention/belief math constants.
const calendarReprocessLookbackDays = 2

// calRecap is the local projection of a meeting_recaps recap_json (mirrors
// internal/meeting.RecapResult) — memory reuses the recap mechanically without
// importing the meeting package.
type calRecap struct {
	Summary       string   `json:"summary"`
	KeyDecisions  []string `json:"key_decisions"`
	ActionItems   []string `json:"action_items"`
	OpenQuestions []string `json:"open_questions"`
}

// calAttendee is the subset of a calendar_events.attendees entry the builder
// reads: the label (display name / email) and the resolution keys (Slack user
// id when the sync resolved one, else the email).
type calAttendee struct {
	Email       string `json:"email"`
	DisplayName string `json:"display_name"`
	SlackUserID string `json:"slack_user_id"`
}

// runCalendarIngest is Run step 3b (behind memory.sources.calendar): the
// mechanical, no-AI fold of ended calendar events into episode nodes. It loads
// ended events above the calendar watermark (bounded-lookback re-scan), builds
// their episodes in one vault commit, advances the watermark to the newest
// committed end-time (MEM-04-adapted, frozen on any build/commit/lookup error),
// and records one pipeline_steps row at stepOffset+1. A build error is logged
// and never fatal to the run (source isolation). Returns the number of step rows
// recorded (0 when there was nothing to do, else 1).
func (p *Pipeline) runCalendarIngest(runID int64, stepOffset int, stats *RunStats) (int, error) {
	wm, err := p.db.MemoryCalendarWatermark()
	if err != nil {
		// Pre-build failures get the same accounting as build failures: a step
		// row + counter, so a top-level calendar read outage is as observable
		// as an extraction error (review 2026-07-16, slice-2 minor #1).
		stats.CalendarEventsFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "calendar-ingest", "error", nil, time.Now())
		return 1, err
	}
	events, err := p.db.ListCalendarEventsForExtract(wm, calendarReprocessLookbackDays, orDefault(p.cfg.MaxChunkMessages, 2000))
	if err != nil {
		stats.CalendarEventsFailed++
		step := stepOffset + 1
		p.recordSemanticStep(runID, &step, "calendar-ingest", "error", nil, time.Now())
		return 1, err
	}
	if len(events) == 0 {
		return 0, nil
	}

	// cal: is the only scheme a calendar episode can carry, so the builder
	// validates through a cal-only scoped registry (MEM-12 scheme scoping).
	calReg := newProvenanceRegistry(calResolver{p.db})

	start := time.Now()
	built, failed, maxEnd, berr := p.buildCalendarEpisodes(runID, calReg, events)
	if berr != nil {
		// A commit/lookup failure freezes the whole step: the watermark stays and
		// every event re-scans next run (MEM-04-adapted, batch-isolation spirit).
		stats.CalendarEventsFailed += len(events)
		p.logf("memory: calendar ingest: %v", berr)
	} else {
		stats.CalendarEpisodes += built
		stats.CalendarEventsFailed += failed
		if maxEnd > int64(wm) {
			if serr := p.db.SetMemoryCalendarWatermark(float64(maxEnd)); serr != nil {
				p.logf("memory: calendar ingest: set watermark: %v", serr)
			}
		}
	}
	step := stepOffset + 1
	p.recordSemanticStep(runID, &step, "calendar-ingest", stepStatus(berr), nil, start)
	return 1, nil
}

// buildCalendarEpisodes turns ended events into episode nodes (plus entity
// back-links) committed as ONE vault commit, keyed by their calevent:<event_id>
// alias so a re-scan updates in place. It returns the number of episodes
// created-or-refreshed (built), the number dropped for an unresolved cal: ref
// (failed), the newest end-time unix among processed events (the watermark
// bound), and an error that freezes the whole step (a LookupMemoryAlias/read/
// recap/commit failure — the alias is the idempotency key, so guessing on a
// lookup error could mint the very duplicate it exists to prevent). A cal: ref
// that positively does not resolve (an event swept from the DB between load and
// validate, MEM-01) drops the episode and is counted, never a freeze.
func (p *Pipeline) buildCalendarEpisodes(runID int64, calReg *provenanceRegistry, events []db.CalendarExtractEvent) (built, failed int, maxEnd int64, err error) {
	// byID/order/dirty accumulate every node (episodes + back-linked entities);
	// only the dirty ones are committed, so an unchanged re-scan commits nothing.
	byID := map[string]*Node{}
	var order []string
	dirty := map[string]bool{}
	add := func(n *Node) {
		if _, ok := byID[n.ID]; !ok {
			byID[n.ID] = n
			order = append(order, n.ID)
		}
	}

	for _, ev := range events {
		// maxEnd lifts BEFORE ref validation on purpose: an event whose cal:
		// ref fails to resolve was swept by the sync's retention delete and is
		// permanently gone from calendar_events — it can never be built later,
		// so advancing the watermark past it loses nothing (unlike MEM-04's
		// message freeze, where the raw row survives for a retry).
		if ev.EndUnix > maxEnd {
			maxEnd = ev.EndUnix
		}
		ref := episodeRef{ChannelID: calRefPrefix + ev.ID, TS: strconv.FormatInt(ev.StartUnix, 10)}

		// MEM-01/MEM-12: validate the cal: ref through the cal-only registry. A
		// lookup error freezes the step; a positive non-resolution drops the event.
		ok, registered, verr := calReg.Validate(ref)
		if verr != nil {
			return 0, 0, 0, fmt.Errorf("memory: calendar ingest: validate %s: %w", ref.ChannelID, verr)
		}
		if !registered || !ok {
			failed++
			p.logf("memory: calendar ingest: event %s ref unresolved — episode discarded (MEM-01)", ev.ID)
			continue
		}

		recap, rerr := p.db.GetMeetingRecap(ev.ID)
		if rerr != nil {
			return 0, 0, 0, fmt.Errorf("memory: calendar ingest: recap %s: %w", ev.ID, rerr)
		}

		attendees := parseCalAttendees(ev.Attendees)
		labels := attendeeLabels(attendees)
		title := firstNonEmpty(strings.Join(strings.Fields(ev.Title), " "), "(untitled event)")
		body := calendarEpisodeBody(title, labels, calendarStory(ev, labels, recap), calendarOutcome(recap), ref)
		alias := calendarEventAlias(ev.ID)

		epNode, changed, berr := p.calendarEpisodeNode(alias, title, body)
		if berr != nil {
			return 0, 0, 0, berr
		}
		add(&epNode)
		if changed {
			dirty[epNode.ID] = true
			built++
		}

		// Entity back-links: each attendee (by Slack user id when present, else
		// email) plus, for a recurring instance, its series entity.
		link := "- [[" + epNode.ID + "|" + linkLabel(title) + "]]\n"
		refs := attendeeEntityRefs(attendees)
		if ev.IsRecurring {
			if series := parseRecurringEventID(ev.RawJSON); series != "" {
				refs = append(refs, calendarSeriesAliasPrefix+series)
			}
		}
		for _, entRef := range refs {
			if lerr := linkEntity(p, byID, &order, dirty, entRef, link); lerr != nil {
				return 0, 0, 0, lerr
			}
		}
	}

	if lerr := p.commitCalendarNodes(runID, byID, order, dirty); lerr != nil {
		return 0, 0, 0, lerr
	}
	return built, failed, maxEnd, nil
}

// linkEntity appends the episode back-link to the entity that entRef resolves
// to, accumulating into byID so several events linking one entity append to the
// same in-memory node. A not-found entity (an attendee memory holds no entity
// for) is a clean skip; a genuine resolve error freezes the step.
func linkEntity(p *Pipeline, byID map[string]*Node, order *[]string, dirty map[string]bool, entRef, link string) error {
	en, rerr := Resolve(p.vault, p.db, entRef)
	if rerr != nil {
		if errors.Is(rerr, ErrNotFound) {
			return nil // no entity for this participant/series — skipped
		}
		return fmt.Errorf("memory: calendar ingest: resolve %s: %w", entRef, rerr)
	}
	if en.Type != "entity" || en.Status != "active" {
		return nil
	}
	np, ok := byID[en.ID]
	if !ok {
		nn := en
		byID[en.ID] = &nn
		*order = append(*order, en.ID)
		np = &nn
	}
	if nb := appendToLinks(np.Body, link); nb != np.Body {
		np.Body = nb
		dirty[en.ID] = true
	}
	return nil
}

// commitCalendarNodes writes the dirty nodes as one vault commit + index mirror.
// An all-unchanged run commits nothing (no empty git commit). A commit failure
// propagates (freezing the step); an index-mirror error is non-fatal (reconcile
// self-heals).
func (p *Pipeline) commitCalendarNodes(runID int64, byID map[string]*Node, order []string, dirty map[string]bool) error {
	var nodes []Node
	var ids []string
	for _, id := range order {
		if dirty[id] {
			nodes = append(nodes, *byID[id])
			ids = append(ids, id)
		}
	}
	if len(nodes) == 0 {
		return nil
	}
	msg := CommitMsg{
		Op:      "calendar",
		Summary: fmt.Sprintf("%d calendar episode(s)", len(ids)),
		Cause:   fmt.Sprintf("run:%d", runID),
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, now); err != nil {
			p.logf("memory: index %s after calendar ingest: %v", n.ID, err)
		}
	}
	return nil
}

// calendarEpisodeNode returns the episode node for one event: a fresh node when
// the calevent:<event_id> alias has none, or the existing node with Title/Body
// refreshed when it already resolves (the update path). changed reports whether
// the node is new or its body/title differs from disk (the content-equality
// check that keeps an unchanged re-scan a no-op). A LookupMemoryAlias error (not
// a clean miss) fails the step — the alias is the idempotency key.
func (p *Pipeline) calendarEpisodeNode(alias, title, body string) (n Node, changed bool, err error) {
	existingID, lerr := p.db.LookupMemoryAlias(alias)
	switch {
	case lerr == nil:
		existing, rerr := p.vault.ReadNode(existingID)
		if rerr != nil {
			return Node{}, false, fmt.Errorf("memory: calendar ingest: read %s for %q: %w", existingID, alias, rerr)
		}
		if existing.Title == title && existing.Body == body {
			return existing, false, nil // unchanged — no commit
		}
		existing.Title = title
		existing.Body = body
		existing.Aliases = ensureAlias(existing.Aliases, alias)
		return existing, true, nil
	case errors.Is(lerr, sql.ErrNoRows):
		return Node{
			ID:      NewID("episode"),
			Type:    "episode",
			Tier:    "short",
			Status:  "active",
			Title:   title,
			Aliases: []string{alias},
			Body:    body,
		}, true, nil
	default:
		return Node{}, false, fmt.Errorf("memory: calendar ingest: alias lookup %q: %w", alias, lerr)
	}
}

// parseCalAttendees parses the calendar_events.attendees JSON array, tolerating
// a malformed/empty value as no attendees (a mechanical builder never fails on
// one bad row — the defensive-skip precedent).
func parseCalAttendees(raw string) []calAttendee {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []calAttendee
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil
	}
	return out
}

// attendeeLabels renders each attendee's display label (display name, else
// email) in order, dropping empties — the Participants line of the episode.
func attendeeLabels(atts []calAttendee) []string {
	var out []string
	for _, a := range atts {
		if label := firstNonEmpty(strings.TrimSpace(a.DisplayName), strings.TrimSpace(a.Email)); label != "" {
			out = append(out, label)
		}
	}
	return out
}

// attendeeEntityRefs returns the resolution key for each attendee — the Slack
// user id when the sync resolved one, else the email — for entity back-linking.
func attendeeEntityRefs(atts []calAttendee) []string {
	var out []string
	for _, a := range atts {
		if ref := firstNonEmpty(strings.TrimSpace(a.SlackUserID), strings.TrimSpace(a.Email)); ref != "" {
			out = append(out, ref)
		}
	}
	return out
}

// calendarStory renders the mechanical Story: a metadata line (time, organizer,
// participants, location) plus the trimmed description and, where a recap
// exists, its summary (reused, never re-synthesized).
func calendarStory(ev db.CalendarExtractEvent, labels []string, recap *db.MeetingRecap) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Met %s.", calendarTimeRange(ev))
	if org := strings.TrimSpace(ev.OrganizerEmail); org != "" {
		fmt.Fprintf(&b, " Organized by %s.", org)
	}
	if len(labels) > 0 {
		fmt.Fprintf(&b, " Participants: %s.", strings.Join(labels, ", "))
	}
	if loc := strings.TrimSpace(ev.Location); loc != "" {
		fmt.Fprintf(&b, " Location: %s.", loc)
	}
	if desc := oneLine(ev.Description); desc != "" {
		b.WriteString("\n" + desc)
	}
	if r, ok := parseCalRecap(recap); ok && strings.TrimSpace(r.Summary) != "" {
		b.WriteString("\n" + oneLine(r.Summary))
	}
	return b.String()
}

// calendarTimeRange renders "YYYY-MM-DD HH:MM–HH:MM UTC" from the event's start
// and end unix seconds — a deterministic time label for the Story.
func calendarTimeRange(ev db.CalendarExtractEvent) string {
	start := time.Unix(ev.StartUnix, 0).UTC()
	end := time.Unix(ev.EndUnix, 0).UTC()
	return fmt.Sprintf("%s %s–%s UTC", start.Format("2006-01-02"), start.Format("15:04"), end.Format("15:04"))
}

// calendarOutcome renders the recap's decisions/actions/open questions as
// Outcome bullets (the recap is already an AI product of the meeting pipeline).
// No recap → an empty Outcome (a meeting with no notes is still a real episode).
func calendarOutcome(recap *db.MeetingRecap) string {
	r, ok := parseCalRecap(recap)
	if !ok {
		return ""
	}
	var lines []string
	for _, d := range r.KeyDecisions {
		if d = strings.TrimSpace(d); d != "" {
			lines = append(lines, "- Decision: "+oneLine(d))
		}
	}
	for _, a := range r.ActionItems {
		if a = strings.TrimSpace(a); a != "" {
			lines = append(lines, "- Action: "+oneLine(a))
		}
	}
	for _, q := range r.OpenQuestions {
		if q = strings.TrimSpace(q); q != "" {
			lines = append(lines, "- Open question: "+oneLine(q))
		}
	}
	return strings.Join(lines, "\n")
}

// parseCalRecap decodes a meeting_recaps recap_json. A nil recap or malformed
// JSON yields ok=false (a metadata-only episode).
func parseCalRecap(recap *db.MeetingRecap) (calRecap, bool) {
	if recap == nil {
		return calRecap{}, false
	}
	var r calRecap
	if err := json.Unmarshal([]byte(recap.RecapJSON), &r); err != nil {
		return calRecap{}, false
	}
	return r, true
}

// calendarEpisodeBody renders the deterministic episode body (H1, Participants,
// Story, Outcome, single cal: Provenance ref) — deterministic so the
// content-equality check can detect an unchanged re-scan.
func calendarEpisodeBody(title string, labels []string, story, outcome string, ref episodeRef) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", title)
	if len(labels) > 0 {
		fmt.Fprintf(&b, "Participants: %s\n\n", strings.Join(labels, ", "))
	}
	b.WriteString("## Story\n")
	if story != "" {
		b.WriteString(story + "\n")
	}
	b.WriteString("\n## Outcome\n")
	if outcome != "" {
		b.WriteString(outcome + "\n")
	}
	b.WriteString("\n## Provenance\n")
	fmt.Fprintf(&b, "- %s %s\n", ref.ChannelID, ref.TS)
	return b.String()
}
