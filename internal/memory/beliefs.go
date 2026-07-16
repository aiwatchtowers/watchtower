package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// reviseSource is the WithSource routing tag for the strong-tier belief pass;
// ABSENT from the light-tier switch, so it routes to the default (strong) model.
const reviseSource = prompts.MemoryReviseBeliefs

var evidenceHeadingRe = regexp.MustCompile(`(?m)^## Evidence[ \t]*$`)

// beliefOpJSON is one op the model proposes for a belief. The model NEVER sets
// confidence/status — the rank math (belief_math.go) computes them.
type beliefOpJSON struct {
	BeliefID  string       `json:"belief_id"`
	Op        string       `json:"op"`
	Statement string       `json:"statement"` // propose-new only
	Subject   string       `json:"subject"`   // propose-new only
	Evidence  []episodeRef `json:"evidence"`
	Rationale string       `json:"rationale"`
}

type beliefOpsReply struct {
	Ops []beliefOpJSON `json:"ops"`
}

// beliefEvidence is one parsed "## Evidence" line: a ranked, for/against
// provenance ref. Age is derived from the ts at read time, never cached.
type beliefEvidence struct {
	Rank      evidenceRank
	Support   bool // true = supports the belief, false = against
	ChannelID string
	TS        string // provenance ts (unix seconds), for age computation
}

func (e beliefEvidence) render() string {
	dir := "against"
	if e.Support {
		dir = "for"
	}
	return fmt.Sprintf("- %s %s %s %s\n", rankName(e.Rank), dir, e.ChannelID, e.TS)
}

// weigh converts a stored evidence line into the belief_math evidence the rank
// gate consumes, computing age from the provenance ts.
func (e beliefEvidence) weigh(now time.Time) evidence {
	ageDays := 0.0
	if ts, err := strconv.ParseFloat(e.TS, 64); err == nil {
		ageDays = now.Sub(time.Unix(int64(ts), 0)).Hours() / 24
	}
	return evidence{Rank: e.Rank, AgeDays: ageDays, Support: e.Support}
}

// ReviseBeliefs is the strong-tier belief pass (MEM-06 + MEM-08). Scope: beliefs
// whose subject was rewritten this run plus every shaken belief (capped). The
// model proposes one op per belief with cited evidence; every op is disposed of
// by the rank math (applyOp) — the model never flips a belief directly. Evidence
// refs are validated the MEM-01 way (a ref absent from the supplied episodes is
// dropped; an op left with no valid evidence is rejected and counted), and a
// propose-new whose subject does not resolve to an existing entity is rejected.
// Applied/downgraded ops mutate the belief frontmatter through the node fields,
// append a ## History line, and commit as one vault batch ("memory(beliefs)")
// mirrored into the index. maxBeliefs caps applied ops per run (<= 0 =
// unbounded). The pipeline gates the call behind memory.semantic.enabled
// (Task 11); this function is unconditional so it can be unit-tested directly.
func (p *Pipeline) ReviseBeliefs(ctx context.Context, rewrittenSubjects []string, maxBeliefs int, now time.Time) (touched int, usage *digest.Usage, err error) {
	if p.generator == nil {
		return 0, nil, nil
	}
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return 0, nil, err
	}

	subjectSet := make(map[string]bool, len(rewrittenSubjects))
	for _, s := range rewrittenSubjects {
		subjectSet[s] = true
	}

	// Candidate beliefs: subject rewritten this run, or currently shaken.
	candidatesByID := make(map[string]Node)
	var candidates []Node
	for _, row := range rows {
		if row.Type != "belief" || row.Status == "tombstone" || row.Status == statusRetired {
			continue
		}
		n, rerr := p.vault.ReadNode(row.ID)
		if rerr != nil {
			p.logf("memory: beliefs: read %s: %v", row.ID, rerr)
			continue
		}
		if subjectSet[n.Subject] || n.Status == statusShaken {
			candidates = append(candidates, n)
			candidatesByID[n.ID] = n
		}
	}

	// Episodes linked from the rewritten subjects supply both the prompt's new
	// evidence and the ref set every op's evidence is validated against.
	episodes := p.subjectEpisodes(rewrittenSubjects)
	inputSet := episodeRefSet(episodes)

	system, user := buildReviseBeliefsPrompt(p.getPrompt(prompts.MemoryReviseBeliefs), p.Language, candidates, episodes)
	raw, u, _, gerr := p.generator.Generate(digest.WithSource(ctx, reviseSource), system, user, "")
	var acc digest.Usage
	addUsage(&acc, u)
	usage = &acc
	if gerr != nil {
		return 0, usage, fmt.Errorf("memory: revise beliefs: generate: %w", gerr)
	}
	ops, perr := parseBeliefOps(raw)
	if perr != nil {
		return 0, usage, perr
	}

	var (
		nodes []Node
		ids   []string
	)
	for _, op := range ops.Ops {
		if maxBeliefs > 0 && touched >= maxBeliefs {
			break
		}
		node, ok := p.applyBeliefOp(op, candidatesByID, inputSet, now)
		if !ok {
			continue
		}
		nodes = append(nodes, node)
		ids = append(ids, node.ID)
		touched++
	}

	if len(nodes) == 0 {
		return 0, usage, nil
	}
	msg := CommitMsg{
		Op:      "beliefs",
		Summary: fmt.Sprintf("%d beliefs revised", len(nodes)),
		Cause:   "beliefs",
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, usage, err
	}
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, nowStr); err != nil {
			p.logf("memory: index %s after belief pass: %v", n.ID, err)
		}
	}
	return touched, usage, nil
}

