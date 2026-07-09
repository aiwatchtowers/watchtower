package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// maxTriagePerCall bounds how many candidates are sent to the AI in one
// Generate call; the full stream scan is chunked into calls of this size.
const maxTriagePerCall = 150

// triageVerdict is one AI verdict on a single candidate.
type triageVerdict struct {
	Key      string `json:"key"`      // "item:<id>" or "msg:<channel_id>:<ts>"
	Tier     string `json:"tier"`     // action|awareness|ignore
	Priority string `json:"priority"` // high|medium|low
	Reason   string `json:"reason"`
}

// triageResult is the structured AI response for a triage chunk.
type triageResult struct {
	Verdicts []triageVerdict `json:"verdicts"`
}

// triageOutcome summarizes what a runTriage call did.
type triageOutcome struct {
	Created        int     // stream items created
	MaxProcessedTS float64 // highest ts_unix of a triaged stream candidate (0 if none)
	Capped         bool    // stream scan hit the per-cycle cap
}

// triageCandidate is one line the AI judges: either an existing trigger item
// or a raw stream message.
type triageCandidate struct {
	key    string
	line   string             // formatted prompt line
	item   *db.InboxItem      // set for trigger items
	stream *db.InboxCandidate // set for stream messages
}

// runTriage scans everything that happened since the last cycle — the
// already-detected trigger items (mentions/DMs/Jira/Calendar/...) plus a
// full scan of ordinary channel traffic — and asks the AI to classify each
// into action/awareness/ignore. Trigger items may only be demoted
// (actionable→ambient); stream messages become new inbox items when the
// verdict is action or awareness. See INBOX-01 in docs/inventory/inbox-pulse.md.
//
// sinceTS is the caller's already lookback-floored watermark (Run floors a
// fresh/zero watermark to now-lookbackDays before calling in, so a fresh
// install triages the recent window instead of the entire backfilled
// history — see docs/inventory/inbox-pulse.md).
func (p *Pipeline) runTriage(ctx context.Context, currentUserID string, newItems []db.InboxItem, sinceTS float64) (triageOutcome, error) {
	var out triageOutcome

	maxStream := p.cfg.Inbox.MaxTriageMessages
	streamCands, err := p.db.ListStreamCandidatesSince(currentUserID, sinceTS, maxStream)
	if err != nil {
		return out, fmt.Errorf("listing stream candidates: %w", err)
	}
	out.Capped = len(streamCands) == maxStream

	mutes := loadMuteScopes(p.db)
	cands := make([]triageCandidate, 0, len(newItems)+len(streamCands))
	for i := range newItems {
		it := &newItems[i]
		// Resolve the sender to a display name; UserNameByID falls back to the
		// raw ID on a miss (correct for non-Slack senders like Jira issue keys).
		// Feeding raw IDs makes the AI echo them into reasons and cards.
		sender, _ := p.db.UserNameByID(it.SenderUserID)
		cands = append(cands, triageCandidate{
			key:  fmt.Sprintf("item:%d", it.ID),
			line: fmt.Sprintf("[TRIGGER] key=item:%d type=%s from=%s channel=%s :: %s", it.ID, it.TriggerType, sender, it.ChannelID, it.Snippet),
			item: it,
		})
	}
	// Muted candidates are dropped before the AI sees them, but their ts may
	// only advance the watermark once every unmuted stream candidate BELOW it
	// has been successfully triaged (INBOX-09: the watermark advances only
	// over what was actually processed). Collect them (input is ts ASC, so
	// the slice stays sorted) and fold them in on return, bounded by the
	// first failure point.
	var mutedTS []float64
	for i := range streamCands {
		c := &streamCands[i]
		if mutes["sender:"+c.SenderUserID] || mutes["channel:"+c.ChannelID] {
			mutedTS = append(mutedTS, c.TSUnix)
			continue
		}
		sender, _ := p.db.UserNameByID(c.SenderUserID)
		cands = append(cands, triageCandidate{
			key:    fmt.Sprintf("msg:%s:%s", c.ChannelID, c.MessageTS),
			line:   fmt.Sprintf("key=msg:%s:%s from=%s channel=%s :: %s", c.ChannelID, c.MessageTS, sender, c.ChannelID, enrichSnippet(c.Text, p.db)),
			stream: c,
		})
	}
	if len(cands) == 0 {
		foldMutedTS(&out, mutedTS, math.MaxFloat64)
		return out, nil
	}

	brief := buildSecretaryBrief(p.db, currentUserID, time.Now())
	tmpl, _ := p.getPrompt(prompts.InboxTriage)

	for start := 0; start < len(cands); start += maxTriagePerCall {
		end := min(start+maxTriagePerCall, len(cands))
		chunk := cands[start:end]
		if err := p.triageChunk(ctx, brief, tmpl, chunk, &out); err != nil {
			// The failing chunk and everything after it were NOT triaged:
			// muted ts values at or beyond the first untriaged stream
			// candidate must not advance the watermark.
			foldMutedTS(&out, mutedTS, untriagedStreamFloor(cands[start:]))
			return out, err // caller freezes/partially advances the watermark at out.MaxProcessedTS
		}
	}
	foldMutedTS(&out, mutedTS, math.MaxFloat64)
	return out, nil
}

