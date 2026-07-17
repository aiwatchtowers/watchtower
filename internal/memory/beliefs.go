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
// unbounded); capHit reports whether that cap cut the op loop short, so the
// caller can hold the chat-turn floor (staged owner refs may be uncited — M3).
// staged carries this run's owner Discuss turns (nil unless the chat surface
// staged some): they widen the candidate scope and admit their chat: refs into
// the input set. The pipeline gates the call behind memory.semantic.enabled
// (Task 11); this function is unconditional so it can be unit-tested directly.
func (p *Pipeline) ReviseBeliefs(ctx context.Context, rewrittenSubjects []string, staged *stagedChat, maxBeliefs int, now time.Time) (touched, rejected int, capHit bool, usage *digest.Usage, err error) {
	if p.generator == nil {
		return 0, 0, false, nil, nil
	}
	rows, err := p.db.ListMemoryNodes()
	if err != nil {
		return 0, 0, false, nil, err
	}

	subjectSet := make(map[string]bool, len(rewrittenSubjects))
	for _, s := range rewrittenSubjects {
		subjectSet[s] = true
	}
	// Phase-4 chat surface: owner Discuss turns staged this run widen the
	// candidate scope to the entities they bear on, so a belief the owner
	// contradicts in chat is revised even when its subject was not rewritten.
	if staged != nil {
		for s := range staged.subjects {
			subjectSet[s] = true
		}
	}

	// Candidate beliefs: subject rewritten this run, or currently shaken.
	candidatesByID := make(map[string]Node)
	var candidates []Node
	// Known subjects: the active entities a propose-new op is allowed to name,
	// rendered as id+title pairs so the model copies an exact id instead of
	// inventing a readable slug (which can never resolve — see the 2026-07-16
	// changelog entry: the first live semantic-tier run proposed 13 ops, all
	// rejected, because the prompt asked for "an entity id" without ever
	// showing the model one).
	var knownSubjects []Node
	for _, row := range rows {
		if row.Type == "entity" && row.Status == "active" && subjectSet[row.ID] {
			knownSubjects = append(knownSubjects, Node{ID: row.ID, Title: row.Title})
			continue
		}
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

	// Admit the staged owner chat + act refs into the input set so a model op
	// citing one validates (Task 3 / MEM-15) instead of being dropped as invented
	// (MEM-08); the verbatim statements render into the prompt's OWNER SAID block.
	var statements []ownerStatement
	if staged != nil {
		for ref := range staged.refs {
			inputSet[ref] = true
		}
		statements = staged.statements
	}

	// OWNER ACTIONS (Phase-5 5D, dark behind memory.semantic.preferences): the
	// staged mechanical owner interactions plus per-subject engagement aggregates,
	// so the model can form preference beliefs. The block is built only when the
	// gate is on AND actions were staged — otherwise ownerActions is nil and the
	// prompt is byte-identical to the pre-preferences behavior (the block is
	// absent, not empty-rendered).
	var ownerActions *ownerActionsBlock
	if p.cfg.Semantic.Preferences && staged != nil && len(staged.actions) > 0 {
		ownerActions = p.buildOwnerActionsBlock(staged.actions)
	}

	system, user := buildReviseBeliefsPrompt(p.getPrompt(prompts.MemoryReviseBeliefs), p.Language, candidates, knownSubjects, episodes, statements, ownerActions)
	raw, u, _, gerr := p.generator.Generate(digest.WithSource(ctx, reviseSource), system, user, "")
	usage = u // single call — the reply's usage is the step's usage
	if gerr != nil {
		return 0, 0, false, usage, fmt.Errorf("memory: revise beliefs: generate: %w", gerr)
	}
	ops, perr := parseBeliefOps(raw)
	if perr != nil {
		return 0, 0, false, usage, perr
	}

	var (
		nodes []Node
		ids   []string
	)
	for _, op := range ops.Ops {
		if maxBeliefs > 0 && touched >= maxBeliefs {
			// The cap cut the loop short with ops still unprocessed: staged owner
			// chat refs among them may be uncited this run, so the caller holds the
			// chat-turn floor for a re-scan (M3).
			capHit = true
			break
		}
		node, applied, mathRejected := p.applyBeliefOp(op, candidatesByID, inputSet, now)
		if mathRejected {
			rejected++
		}
		if !applied {
			continue
		}
		nodes = append(nodes, node)
		ids = append(ids, node.ID)
		touched++
	}
	// Observability: an aggregate so a run that proposed many ops but applied few
	// (systemic rank-math rejection) is visible, not silent.
	p.logf("memory: beliefs: proposed=%d applied=%d rejected=%d cap_hit=%t", len(ops.Ops), touched, rejected, capHit)

	if len(nodes) == 0 {
		return 0, rejected, capHit, usage, nil
	}
	msg := CommitMsg{
		Op:      "beliefs",
		Summary: fmt.Sprintf("%d beliefs revised", len(nodes)),
		Cause:   "beliefs",
		NodeIDs: ids,
	}
	if _, err := p.vault.WriteNodes(nodes, msg); err != nil {
		return 0, rejected, capHit, usage, err
	}
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, n, nowStr); err != nil {
			// Index-mirror consistency: return the error so the step is recorded
			// as error; reconcile self-heals the missed mirror next run.
			return touched, rejected, capHit, usage, err
		}
	}
	return touched, rejected, capHit, usage, nil
}