// applyBeliefOp disposes of one proposed op through the rank math and returns
// the node to write plus whether the op was applied. Invented-only evidence, an
// unknown belief, an unresolvable propose-new subject, or a math-rejected
// transition all yield ok=false (nothing written).
func (p *Pipeline) applyBeliefOp(op beliefOpJSON, candidatesByID map[string]Node, inputSet map[string]bool, now time.Time) (Node, bool) {
	kept, dropped := validateMarkers(inputSet, op.Evidence)
	if dropped > 0 {
		p.logf("memory: beliefs: op %q evidence_rejected=%d (MEM-01)", op.Op, dropped)
	}
	if len(kept) == 0 {
		return Node{}, false // invented-only / evidence-less op is a no-op
	}

	switch beliefOp(op.Op) {
	case opProposeNew:
		return p.applyProposeNew(op, kept, now)
	case opConfirm, opWeaken, opShake, opRetire:
		return p.applyExistingOp(op, candidatesByID, kept, now)
	default:
		p.logf("memory: beliefs: unknown op %q", op.Op)
		return Node{}, false
	}
}

// applyProposeNew mints a bel_* node from a propose-new op. The subject must
// resolve to an existing entity; birth confidence comes from the rank math
// (capped at 0.6).
func (p *Pipeline) applyProposeNew(op beliefOpJSON, kept []episodeRef, now time.Time) (Node, bool) {
	if strings.TrimSpace(op.Statement) == "" {
		return Node{}, false
	}
	subject, err := Resolve(p.vault, p.db, op.Subject)
	if err != nil || subject.Type != "entity" {
		p.logf("memory: beliefs: propose-new subject %q does not resolve to an entity", op.Subject)
		return Node{}, false
	}

	ev := newEvidenceLines(kept, opProposeNew)
	state, _ := applyOp(beliefState{}, opProposeNew, weighAll(ev, now))
	id := NewID("belief")
	body := "# " + op.Statement + "\n\n## Evidence\n"
	for _, e := range ev {
		body += e.render()
	}
	body = appendHistory(body, historyLine(now, "created", op.Rationale))
	return Node{
		ID:         id,
		Type:       "belief",
		Tier:       "long",
		Status:     state.Status,
		Confidence: state.Confidence,
		Stability:  state.Stability,
		Subject:    subject.ID,
		Title:      op.Statement,
		Body:       body,
	}, true
}

// applyExistingOp mutates an in-scope belief. The op only takes effect when the
// rank math (applyOp) allows or downgrades it; a downgraded retire lands as
// shaken (MEM-06 owner-rank protection).
func (p *Pipeline) applyExistingOp(op beliefOpJSON, candidatesByID map[string]Node, kept []episodeRef, now time.Time) (Node, bool) {
	node, ok := candidatesByID[op.BeliefID]
	if !ok {
		return Node{}, false // out of scope / unknown belief id
	}
	newEv := newEvidenceLines(kept, beliefOp(op.Op))
	combined := append(weighAll(parseBeliefEvidence(node.Body), now), weighAll(newEv, now)...)
	state := beliefState{Confidence: node.Confidence, Stability: node.Stability, Status: node.Status}
	next, decision := applyOp(state, beliefOp(op.Op), combined)
	if decision == opRejected {
		return Node{}, false
	}

	node.Confidence = next.Confidence
	node.Stability = next.Stability
	node.Status = next.Status
	for _, e := range newEv {
		node.Body = appendToSection(node.Body, evidenceHeadingRe, "## Evidence", e.render())
	}
	cause := op.Op
	if decision == opDowngraded {
		cause += " (downgraded)"
	}
	node.Body = appendHistory(node.Body, historyLine(now, cause, op.Rationale))
	return node, true
}

// newEvidenceLines turns validated model refs into stored evidence lines. Model
// evidence is treated as rank observed (an observed episode); support direction
// follows the op (confirm/propose-new support the belief, the rest weigh
// against). Owner-rank evidence only ever enters via pre-existing/hand-authored
// belief pages — the model can never mint owner rank.
func newEvidenceLines(refs []episodeRef, op beliefOp) []beliefEvidence {
	support := op == opConfirm || op == opProposeNew
	out := make([]beliefEvidence, len(refs))
	for i, r := range refs {
		out[i] = beliefEvidence{Rank: rankObserved, Support: support, ChannelID: r.ChannelID, TS: r.TS}
	}
	return out
}

