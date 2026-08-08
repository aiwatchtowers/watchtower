package ideas

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// consolidateOp is one registry mutation the AI proposes for a consolidate
// cycle: mint a new idea/decision, or attach a fresh sighting to an existing
// registry item instead of duplicating it (see internal/prompts/defaults.go's
// defaultIdeasConsolidate).
type consolidateOp struct {
	Op        string         `json:"op"` // new_idea|new_decision|attach_mention
	Title     string         `json:"title"`
	Essence   string         `json:"essence"`
	IdeaID    int64          `json:"idea_id"`
	SimilarTo int64          `json:"similar_to"`
	Mentions  []mentionInput `json:"mentions"`
	Mention   *mentionInput  `json:"mention"`
}

// mentionInput is one sighting the AI cites, copied verbatim from a
// new-material line. The ref is validated against this run's rendered material
// before it is trusted — the model only proposes a ref, Go disposes (IDEA-02).
//
// Source is parsed for completeness but NEVER used: the authoritative source
// is whatever the run's own validRefs map recorded for that ref. A model token
// is not a second gate a ref has to pass — it is only another way to get a
// legitimate sighting silently dropped, or (worse, before this) to write a
// source string outside idea_mentions' CHECK and abort the whole transaction.
type mentionInput struct {
	Source string `json:"source"` // ignored — see the type comment
	Ref    string `json:"ref"`
	Quote  string `json:"quote"`
	Author string `json:"author"`
	SaidAt string `json:"said_at"`
}

// consolidateResult is the structured AI response for a consolidate cycle.
// Ops is a POINTER so a syntactically-valid reply that simply omits the "ops"
// key is distinguishable from one that explicitly returns none: the former is
// a model error (it answered nothing), the latter is the ordinary "no changes
// this run" answer. Only the latter may advance the floors.
type consolidateResult struct {
	Ops *[]consolidateOp `json:"ops"`
}

// consolidateInput is the gathered, budget-capped stage-1 material for one
// consolidate cycle: the rendered "=== NEW MATERIAL ===" body, the set of
// refs it actually contains (ref -> source, "slack"|"meeting"|"gmail"|
// "jira"), and the per-source floor each should advance to — the highest id
// among the units this run actually consumed, never past a unit that was
// left out for lack of budget (IDEA-01). The start* fields hold the floors as
// read, so a run that consumed units without rendering any of them can still
// tell that its floors moved.
type consolidateInput struct {
	startTopicID, startStreamID, startTranscriptID int64
	maxTopicID, maxStreamID, maxTranscriptID       int64
	validRefs                                      map[string]string
	block                                          string
	included                                       int
}

// floorsAdvanced reports whether this run consumed any unit at all — whether
// or not the unit produced material for the prompt.
func (in *consolidateInput) floorsAdvanced() bool {
	return in.maxTopicID != in.startTopicID ||
		in.maxStreamID != in.startStreamID ||
		in.maxTranscriptID != in.startTranscriptID
}

// transcriptRecapWaitWindow is how long a just-finished transcript is given
// a chance for its recap to land before the consolidator stops waiting and
// treats it as recap-less for real (spec §7).
const transcriptRecapWaitWindow = 48 * time.Hour

// transcriptRecap is the subset of meeting.recap's RecapResult the
// consolidator cares about, parsed leniently from a transcript's resolved
// recap JSON (TranscriptForIdeas.RecapJSON) — a malformed or absent recap
// unmarshals to a zero value, which the caller treats as "no recap yet".
type transcriptRecap struct {
	Ideas        []string `json:"ideas"`
	KeyDecisions []string `json:"key_decisions"`
}