// untriagedStreamFloor returns the smallest ts_unix among the stream
// candidates in remaining (the failed chunk plus every chunk after it), or
// math.MaxFloat64 if none. Candidates are ordered trigger-items-first then
// stream ts ASC, so the first stream entry is the floor.
func untriagedStreamFloor(remaining []triageCandidate) float64 {
	for _, c := range remaining {
		if c.stream != nil {
			return c.stream.TSUnix
		}
	}
	return math.MaxFloat64
}

// foldMutedTS raises out.MaxProcessedTS over muted candidate timestamps, but
// only those strictly below failedFloor (the first untriaged stream ts).
// mutedTS is sorted ascending; the fold only ever raises, never lowers.
func foldMutedTS(out *triageOutcome, mutedTS []float64, failedFloor float64) {
	for _, ts := range mutedTS {
		if ts >= failedFloor {
			break
		}
		if ts > out.MaxProcessedTS {
			out.MaxProcessedTS = ts
		}
	}
}

// loadMuteScopes returns the set of "sender:<id>" / "channel:<id>" scope keys
// that are hard-muted (weight <= -0.8), used to drop candidates before they
// ever reach the AI. Moved here from the deleted pinned_selector.go, which
// also relied on it for filtering AI-suggested pinned items.
func loadMuteScopes(database *db.DB) map[string]bool {
	rules, _ := database.ListAllLearnedRules()
	m := map[string]bool{}
	for _, r := range rules {
		if r.RuleType == "source_mute" && r.Weight <= -0.8 {
			m[r.ScopeKey] = true
		}
	}
	return m
}

// prioUpdateMap is an alias for db.BulkUpdateInboxPriorities' parameter type
// (kept unnamed there), so triageChunk and its helpers share one spelling.
type prioUpdateMap = map[int]struct {
	Priority string
	AIReason string
}

// buildTriageBlock renders the "=== CANDIDATES ===" section of the triage
// prompt and returns a by-key lookup plus the trigger items in this chunk
// (used to scope the learned-preferences block).
func buildTriageBlock(chunk []triageCandidate) (string, map[string]*triageCandidate, []db.InboxItem) {
	var block strings.Builder
	block.WriteString("=== CANDIDATES ===\n")
	byKey := make(map[string]*triageCandidate, len(chunk))
	var chunkItems []db.InboxItem
	for i := range chunk {
		block.WriteString(chunk[i].line + "\n")
		byKey[chunk[i].key] = &chunk[i]
		if chunk[i].item != nil {
			chunkItems = append(chunkItems, *chunk[i].item)
		}
	}
	return block.String(), byKey, chunkItems
}

// normalizeTriagePriority coerces an AI-returned priority to one of the three
// known values, defaulting to "medium" (INBOX-01 priority-default logic).
func normalizeTriagePriority(prio string) string {
	if prio != "high" && prio != "medium" && prio != "low" {
		return "medium"
	}
	return prio
}

