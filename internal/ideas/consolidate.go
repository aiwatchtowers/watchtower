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
// new-material line. Every field is validated against this run's rendered
// material before it is trusted — the model only proposes a ref, Go disposes
// (IDEA-02).
type mentionInput struct {
	Source string `json:"source"`
	Ref    string `json:"ref"`
	Quote  string `json:"quote"`
	Author string `json:"author"`
	SaidAt string `json:"said_at"`
}

// consolidateResult is the structured AI response for a consolidate cycle.
type consolidateResult struct {
	Ops []consolidateOp `json:"ops"`
}

// consolidateInput is the gathered, budget-capped stage-1 material for one
// consolidate cycle: the rendered "=== NEW MATERIAL ===" body, the set of
// refs it actually contains (ref -> source, "slack"|"meeting"|"gmail"|
// "jira"), and the per-source floor each should advance to — the highest id
// among the units this run actually included, never past a unit that was
// left out for lack of budget (IDEA-01).
type consolidateInput struct {
	maxTopicID, maxStreamID, maxTranscriptID int64
	validRefs                                map[string]string
	block                                    string
	included                                 int
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
// runEmailDigests/runJiraDigests precedent) is a clean no-op.
func (p *Pipeline) runConsolidate(ctx context.Context) (int, error) {
	if p.generator == nil {
		return 0, nil
	}

	in, err := gatherConsolidateInput(p.db, p.maxPromptChars())
	if err != nil {
		return 0, fmt.Errorf("gathering consolidate input: %w", err)
	}
	if in.included == 0 {
		return 0, nil // nothing new to fold in — no AI call, floors untouched
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

	// Parsing succeeded — only now do we start mutating (compose.go:123
	// parse-before-mutate precedent).
	registryByID := make(map[int64]db.Idea, len(registry))
	for _, idea := range registry {
		registryByID[idea.ID] = idea
	}

	proposed, refsRejected, err := applyConsolidateOps(p.db, res.Ops, registryByID, in)
	if err != nil {
		return 0, err
	}
	if refsRejected > 0 && p.logger != nil {
		p.logger.Printf("ideas: consolidate dropped %d invented ref(s)", refsRejected)
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
// past them, and renders a budget-capped "=== NEW MATERIAL ===" body in
// deterministic order — Slack digest topics, then stream digests (Gmail/
// Jira), then meeting transcripts — appending whole units until maxChars is
// spent. Once a unit doesn't fit, consumption stops entirely (no smaller
// later unit is smuggled in out of order), so each source's floor advances
// only past the units this run actually included; a source that contributed
// nothing keeps its old floor (IDEA-01).
func gatherConsolidateInput(database *db.DB, maxChars int) (*consolidateInput, error) {
	topicFloor, streamFloor, transcriptFloor, err := database.GetIdeasFloors()
	if err != nil {
		return nil, fmt.Errorf("getting ideas floors: %w", err)
	}

	topics, err := database.ListDigestTopicIdeasAfter(topicFloor)
	if err != nil {
		return nil, fmt.Errorf("listing digest topic ideas: %w", err)
	}
	streams, err := database.ListStreamDigestsAfter(streamFloor)
	if err != nil {
		return nil, fmt.Errorf("listing stream digests: %w", err)
	}
	transcripts, err := database.ListTranscriptsForIdeasAfter(transcriptFloor)
	if err != nil {
		return nil, fmt.Errorf("listing transcripts for ideas: %w", err)
	}

	in := &consolidateInput{
		maxTopicID:      topicFloor,
		maxStreamID:     streamFloor,
		maxTranscriptID: transcriptFloor,
		validRefs:       map[string]string{},
	}
	var b strings.Builder
	budget := maxChars
	stopped := false

	// include appends a rendered unit if it still fits the budget. An empty
	// unit (a stage-1 row that ended up with no surviving candidates) costs
	// nothing and is always "included" for floor-advancement purposes. Once
	// stopped is set it stays set: no later, possibly-smaller unit is
	// allowed to jump the queue.
	include := func(unit string, refs map[string]string) bool {
		if unit == "" {
			return true
		}
		if stopped || len(unit) > budget {
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
		unit, refs := renderTopicUnit(t)
		if !include(unit, refs) {
			break
		}
		in.maxTopicID = t.TopicID
	}
	for _, s := range streams {
		unit, refs := renderStreamUnit(s)
		if !include(unit, refs) {
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
		if !include(unit, refs) {
			break
		}
		in.maxTranscriptID = t.ID
	}

	in.block = b.String()
	return in, nil
}

// renderTopicUnit renders one Slack digest topic's idea/decision candidates,
// one line each, ending in " ref=<channel_id>|<message_ts>" — the exact ref
// shape a consolidate mention must copy to survive validation. Returns ""
// when the topic carries no candidates (defensive; ListDigestTopicIdeasAfter
// already filters these out).
func renderTopicUnit(t db.DigestTopicForIdeas) (string, map[string]string) {
	var ideas []digest.IdeaCandidate
	_ = json.Unmarshal([]byte(t.Ideas), &ideas)
	var decisions []digest.Decision
	_ = json.Unmarshal([]byte(t.Decisions), &decisions)
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
func renderStreamUnit(s db.StreamDigest) (string, map[string]string) {
	var topics []streamTopic
	if err := json.Unmarshal([]byte(s.TopicsJSON), &topics); err != nil {
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
// number of ideas/decisions rows created and the number of invented refs
// dropped along the way.
func applyConsolidateOps(database *db.DB, ops []consolidateOp, registryByID map[int64]db.Idea, in *consolidateInput) (proposed, refsRejected int, err error) {
	tx, err := database.Begin()
	if err != nil {
		return 0, 0, fmt.Errorf("beginning consolidate apply tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op once committed

	for _, op := range ops {
		switch op.Op {
		case "new_idea", "new_decision":
			kind := "idea"
			if op.Op == "new_decision" {
				kind = "decision"
			}
			valid := make([]mentionInput, 0, len(op.Mentions))
			for _, m := range op.Mentions {
				if src, ok := in.validRefs[m.Ref]; ok && src == m.Source {
					valid = append(valid, m)
				} else {
					refsRejected++
				}
			}
			if len(valid) == 0 {
				continue // nothing survived — drop the whole op (IDEA-02)
			}

			idea := db.Idea{Kind: kind, Title: op.Title, Essence: op.Essence}
			if op.SimilarTo > 0 {
				if _, ok := registryByID[op.SimilarTo]; ok {
					idea.SimilarToID = sql.NullInt64{Int64: op.SimilarTo, Valid: true}
				}
			}
			id, cerr := database.CreateIdeaTx(tx, idea)
			if cerr != nil {
				return proposed, refsRejected, fmt.Errorf("creating %s %q: %w", kind, op.Title, cerr)
			}
			for _, m := range valid {
				if merr := database.InsertIdeaMentionTx(tx, db.IdeaMention{
					IdeaID: id, Source: m.Source, Ref: m.Ref, Quote: m.Quote, Author: m.Author, SaidAt: m.SaidAt,
				}); merr != nil {
					return proposed, refsRejected, fmt.Errorf("recording mention for idea %d: %w", id, merr)
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
			if !refOK || src != op.Mention.Source {
				refsRejected++
				continue
			}
			if merr := database.InsertIdeaMentionTx(tx, db.IdeaMention{
				IdeaID: target.ID, Source: op.Mention.Source, Ref: op.Mention.Ref,
				Quote: op.Mention.Quote, Author: op.Mention.Author, SaidAt: op.Mention.SaidAt,
			}); merr != nil {
				return proposed, refsRejected, fmt.Errorf("attaching mention to idea %d: %w", target.ID, merr)
			}
			if target.Status == "not_now" || target.Status == "dropped" || target.Status == "rejected" {
				reason := fmt.Sprintf("brought up again: %s %s", op.Mention.Source, op.Mention.Ref)
				if rerr := database.SetIdeaNeedsReviewTx(tx, target.ID, reason); rerr != nil {
					return proposed, refsRejected, fmt.Errorf("flagging idea %d for review: %w", target.ID, rerr)
				}
			}
		}
	}

	if err := database.SetIdeasFloorsTx(tx, in.maxTopicID, in.maxStreamID, in.maxTranscriptID); err != nil {
		return proposed, refsRejected, fmt.Errorf("advancing ideas floors: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return proposed, refsRejected, fmt.Errorf("committing consolidate apply: %w", err)
	}
	return proposed, refsRejected, nil
}