// runConsolidate is the ideas registry's stage-2 pass: it folds newly mined
// stage-1 material (Slack digest topics, stream_digests rows, meeting
// recaps) into the durable registry via one AI call, then applies the
// model's ops and advances the registry floors inside a single transaction —
// a failure anywhere (the AI call, the parse, or an apply write) leaves the
// registry, its mentions, and the floors untouched (IDEA-01). Returns the
// number of ideas/decisions rows created this run. A nil generator (the
// runEmailDigests/runJiraDigests precedent) is a clean no-op. bound is an
// optional upper bound on every listing this pass reads (the zero value is
// unbounded — Run's ordinary daemon/incremental path passes time.Time{}); a
// non-zero bound is how a backfill run scopes one pass to a slice of history.
func (p *Pipeline) runConsolidate(ctx context.Context, bound time.Time) (int, error) {
	if p.generator == nil {
		return 0, nil
	}

	in, err := p.gatherConsolidateInput(p.maxPromptChars(), bound)
	if err != nil {
		return 0, fmt.Errorf("gathering consolidate input: %w", err)
	}
	if in.included == 0 {
		// Nothing rendered — no AI call. But units may still have been
		// CONSUMED (empty stage-1 rows, stale recap-less transcripts, a unit
		// too big to ever fit): their floors have to land, or every future
		// run re-reads the same inert material forever.
		return 0, persistFloorsOnly(p.db, in)
	}

	registry, err := p.db.ListIdeasForPrompt()
	if err != nil {
		return 0, fmt.Errorf("listing registry for prompt: %w", err)
	}

	tmpl, _ := p.getPrompt("ideas.consolidate")
	system := fmt.Sprintf(tmpl, prompts.Directive(p.language()))
	userMsg := buildConsolidateUserMessage(registry, buildPreferencesBlock(p.db), in.block)

	reply, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "ideas.consolidate"), system, userMsg, "")
	p.accumulateUsage(usage)
	if err != nil {
		return 0, fmt.Errorf("consolidate AI call: %w", err)
	}

	raw, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return 0, fmt.Errorf("extracting consolidate JSON: %w", err)
	}
	var res consolidateResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		return 0, fmt.Errorf("parsing consolidate JSON: %w", err)
	}
	if res.Ops == nil {
		// Valid JSON that answers nothing is a model failure, not an empty
		// verdict — treat it exactly like malformed JSON: no commit, no floor
		// advance, so the material comes back next run.
		return 0, fmt.Errorf("consolidate reply has no \"ops\" key")
	}

	// Parsing succeeded — only now do we start mutating (compose.go:123
	// parse-before-mutate precedent).
	registryByID := make(map[int64]db.Idea, len(registry))
	for _, idea := range registry {
		registryByID[idea.ID] = idea
	}

	proposed, refsRejected, mentionsDeduped, err := applyConsolidateOps(p.db, *res.Ops, registryByID, in)
	if err != nil {
		return 0, err
	}
	if refsRejected > 0 {
		p.logf("ideas: consolidate dropped %d invented ref(s)", refsRejected)
	}
	if mentionsDeduped > 0 {
		p.logf("ideas: consolidate deduped %d already-mined mention(s)", mentionsDeduped)
	}
	return proposed, nil
}

// maxPromptChars returns the configured input-assembly budget, falling back
// to the documented default when cfg is nil or unset (a zero budget would
// otherwise exclude every unit, breaking every run).
func (p *Pipeline) maxPromptChars() int {
	if p.cfg != nil && p.cfg.Ideas.MaxPromptChars > 0 {
		return p.cfg.Ideas.MaxPromptChars
	}
	return config.DefaultIdeasMaxPromptChars
}