// applyTriggerVerdict records the verdict's priority/reason for a trigger
// item and demotes it to ambient when the AI voted to ignore it. Trigger
// items are only ever demoted, never dropped, and never re-upgraded
// (INBOX-01).
func (p *Pipeline) applyTriggerVerdict(c *triageCandidate, v triageVerdict, prio string, prioUpdates prioUpdateMap) {
	tier := v.Tier
	if tier == "ignore" { // INBOX-01: triggers can be demoted, never dropped
		tier = "awareness"
	}
	prioUpdates[c.item.ID] = struct {
		Priority string
		AIReason string
	}{prio, v.Reason}
	if tier == "awareness" && c.item.ItemClass == "actionable" {
		_ = p.db.SetInboxItemClass(int64(c.item.ID), "ambient")
	}
	// tier == "action" on an already-ambient item: no upgrade (INBOX-01).
}

// createStreamItem persists a stream candidate as a new inbox item when the
// verdict is action or awareness; an ignore verdict persists nothing.
func (p *Pipeline) createStreamItem(c *triageCandidate, v triageVerdict, prio string, out *triageOutcome) {
	if v.Tier != "action" && v.Tier != "awareness" {
		return // ignore → nothing persisted
	}
	class := "actionable"
	if v.Tier == "awareness" {
		class = "ambient"
	}
	if _, err := p.db.CreateInboxItem(db.InboxItem{
		ChannelID:    c.stream.ChannelID,
		MessageTS:    c.stream.MessageTS,
		ThreadTS:     c.stream.ThreadTS,
		SenderUserID: c.stream.SenderUserID,
		TriggerType:  "stream",
		Snippet:      enrichSnippet(c.stream.Text, p.db),
		RawText:      c.stream.Text,
		Permalink:    c.stream.Permalink,
		Priority:     prio,
		AIReason:     v.Reason,
		ItemClass:    class,
	}); err == nil {
		out.Created++
	}
}

// callTriageAI sends the assembled system prompt to the AI and parses the
// structured verdict response.
func (p *Pipeline) callTriageAI(ctx context.Context, system string) (triageResult, error) {
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.triage"), system, "Triage these candidates.", "")
	if err != nil {
		return triageResult{}, fmt.Errorf("triage AI call: %w", err)
	}
	p.accumulateUsage(usage)

	jsonStr, err := prompts.ExtractJSONObject(raw)
	if err != nil {
		return triageResult{}, fmt.Errorf("triage response: %w", err)
	}
	var res triageResult
	if err := json.Unmarshal([]byte(jsonStr), &res); err != nil {
		return triageResult{}, fmt.Errorf("triage response parse: %w", err)
	}
	return res, nil
}

// advanceMaxProcessedTS raises out.MaxProcessedTS over every stream
// candidate's ts in chunk. All stream candidates in a chunk are processed
// regardless of their verdict (including "ignore"), so the watermark can
// advance past them.
func advanceMaxProcessedTS(chunk []triageCandidate, out *triageOutcome) {
	for _, c := range chunk {
		if c.stream != nil && c.stream.TSUnix > out.MaxProcessedTS {
			out.MaxProcessedTS = c.stream.TSUnix
		}
	}
}

// triageChunk sends one chunk of candidates to the AI and applies the
// verdicts. On any error (AI call, parse), it returns before mutating
// anything so the caller's outcome reflects only fully-triaged chunks (INBOX-07).
func (p *Pipeline) triageChunk(ctx context.Context, brief, tmpl string, chunk []triageCandidate, out *triageOutcome) error {
	blockStr, byKey, chunkItems := buildTriageBlock(chunk)
	// Scoped learned rules (mutes/boosts) for the trigger items in this chunk.
	if prefs, err := buildUserPreferencesBlock(p.db, chunkItems); err == nil && prefs != "" {
		blockStr += "\n" + prefs
	}

	system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, blockStr)
	res, err := p.callTriageAI(ctx, system)
	if err != nil {
		return err
	}

	prioUpdates := make(prioUpdateMap)
	for _, v := range res.Verdicts {
		c, ok := byKey[v.Key]
		if !ok {
			continue // hallucinated key
		}
		prio := normalizeTriagePriority(v.Priority)
		switch {
		case c.item != nil:
			p.applyTriggerVerdict(c, v, prio, prioUpdates)
		case c.stream != nil:
			p.createStreamItem(c, v, prio, out)
		}
	}
	advanceMaxProcessedTS(chunk, out)
	if len(prioUpdates) > 0 {
		if err := p.db.BulkUpdateInboxPriorities(prioUpdates); err != nil {
			return fmt.Errorf("applying triage priorities: %w", err)
		}
	}
	return nil
}