// applyBeliefOp disposes of one proposed op through the rank math and returns
// the node to write, whether the op was applied, and whether it was rejected by
// the rank math specifically. Invented-only evidence, an unknown belief, or an
// unresolvable propose-new subject yield applied=false with mathRejected=false;
// a transition the rank math refuses yields mathRejected=true (counted into
// RunStats.BeliefOpsRejected).
func (p *Pipeline) applyBeliefOp(op beliefOpJSON, candidatesByID map[string]Node, inputSet map[string]bool, now time.Time) (node Node, applied, mathRejected bool) {
	// Two-stage validation. First MEM-08/MEM-01: the ref must be in the model's
	// input set (episode provenance + any owner chat turns staged this run) or it
	// is invented and dropped. Then MEM-09: a chat: ref must additionally resolve
	// to a role='user' Discuss turn before newEvidenceLines can mint it at owner
	// rank — so DB existence alone never mints owner rank, only a ref the model
	// received AND that is a genuine owner turn does.
	kept, dropped := validateMarkers(inputSet, op.Evidence)
	kept, chatDropped := p.validateChatRefs(kept)
	dropped += chatDropped
	if dropped > 0 {
		p.logf("memory: beliefs: op %q evidence_rejected=%d (MEM-01/09)", op.Op, dropped)
	}
	if len(kept) == 0 {
		return Node{}, false, false // invented-only / evidence-less op is a no-op
	}

	switch beliefOp(op.Op) {
	case opProposeNew:
		n, ok := p.applyProposeNew(op, kept, now)
		return n, ok, false
	case opConfirm, opWeaken, opShake, opRetire:
		return p.applyExistingOp(op, candidatesByID, kept, now)
	default:
		p.logf("memory: beliefs: unknown op %q", op.Op)
		return Node{}, false, false
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
func (p *Pipeline) applyExistingOp(op beliefOpJSON, candidatesByID map[string]Node, kept []episodeRef, now time.Time) (node Node, applied, mathRejected bool) {
	node, ok := candidatesByID[op.BeliefID]
	if !ok {
		return Node{}, false, false // out of scope / unknown belief id
	}
	newEv := newEvidenceLines(kept, beliefOp(op.Op))
	combined := append(weighAll(parseBeliefEvidence(node.Body, p.logf), now), weighAll(newEv, now)...)
	state := beliefState{Confidence: node.Confidence, Stability: node.Stability, Status: node.Status}
	next, decision := applyOp(state, beliefOp(op.Op), combined)
	if decision == opRejected {
		p.logf("memory: beliefs: op %q on %s rejected by rank math (decision=%s)", op.Op, op.BeliefID, decisionName(decision))
		return Node{}, false, true
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
		// Design §4 case (a): raise a dispute ONLY when the downgrade came from
		// MEM-06 fresh-owner protection — the secretary's evidence collided with
		// the owner's word. decideOp also downgrades a retire that merely lacks
		// preponderance on a belief with NO owner rank; that is routine hysteresis,
		// not a disagreement with the boss, and must not spam the inbox.
		// MEM-05 holds: memory_dispute_flags is memory-owned, never an inbox
		// table. Implicitly capped by beliefs_max (per-op loop). A flag-write
		// failure is logged, not fatal — the downgrade itself still applies
		// (mirrors reflection's isolated SetDisputePending).
		if hasFreshOwnerSupport(combined) {
			if serr := p.db.SetDisputePending(op.BeliefID, "owner-rank belief challenged"); serr != nil {
				p.logf("memory: beliefs: set dispute pending %s: %v", op.BeliefID, serr)
			}
		}
	}
	node.Body = appendHistory(node.Body, historyLine(now, cause, op.Rationale))
	return node, true, false
}

// decisionName renders an opDecision for a log line.
func decisionName(d opDecision) string {
	switch d {
	case opAllowed:
		return "allowed"
	case opDowngraded:
		return "downgraded"
	default:
		return "rejected"
	}
}

// chatRefPrefix marks an evidence channel_id as a Discuss chat reference
// ("chat:<conversation_id>") rather than a Slack/Jira channel id — the seam
// that carries owner-authored provenance into the belief math.
const chatRefPrefix = "chat:"

// isChatRef reports whether an evidence ref points at a Discuss chat turn.
func isChatRef(channelID string) bool {
	return strings.HasPrefix(channelID, chatRefPrefix)
}

// isActRef reports whether an evidence ref points at a mechanical owner
// interaction ("act:<table>:<row_id>", Phase-5 5D) — the seam that carries an
// owner-action-rank data point into the belief math.
func isActRef(channelID string) bool {
	return strings.HasPrefix(channelID, actRefPrefix)
}

// newEvidenceLines turns validated model refs into stored evidence lines.
// Support direction follows the op (confirm/propose-new support the belief, the
// rest weigh against). Rank is minted by CODE, never the model (MEM-08/09/15):
// an episode ref (bare channel or mail:) is observed rank; a chat: ref is owner
// rank; an act: ref is owner-action rank — but a chat:/act: ref only reaches
// here after validateChatRefs confirmed it resolves (a role='user' Discuss turn
// / a real whitelisted interaction row), so the elevation is authored by the
// code path keyed on the ref scheme, never named by the model (the op JSON
// carries no rank field).
func newEvidenceLines(refs []episodeRef, op beliefOp) []beliefEvidence {
	support := op == opConfirm || op == opProposeNew
	out := make([]beliefEvidence, len(refs))
	for i, r := range refs {
		rank := rankObserved
		switch {
		case isChatRef(r.ChannelID):
			rank = rankOwner // MEM-09: validated owner Discuss turn
		case isActRef(r.ChannelID):
			rank = rankOwnerAction // MEM-15: validated owner interaction row
		}
		out[i] = beliefEvidence{Rank: rank, Support: support, ChannelID: r.ChannelID, TS: r.TS}
	}
	return out
}

// validateChatRefs enforces the write-time authenticity check on the belief
// pass's SURFACE refs — chat: (MEM-09 owner-authenticity) and act: (MEM-15
// owner-interaction existence). Episode refs (bare channel / mail:) pass through
// untouched — they were already validated against the model's input set
// (validateMarkers, MEM-08) and carry no authenticity claim. A chat: ref is kept
// only if it resolves to a role='user' situation Discuss turn; an act: ref only
// if it points at a real whitelisted interaction row — otherwise each is dropped
// and counted exactly like an invented episode ref (MEM-01 discipline), so
// newEvidenceLines can only ever mint owner/owner-action rank for a
// resolver-confirmed ref. The check is non-fatal: a lookup error drops that ref
// and keeps the pass alive, never freezing the run (these surfaces are soft
// owner-writebacks re-scanned next run — unlike the episode extractor's fatal
// MEM-01 lookup freeze).
func (p *Pipeline) validateChatRefs(refs []episodeRef) (kept []episodeRef, dropped int) {
	p.chatChecker.reset() // one ChatTablesPresent round-trip per call, not per chat ref
	for _, r := range refs {
		if !isChatRef(r.ChannelID) && !isActRef(r.ChannelID) {
			kept = append(kept, r)
			continue
		}
		// The resolver's existence check IS the authenticity check; a lookup error
		// is a soft drop (a soft owner-writeback, re-scanned next run — never a
		// run-freezing MEM-01 error). registered is always true here (chat:/act:
		// are registered schemes).
		ok, _, err := p.registry.Validate(r)
		if err != nil || !ok {
			dropped++
			continue
		}
		kept = append(kept, r)
	}
	return kept, dropped
}

// parseChatRef splits a "chat:<conversation_id>" channel id and its whole-second
// ts into the ints the owner-turn lookup needs. A malformed id/ts yields ok=false.
func parseChatRef(channelID, ts string) (convID, tsSec int64, ok bool) {
	convID, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(channelID, chatRefPrefix)), 10, 64)
	if err != nil {
		return 0, 0, false
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(ts), 64)
	if err != nil {
		return 0, 0, false
	}
	return convID, int64(f), true
}