// gatherConsolidateInput reads the three registry floors, lists everything
// past them (and, when bound is non-zero, at or before it), and renders a
// budget-capped "=== NEW MATERIAL ===" body in deterministic order — Slack
// digest topics, then stream digests (Gmail/Jira), then meeting transcripts —
// appending whole units until maxChars is spent. Once a unit doesn't fit,
// consumption stops entirely (no smaller later unit is smuggled in out of
// order), so each source's floor advances only past the units this run
// actually included; a source that contributed nothing keeps its old floor
// (IDEA-01).
func (p *Pipeline) gatherConsolidateInput(maxChars int, bound time.Time) (*consolidateInput, error) {
	topicFloor, streamFloor, transcriptFloor, err := p.db.GetIdeasFloors()
	if err != nil {
		return nil, fmt.Errorf("getting ideas floors: %w", err)
	}

	var toUnix int64
	var toISO string
	if !bound.IsZero() {
		toUnix = bound.Unix()
		toISO = bound.UTC().Format(time.RFC3339)
	}

	topics, err := p.db.ListDigestTopicIdeasAfter(topicFloor, toUnix)
	if err != nil {
		return nil, fmt.Errorf("listing digest topic ideas: %w", err)
	}
	streams, err := p.db.ListStreamDigestsAfter(streamFloor, toISO)
	if err != nil {
		return nil, fmt.Errorf("listing stream digests: %w", err)
	}
	transcripts, err := p.db.ListTranscriptsForIdeasAfter(transcriptFloor, toISO)
	if err != nil {
		return nil, fmt.Errorf("listing transcripts for ideas: %w", err)
	}

	in := &consolidateInput{
		startTopicID: topicFloor, startStreamID: streamFloor, startTranscriptID: transcriptFloor,
		maxTopicID: topicFloor, maxStreamID: streamFloor, maxTranscriptID: transcriptFloor,
		validRefs: map[string]string{},
	}
	var b strings.Builder
	budget := maxChars
	stopped := false

	// include appends a rendered unit if it still fits the budget. An empty
	// unit (a stage-1 row that ended up with no surviving candidates) costs
	// nothing and is always "included" for floor-advancement purposes. A unit
	// bigger than the WHOLE budget can never fit in any run, so it is skipped
	// and consumed rather than left wedging the floor forever. Once stopped
	// is set it stays set: no later, possibly-smaller unit is allowed to jump
	// the queue.
	include := func(id, unit string, refs map[string]string) bool {
		if unit == "" {
			return true
		}
		if stopped {
			return false
		}
		if len(unit) > maxChars {
			p.logf("ideas: consolidate skipping oversized unit %s (%d chars > %d budget)", id, len(unit), maxChars)
			return true
		}
		if len(unit) > budget {
			stopped = true
			return false
		}
		b.WriteString(unit)
		budget -= len(unit)
		in.included++
		for ref, src := range refs {
			in.validRefs[ref] = src
		}
		return true
	}

	for _, t := range topics {
		unit, refs := p.renderTopicUnit(t)
		if !include(fmt.Sprintf("digest topic %d", t.TopicID), unit, refs) {
			break
		}
		in.maxTopicID = t.TopicID
	}
	for _, s := range streams {
		unit, refs := p.renderStreamUnit(s)
		if !include(fmt.Sprintf("stream digest %d", s.ID), unit, refs) {
			break
		}
		in.maxStreamID = s.ID
	}
	for _, t := range transcripts {
		recap := parseTranscriptRecap(t.RecapJSON)
		if len(recap.Ideas) == 0 && len(recap.KeyDecisions) == 0 {
			if transcriptIsRecent(t.CreatedAt) {
				break // give the recap a chance to still arrive next run
			}
			in.maxTranscriptID = t.ID // stale and recap-less — skip and count, free
			continue
		}
		unit, refs := renderTranscriptUnit(t, recap)
		if !include(fmt.Sprintf("transcript %d", t.ID), unit, refs) {
			break
		}
		in.maxTranscriptID = t.ID
	}

	in.block = b.String()
	return in, nil
}