func weighAll(ev []beliefEvidence, now time.Time) []evidence {
	out := make([]evidence, len(ev))
	for i, e := range ev {
		out[i] = e.weigh(now)
	}
	return out
}

// parseBeliefEvidence reads a belief node's "## Evidence" lines
// ("- <rank> <for|against> <channel_id> <ts>").
func parseBeliefEvidence(body string) []beliefEvidence {
	var ev []beliefEvidence
	inEvidence := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			inEvidence = trimmed == "## Evidence"
			continue
		}
		if !inEvidence || !strings.HasPrefix(trimmed, "- ") {
			continue
		}
		fields := strings.Fields(strings.TrimPrefix(trimmed, "- "))
		if len(fields) != 4 {
			continue
		}
		rank, ok := parseEvidenceRank(fields[0])
		if !ok {
			continue
		}
		ev = append(ev, beliefEvidence{Rank: rank, Support: fields[1] == "for", ChannelID: fields[2], TS: fields[3]})
	}
	return ev
}

// subjectEpisodes gathers the active episodes linked from the given subject
// entities, deduped — the new-episode context for the belief prompt and the
// evidence-validation ref set.
func (p *Pipeline) subjectEpisodes(subjects []string) []Node {
	seen := make(map[string]bool)
	var eps []Node
	for _, s := range subjects {
		ent, err := Resolve(p.vault, p.db, s)
		if err != nil || ent.Type != "entity" {
			continue
		}
		for _, ep := range p.linkedEpisodes(ent) {
			if seen[ep.ID] {
				continue
			}
			seen[ep.ID] = true
			eps = append(eps, ep)
		}
	}
	return eps
}

// buildReviseBeliefsPrompt renders the belief pass call: the language directive
// fills the template's single %s slot; the user message digests the existing
// beliefs (id/statement/confidence/evidence) then the new episodes. It never
// opens with a "-"/"--" line (the claude-CLI argv gotcha).
func buildReviseBeliefsPrompt(tmpl, lang string, beliefs, episodes []Node) (system, user string) {
	system = fmt.Sprintf(tmpl, prompts.Directive(lang))

	var b strings.Builder
	b.WriteString("Existing beliefs:\n\n")
	if len(beliefs) == 0 {
		b.WriteString("(none)\n")
	}
	for _, bel := range beliefs {
		fmt.Fprintf(&b, "belief_id: %s\n", bel.ID)
		fmt.Fprintf(&b, "  statement: %s\n", bel.Title)
		fmt.Fprintf(&b, "  confidence: %s\n", strconv.FormatFloat(bel.Confidence, 'g', -1, 64))
		fmt.Fprintf(&b, "  status: %s\n", bel.Status)
	}
	b.WriteString("\nNew episodes:\n\n")
	for _, ep := range episodes {
		fmt.Fprintf(&b, "### %s\n", ep.Title)
		if s := sectionFirstLine(ep.Body, "## Story"); s != "" {
			fmt.Fprintf(&b, "Story: %s\n", s)
		}
		if o := sectionFirstLine(ep.Body, "## Outcome"); o != "" {
			fmt.Fprintf(&b, "Outcome: %s\n", o)
		}
		for _, r := range parseProvenance(ep.Body) {
			fmt.Fprintf(&b, "ref: %s %s\n", r.ChannelID, r.TS)
		}
		b.WriteString("\n")
	}
	return system, b.String()
}

// parseBeliefOps parses the belief pass reply: a JSON object with an "ops"
// array, tolerated bare or inside a ```json fence.
func parseBeliefOps(raw string) (beliefOpsReply, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return beliefOpsReply{}, fmt.Errorf("memory: revise-beliefs response has no JSON object")
	}
	var r beliefOpsReply
	if err := json.Unmarshal([]byte(s[start:end+1]), &r); err != nil {
		return beliefOpsReply{}, fmt.Errorf("memory: parse revise-beliefs response: %w", err)
	}
	return r, nil
}

// historyLine renders a dated ## History bullet with the op cause and a
// rationale digest.
func historyLine(now time.Time, cause, rationale string) string {
	line := fmt.Sprintf("- %s: %s", now.UTC().Format("2006-01-02"), cause)
	if r := strings.TrimSpace(rationale); r != "" {
		line += " — " + r
	}
	return line + "\n"
}

// rankName is the inverse of parseEvidenceRank, for rendering evidence lines.
func rankName(r evidenceRank) string {
	switch r {
	case rankOwner:
		return "owner"
	case rankObserved:
		return "observed"
	default:
		return "inferred"
	}
}