func weighAll(ev []beliefEvidence, now time.Time) []evidence {
	out := make([]evidence, len(ev))
	for i, e := range ev {
		out[i] = e.weigh(now)
	}
	return out
}

// parseBeliefEvidence reads a belief node's canonical "## Evidence" lines
// ("- <rank> <for|against> <channel_id> <ts>"). A bullet that does not match
// the canonical 4-field shape (e.g. a prose evidence note) is logged and
// skipped rather than dropped silently — silently ignored evidence would
// weaken MEM-06's owner-rank protection, which only holds when owner support
// is written as a canonical line.
func parseBeliefEvidence(body string, logf func(string, ...any)) []beliefEvidence {
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
			logf("memory: beliefs: unparseable evidence line %q (want '- <rank> <for|against> <channel_id> <ts>'); ignored", trimmed)
			continue
		}
		rank, ok := parseEvidenceRank(fields[0])
		if !ok {
			logf("memory: beliefs: unknown evidence rank %q in %q; ignored", fields[0], trimmed)
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

// ownerActionsBlock is the prebuilt OWNER ACTIONS render for the belief pass
// (Phase-5 5D): one line per staged owner interaction and one engagement
// aggregate per distinct subject. Built only behind memory.semantic.preferences;
// a nil block renders nothing (gate-off byte-identity).
type ownerActionsBlock struct {
	lines      []string // "act:<table>:<id> <ts>: <bullet> (re <subject ids>)"
	engagement []string // "<subject id>: engaged N, dismissed M"
}

// buildOwnerActionsBlock renders the staged owner actions plus per-subject
// engagement aggregates (p.db.GetEngagement) for the OWNER ACTIONS prompt block.
// Subjects are gathered in first-seen order across the actions; a GetEngagement
// error drops that subject's aggregate line (logged) and never fails the pass.
func (p *Pipeline) buildOwnerActionsBlock(actions []stagedAction) *ownerActionsBlock {
	oab := &ownerActionsBlock{}
	seen := map[string]bool{}
	var subjects []string
	for _, a := range actions {
		oab.lines = append(oab.lines, fmt.Sprintf("%s %d: %s (re %s)", a.ref, a.tsUnix, a.text, strings.Join(a.subjects, ", ")))
		for _, s := range a.subjects {
			if !seen[s] {
				seen[s] = true
				subjects = append(subjects, s)
			}
		}
	}
	for _, s := range subjects {
		engaged, dismissed, err := p.db.GetEngagement(s)
		if err != nil {
			p.logf("memory: beliefs: owner-actions engagement %s: %v — line dropped", s, err)
			continue
		}
		oab.engagement = append(oab.engagement, fmt.Sprintf("%s: engaged %d, dismissed %d", s, engaged, dismissed))
	}
	return oab
}

// buildReviseBeliefsPrompt renders the belief pass call: the language directive
// fills the template's single %s slot; the user message digests the existing
// beliefs (id/statement/confidence/evidence), the known subjects a propose-new
// op may name, then the new episodes. It never opens with a "-"/"--" line (the
// claude-CLI argv gotcha). ownerActions is nil unless memory.semantic.preferences
// staged an OWNER ACTIONS block — nil renders nothing (gate-off byte-identity).
func buildReviseBeliefsPrompt(tmpl, lang string, beliefs, knownSubjects, episodes []Node, statements []ownerStatement, ownerActions *ownerActionsBlock) (system, user string) {
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
	// Known subjects: the only ids a propose-new op's "subject" may name. Shown
	// as id+title pairs so the model copies one verbatim rather than inventing
	// a readable slug that can never resolve (Resolve requires an exact node ID
	// or alias match — see applyProposeNew).
	b.WriteString("\nKnown subjects (propose-new's subject must be one of these EXACT ids, copied verbatim):\n\n")
	if len(knownSubjects) == 0 {
		b.WriteString("(none — do not propose-new this run)\n")
	}
	for _, s := range knownSubjects {
		fmt.Fprintf(&b, "%s: %s\n", s.ID, s.Title)
	}
	// OWNER SAID: verbatim owner Discuss turns staged this run (Phase-4 chat
	// surface). These are the ONLY owner-asserted input in the belief pass — the
	// model may cite a "chat:<id> <ts>" ref to weigh a belief with owner rank;
	// the code mints the rank, the model only chooses the direction (MEM-09).
	if len(statements) > 0 {
		b.WriteString("\nOWNER SAID (verbatim, ranked owner — cite as `chat:<id> <ts>` to weigh a belief):\n\n")
		for _, s := range statements {
			fmt.Fprintf(&b, "chat:%d %d: %s\n", s.conversationID, s.turnTS, s.text)
		}
	}
	// OWNER ACTIONS: this run's mechanical owner interactions (Phase-5 5D, dark
	// behind memory.semantic.preferences). These are ranked owner-action — weaker
	// than the owner's own words — so the code mints owner-action rank for a cited
	// `act:<table>:<id> <ts>` ref; the model only chooses the direction. A nil
	// block renders nothing, keeping gate-off output byte-identical.
	if ownerActions != nil {
		b.WriteString("\nOWNER ACTIONS (this run's mechanical owner interactions, ranked owner-action — weaker than the owner's words; cite as `act:<table>:<id> <ts>` to weigh a belief):\n\n")
		for _, l := range ownerActions.lines {
			b.WriteString(l + "\n")
		}
		if len(ownerActions.engagement) > 0 {
			b.WriteString("\nEngagement so far (per subject — trend context the single actions cannot carry):\n")
			for _, e := range ownerActions.engagement {
				b.WriteString(e + "\n")
			}
		}
		b.WriteString("\nForming a preference belief about the owner (\"the owner does / does not …\") is an ordinary propose-new: its `subject` MUST be one of the EXACT Known-subject ids above, copied verbatim. Do NOT over-read a single dismissal — prefer patterns the engagement counts support.\n")
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

// HistoryBullet is one parsed "## History" line — the inverse of historyLine.
// Cause has any trailing " (downgraded)" suffix stripped so a downgraded op is
// classified by its base op; Rationale is the free text after the em dash ("" if
// absent).
type HistoryBullet struct {
	Date      string // "YYYY-MM-DD"
	Cause     string
	Rationale string
}

// ParseHistory parses a node body's "## History" section into its bullets in
// file order (oldest first) — the single reader shared by the briefing revision
// journal (historyEntriesSince) and the reflection churn counter
// (historyChurnSince). Only canonical bullets ("- YYYY-MM-DD: cause[ —
// rationale]", as historyLine writes them) are returned; anything else in the
// section is skipped.
func ParseHistory(body string) []HistoryBullet {
	var out []HistoryBullet
	inHistory := false
	for _, raw := range strings.Split(body, "\n") {
		if strings.HasPrefix(raw, "## ") {
			inHistory = strings.TrimSpace(raw) == "## History"
			continue
		}
		if !inHistory {
			continue
		}
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, "- ") {
			continue
		}
		rest := strings.TrimPrefix(line, "- ")
		colon := strings.Index(rest, ": ")
		if colon != len("2006-01-02") {
			continue
		}
		cause, rationale := splitCauseRationale(strings.TrimSpace(rest[colon+2:]))
		out = append(out, HistoryBullet{Date: rest[:colon], Cause: cause, Rationale: rationale})
	}
	return out
}

// splitCauseRationale splits "cause — rationale" (em dash) into the op cause and
// its digest, stripping a trailing " (downgraded)" so a downgraded op is still
// classified by its base op. A cause without a dash has an empty rationale.
func splitCauseRationale(rest string) (cause, rationale string) {
	if idx := strings.Index(rest, " — "); idx >= 0 {
		cause = strings.TrimSpace(rest[:idx])
		rationale = strings.TrimSpace(rest[idx+len(" — "):])
	} else {
		cause = strings.TrimSpace(rest)
	}
	cause = strings.TrimSuffix(cause, " (downgraded)")
	return cause, rationale
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
	case rankOwnerAction:
		return "owner-action"
	case rankObserved:
		return "observed"
	default:
		return "inferred"
	}
}