// persistFloorsOnly commits the floors a run advanced when it produced no
// material to send the model (every consumed unit was inert). Without this the
// same empty stream-digest rows and stale recap-less transcripts are re-read on
// every single run, forever. A run that consumed nothing writes nothing.
func persistFloorsOnly(database *db.DB, in *consolidateInput) error {
	if !in.floorsAdvanced() {
		return nil
	}
	tx, err := database.Begin()
	if err != nil {
		return fmt.Errorf("beginning ideas floor-only tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	if err := database.SetIdeasFloorsTx(tx, in.maxTopicID, in.maxStreamID, in.maxTranscriptID); err != nil {
		return fmt.Errorf("advancing ideas floors: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing ideas floor-only advance: %w", err)
	}
	return nil
}

// renderTopicUnit renders one Slack digest topic's idea/decision candidates,
// one line each, ending in " ref=<channel_id>|<message_ts>" — the exact ref
// shape a consolidate mention must copy to survive validation. Returns ""
// when the topic carries no candidates, which ListDigestTopicIdeasAfter's
// `!= '[]'` filter catches for every row written since the digest pipeline
// started marshaling empty arrays as "[]" (marshalArray), but not for a
// legacy row that stored a bare "null".
func (p *Pipeline) renderTopicUnit(t db.DigestTopicForIdeas) (string, map[string]string) {
	var ideas []digest.IdeaCandidate
	if err := json.Unmarshal([]byte(t.Ideas), &ideas); err != nil {
		p.logf("ideas: digest topic %d has unreadable ideas JSON: %v", t.TopicID, err)
	}
	var decisions []digest.Decision
	if err := json.Unmarshal([]byte(t.Decisions), &decisions); err != nil {
		p.logf("ideas: digest topic %d has unreadable decisions JSON: %v", t.TopicID, err)
	}
	if len(ideas) == 0 && len(decisions) == 0 {
		return "", nil
	}

	label := t.ChannelName
	if label == "" {
		label = t.ChannelID
	}
	refs := map[string]string{}
	var b strings.Builder
	for _, c := range ideas {
		ref := t.ChannelID + "|" + c.MessageTS
		refs[ref] = "slack"
		fmt.Fprintf(&b, "[#%s] idea: %q — %s ref=%s\n", label, c.Text, c.By, ref)
	}
	for _, c := range decisions {
		ref := t.ChannelID + "|" + c.MessageTS
		refs[ref] = "slack"
		fmt.Fprintf(&b, "[#%s] decision: %q — %s ref=%s\n", label, c.Text, c.By, ref)
	}
	return b.String(), refs
}

// renderStreamUnit renders one stream_digests row's (Gmail or Jira) already
// stage-1-validated candidates, one line each. Refs come verbatim from
// topics_json (gmail:<acct>:<thread> or a bare Jira key) — no reconstruction.
// topics_json holds a bare JSON array of streamTopic (see
// runEmailDigestAccount/runJiraDigestAccount's json.Marshal(topics) — not
// wrapped in a streamTopics envelope). Returns "" for a row whose candidates
// were all stripped at stage 1 (topics_json == "[]").
func (p *Pipeline) renderStreamUnit(s db.StreamDigest) (string, map[string]string) {
	var topics []streamTopic
	if err := json.Unmarshal([]byte(s.TopicsJSON), &topics); err != nil {
		p.logf("ideas: stream digest %d has unreadable topics JSON: %v", s.ID, err)
		return "", nil
	}
	refs := map[string]string{}
	var b strings.Builder
	label := strings.ToUpper(s.Source)
	for _, topic := range topics {
		for _, c := range topic.Ideas {
			if c.Ref == "" {
				continue
			}
			refs[c.Ref] = s.Source
			fmt.Fprintf(&b, "[%s/%s] idea: %q — %s ref=%s\n", label, topic.Title, c.Text, c.Author, c.Ref)
		}
		for _, c := range topic.Decisions {
			if c.Ref == "" {
				continue
			}
			refs[c.Ref] = s.Source
			fmt.Fprintf(&b, "[%s/%s] decision: %q — %s ref=%s\n", label, topic.Title, c.Text, c.Author, c.Ref)
		}
	}
	if b.Len() == 0 {
		return "", nil
	}
	return b.String(), refs
}

// renderTranscriptUnit renders one meeting's recap ideas/decisions, one line
// each, all sharing a single ref — "transcript:<id>" — since a recap's
// ideas/key_decisions are plain strings with no per-item citation of their
// own.
func renderTranscriptUnit(t db.TranscriptForIdeas, recap transcriptRecap) (string, map[string]string) {
	ref := fmt.Sprintf("transcript:%d", t.ID)
	refs := map[string]string{ref: "meeting"}
	title := t.Title
	if title == "" {
		title = "(untitled meeting)"
	}
	var b strings.Builder
	for _, idea := range recap.Ideas {
		fmt.Fprintf(&b, "[%s] idea: %q ref=%s\n", title, idea, ref)
	}
	for _, dec := range recap.KeyDecisions {
		fmt.Fprintf(&b, "[%s] decision: %q ref=%s\n", title, dec, ref)
	}
	return b.String(), refs
}

// parseTranscriptRecap parses a transcript's resolved recap JSON leniently:
// an empty string or a malformed document both come back as the zero value,
// which the caller reads as "no recap yet" (spec §7).
func parseTranscriptRecap(raw string) transcriptRecap {
	var r transcriptRecap
	if raw == "" {
		return r
	}
	_ = json.Unmarshal([]byte(raw), &r)
	return r
}

// transcriptIsRecent reports whether createdAt is within
// transcriptRecapWaitWindow of now. An unparseable timestamp is treated as
// NOT recent, so a transcript the code can't date falls through to the
// skip-and-count path rather than blocking transcript consumption forever.
func transcriptIsRecent(createdAt string) bool {
	t, err := time.Parse(time.RFC3339, createdAt)
	if err != nil {
		return false
	}
	return time.Since(t) < transcriptRecapWaitWindow
}

// buildConsolidateUserMessage assembles the consolidator's user message —
// the registry, the owner's preferences, and the new material — in the
// section shape defaultIdeasConsolidate's own prose describes.
func buildConsolidateUserMessage(registry []db.Idea, prefsBlock, materialBlock string) string {
	var b strings.Builder
	b.WriteString("=== REGISTRY ===\n")
	b.WriteString(registrySection(registry))

	if prefsBlock != "" {
		b.WriteString("\n\n=== OWNER PREFERENCES ===\n")
		b.WriteString(prefsBlock)
	}

	b.WriteString("\n\n=== NEW MATERIAL ===\n")
	b.WriteString(materialBlock)
	return b.String()
}

// registrySection renders the current registry as one line per item:
// "#<id> [<kind>/<status>] <title> — <essence>".
func registrySection(registry []db.Idea) string {
	if len(registry) == 0 {
		return "(empty — nothing tracked yet)"
	}
	var b strings.Builder
	for _, idea := range registry {
		fmt.Fprintf(&b, "#%d [%s/%s] %s — %s\n", idea.ID, idea.Kind, idea.Status, idea.Title, idea.Essence)
	}
	return b.String()
}

// applyConsolidateOps applies the AI's ops and advances the registry's
// floors inside a single transaction: any error rolls back every mutation
// from this pass, so a partial write can never leave the registry, its
// mentions, or the floors disagreeing with each other (IDEA-01). Returns the
// number of ideas/decisions rows created, the number of invented refs
// dropped (IDEA-02), and the number of mentions dropped because their ref
// was already recorded — re-mining already-mined material (IDEA-05).
func applyConsolidateOps(database *db.DB, ops []consolidateOp, registryByID map[int64]db.Idea, in *consolidateInput) (proposed, refsRejected, mentionsDeduped int, err error) {
	tx, err := database.Begin()
	if err != nil {
		return 0, 0, 0, fmt.Errorf("beginning consolidate apply tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	for _, op := range ops {
		switch op.Op {
		case "new_idea", "new_decision":
			kind := "idea"
			if op.Op == "new_decision" {
				kind = "decision"
			}

			// First pass: drop invented refs (IDEA-02).
			type candidate struct {
				m   mentionInput
				src string
			}
			candidates := make([]candidate, 0, len(op.Mentions))
			for _, m := range op.Mentions {
				src, ok := in.validRefs[m.Ref]
				if !ok {
					refsRejected++
					continue
				}
				candidates = append(candidates, candidate{m: m, src: src})
			}

			// Second pass: drop refs already mined anywhere in idea_mentions
			// (IDEA-05) — batched per source, one lookup per distinct source
			// in this op (almost always exactly one).
			refsBySrc := map[string][]string{}
			for _, c := range candidates {
				refsBySrc[c.src] = append(refsBySrc[c.src], c.m.Ref)
			}
			knownBySrc := make(map[string]map[string]int64, len(refsBySrc))
			for src, refs := range refsBySrc {
				known, kerr := database.IdeaMentionRefsKnownTx(tx, src, refs)
				if kerr != nil {
					return proposed, refsRejected, mentionsDeduped, fmt.Errorf("checking known mention refs: %w", kerr)
				}
				knownBySrc[src] = known
			}

			valid := make([]db.IdeaMention, 0, len(candidates))
			for _, c := range candidates {
				if _, dup := knownBySrc[c.src][c.m.Ref]; dup {
					mentionsDeduped++
					continue
				}
				valid = append(valid, db.IdeaMention{
					Source: c.src, Ref: c.m.Ref, Quote: c.m.Quote, Author: c.m.Author, SaidAt: c.m.SaidAt,
				})
			}
			if len(valid) == 0 {
				continue // nothing survived — invented (IDEA-02) or already mined (IDEA-05)
			}

			idea := db.Idea{Kind: kind, Title: op.Title, Essence: op.Essence}
			if op.SimilarTo > 0 {
				if _, ok := registryByID[op.SimilarTo]; ok {
					idea.SimilarToID = sql.NullInt64{Int64: op.SimilarTo, Valid: true}
				}
			}
			id, cerr := database.CreateIdeaTx(tx, idea)
			if cerr != nil {
				return proposed, refsRejected, mentionsDeduped, fmt.Errorf("creating %s %q: %w", kind, op.Title, cerr)
			}
			for _, m := range valid {
				m.IdeaID = id
				if merr := database.InsertIdeaMentionTx(tx, m); merr != nil {
					return proposed, refsRejected, mentionsDeduped, fmt.Errorf("recording mention for idea %d: %w", id, merr)
				}
			}
			proposed++

		case "attach_mention":
			if op.Mention == nil {
				continue
			}
			target, ok := registryByID[op.IdeaID]
			if !ok {
				continue // hallucinated idea id — skip (compose.go merge-op precedent)
			}
			if target.MergedIntoID.Valid {
				if merged, ok2 := registryByID[target.MergedIntoID.Int64]; ok2 {
					target = merged // follow merged_into_id exactly one hop
				}
			}
			src, refOK := in.validRefs[op.Mention.Ref]
			if !refOK {
				refsRejected++
				continue
			}
			known, kerr := database.IdeaMentionRefsKnownTx(tx, src, []string{op.Mention.Ref})
			if kerr != nil {
				return proposed, refsRejected, mentionsDeduped, fmt.Errorf("checking known mention ref for idea %d: %w", target.ID, kerr)
			}
			if knownIdeaID, dup := known[op.Mention.Ref]; dup && knownIdeaID == target.ID {
				// Already on the target idea — no new evidence, so this must
				// not resurface a not_now/dropped/rejected verdict either
				// (IDEA-05 x IDEA-04, mirroring PR #78's IDEA-02x04 finding).
				mentionsDeduped++
				continue
			}
			if merr := database.InsertIdeaMentionTx(tx, db.IdeaMention{
				IdeaID: target.ID, Source: src, Ref: op.Mention.Ref,
				Quote: op.Mention.Quote, Author: op.Mention.Author, SaidAt: op.Mention.SaidAt,
			}); merr != nil {
				return proposed, refsRejected, mentionsDeduped, fmt.Errorf("attaching mention to idea %d: %w", target.ID, merr)
			}
			if target.Status == "not_now" || target.Status == "dropped" || target.Status == "rejected" {
				reason := fmt.Sprintf("brought up again: %s %s", src, op.Mention.Ref)
				if rerr := database.SetIdeaNeedsReviewTx(tx, target.ID, reason); rerr != nil {
					return proposed, refsRejected, mentionsDeduped, fmt.Errorf("flagging idea %d for review: %w", target.ID, rerr)
				}
			}
		}
	}

	if err := database.SetIdeasFloorsTx(tx, in.maxTopicID, in.maxStreamID, in.maxTranscriptID); err != nil {
		return proposed, refsRejected, mentionsDeduped, fmt.Errorf("advancing ideas floors: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return proposed, refsRejected, mentionsDeduped, fmt.Errorf("committing consolidate apply: %w", err)
	}
	return proposed, refsRejected, mentionsDeduped, nil
}
