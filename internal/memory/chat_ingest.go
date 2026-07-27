package memory

import (
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// ownerStatement is one owner-authored Discuss turn staged for the belief pass:
// its verbatim text plus the "chat:<conversation_id> <ts>" evidence ref the
// model may cite. subjects are the memory entity ids the turn's situation maps
// to (its channels + members resolved against memory_aliases) — the belief-pass
// candidates the statement can bear on.
type ownerStatement struct {
	conversationID int64
	turnTS         int64
	text           string
	subjects       []string
}

// refKey is the "chat:<id> <ts>" input-set key for the statement's evidence ref.
func (s ownerStatement) refKey() string {
	return fmt.Sprintf("%s%d %d", chatRefPrefix, s.conversationID, s.turnTS)
}

// stagedAction is one mechanical owner interaction (Phase-5 5D) folded for THIS
// run's belief pass: its "act:<table>:<id>" evidence ref, the interaction ts
// (whole unix seconds, rendered next to the ref so the model may cite
// "act:<table>:<id> <ts>"), the human-readable bullet describing the action, and
// the memory entity ids the interaction's situation maps to. Rendered into the
// OWNER ACTIONS prompt block only behind memory.semantic.preferences.
type stagedAction struct {
	ref      string
	tsUnix   int64
	text     string
	subjects []string
}

// stagedChat is the owner Discuss evidence ingestChatStatements folded for THIS
// run's belief pass: the verbatim statements for the OWNER SAID prompt block,
// the chat:/act: ref keys to admit into the belief-pass input set, the union of
// entity ids to widen the candidate scope by, and — from the Phase-5 act path —
// the owner-action descriptions rendered into the OWNER ACTIONS block.
type stagedChat struct {
	statements []ownerStatement
	actions    []stagedAction
	refs       map[string]bool
	subjects   map[string]bool
}

// mergeStaged unions two staged-input sets for the belief pass — the Phase-4
// chat turns and the Phase-5 act: interaction refs. Either may be nil. The chat
// set (a) is mutated in place and returned. Only chat turns carry verbatim OWNER
// SAID statements; the act path carries refs + subjects PLUS owner-action
// descriptions (the OWNER ACTIONS block, rendered only behind
// memory.semantic.preferences).
func mergeStaged(a, b *stagedChat) *stagedChat {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	for r := range b.refs {
		a.refs[r] = true
	}
	for s := range b.subjects {
		a.subjects[s] = true
	}
	a.statements = append(a.statements, b.statements...)
	a.actions = append(a.actions, b.actions...)
	return a
}

// ingestChatStatements is the mechanical head of the Phase-4 chat surface
// (MEM-09): it scans owner Discuss turns (role='user') in situation
// conversations above the chat-turn floor, maps each turn's situation to the
// memory entities its channels/members alias, and stages the turns as
// owner-rank evidence input for the belief pass. It makes NO AI call of its own
// — interpretation stays in memory.revise_beliefs.
//
// It does NOT persist the floor: it returns the new floor value (the max
// chat_messages.id scanned), and the caller advances MemoryChatTurnFloor only
// after the belief pass commits, so a failed or budget-skipped pass re-scans the
// same turns next run (the ingest-floor "advance after success" discipline). The
// Swift-owned chat tables are absent on a headless daemon; that is a clean no-op
// (nil staged, floor unchanged). A turn whose situation resolves to no entity is
// still consumed (the floor advances past it) but stages nothing.
func (p *Pipeline) ingestChatStatements(floor int64, contextTypes []string) (staged *stagedChat, newFloor int64, err error) {
	turns, err := p.db.ListOwnerChatTurns(floor, contextTypes)
	if err != nil {
		return nil, floor, err
	}
	if len(turns) == 0 {
		return nil, floor, nil
	}

	newFloor = floor
	sc := &stagedChat{refs: map[string]bool{}, subjects: map[string]bool{}}
	for _, t := range turns {
		// Resolve the turn's context subjects BEFORE advancing the floor: a genuine
		// DB error mapping the context must NOT consume the turn (freeze the whole
		// ingest and re-scan next run — the ingest-floor "advance only past
		// fully-processed" discipline). Turns are id-ascending, so returning here
		// leaves every turn at/above this one to be re-scanned.
		consumed, serr := p.stageChatTurn(t, sc)
		if serr != nil {
			return nil, floor, serr
		}
		if consumed > newFloor {
			newFloor = consumed // consumed: advance past it whether or not it mapped to an entity
		}
	}
	if len(sc.statements) == 0 {
		// Turns were scanned but none mapped to an entity: advance the floor (they
		// are consumed) but stage nothing for the belief pass.
		return nil, newFloor, nil
	}
	return sc, newFloor, nil
}

// stageChatTurn resolves one owner chat turn's context subjects and, when it
// stages as a world statement (a situation turn always; a target/track turn
// only behind the "remember this" command), appends it to sc. It returns the
// turn id — the caller advances the floor to it whether or not the turn
// staged, per the consumed-not-staged discipline — or a non-nil error when
// subject resolution itself failed (the caller must NOT advance the floor on
// error, so the turn and everything after it re-scans next run).
func (p *Pipeline) stageChatTurn(t db.OwnerChatTurn, sc *stagedChat) (turnID int64, err error) {
	subjects, serr := p.chatSubjects(t.ContextType, t.ContextID)
	if serr != nil {
		return 0, fmt.Errorf("memory: chat ingest: %s %s: %w", t.ContextType, t.ContextID, serr)
	}
	if len(subjects) == 0 {
		// An owner turn about a context memory has no entity for: consumed
		// (the floor advances) but nothing to stage. Logged rather than silent
		// so a systemically unmappable owner is visible.
		p.logf("memory: chat ingest: turn %d (%s %s) maps to no memory entity — consumed, not staged", t.ID, t.ContextType, t.ContextID)
		return t.ID, nil
	}
	// Per-type staging rule (resolved ambiguity #5): a situation turn stages
	// every owner turn (Phase-4, unchanged); a target/track turn is an ordinary
	// drafting instruction unless it opens with the "remember this" command, so
	// only a commanded target/track turn stages as a world statement. Either way
	// the prefix is stripped for the verbatim statement text.
	statement, commanded := parseRememberCommand(t.Text)
	if t.ContextType != "situation" && !commanded {
		// An ordinary target/track drafting turn: consumed (the floor advanced
		// above) but not staged — the "remember this" command is the opt-in.
		p.logf("memory: chat ingest: turn %d (%s %s) is not a \"remember this\" command — consumed, not staged", t.ID, t.ContextType, t.ContextID)
		return t.ID, nil
	}
	if !commanded {
		statement = t.Text // situation turn without the command: stage verbatim
	}
	text := strings.Join(strings.Fields(statement), " ")
	if text == "" {
		return t.ID, nil
	}
	st := ownerStatement{conversationID: t.ConversationID, turnTS: t.TurnTS, text: text, subjects: subjects}
	sc.statements = append(sc.statements, st)
	sc.refs[st.refKey()] = true
	for _, s := range subjects {
		sc.subjects[s] = true
	}
	return t.ID, nil
}

// rememberCommandPrefixes are the case-insensitive opt-in prefixes that turn a
// target/track drafting turn into a staged world statement. "remember this:" is
// listed first, but neither is a prefix of the other, so match order is
// immaterial.
var rememberCommandPrefixes = []string{"remember this:", "remember:"}

// parseRememberCommand reports whether text opens with a "remember this" command
// (case-insensitive, after trimming leading/trailing space) and returns the
// remainder as the verbatim statement (original case preserved). A no-prefix
// text, a prefix-only turn, or an empty remainder yields ok=false. A pure
// function — the opt-in ingestion trigger for the generalized target/track chats
// (resolved ambiguity #5).
func parseRememberCommand(text string) (statement string, ok bool) {
	trimmed := strings.TrimSpace(text)
	lower := strings.ToLower(trimmed)
	for _, prefix := range rememberCommandPrefixes {
		if strings.HasPrefix(lower, prefix) {
			statement = strings.TrimSpace(trimmed[len(prefix):])
			return statement, statement != ""
		}
	}
	return "", false
}

// chatSubjects maps a Discuss conversation's context to the memory entity ids an
// owner statement in it can bear on — the per-context-type generalization of the
// Phase-4 situationSubjects (resolved ambiguities #7/#8). It dispatches on
// contextType:
//   - situation → its signals' channels + members (today's path, unchanged);
//   - track → its channel_ids + participants + assignee/requester/owner user ids;
//   - target → the entities of its linked track(s) (tracks.linked_target_id),
//     unioned; a bare target with no linked track maps to nothing.
//
// All reads are MEM-05-clean (situations/tracks/targets are READ, never written).
// A genuine DB read failure returns an error (the caller holds the floor and
// re-scans); a no-entity mapping is (nil, nil) so the caller consumes the turn.
func (p *Pipeline) chatSubjects(contextType, contextID string) ([]string, error) {
	switch contextType {
	case "situation":
		return p.situationSubjects(contextID)
	case "track":
		return p.trackSubjects(contextID)
	case "target":
		return p.targetSubjects(contextID)
	default:
		return nil, nil // an unknown context type maps to nothing (consumed, not staged)
	}
}

// situationSubjects resolves a situation's signal channels and member user ids
// to the memory entity ids they alias (via memory_aliases / Resolve), deduped —
// the belief subjects an owner statement in that situation can bear on. Reading
// situations/situation_signals is MEM-05-clean: memory only READS inbox tables
// (as IngestSituations already does), it never writes them.
//
// It distinguishes a genuine no-entity mapping (an owner turn about a situation
// memory holds no entity for — empty slice with no error, so the caller consumes
// the turn) from a real DB read failure (returns an error, the caller holds the
// floor so the turn is re-scanned rather than silently dropped). A non-situation
// context_id (Atoi failure) is a normal no-entity case, not an error.
func (p *Pipeline) situationSubjects(situationID string) ([]string, error) {
	sid, convErr := strconv.Atoi(strings.TrimSpace(situationID))
	if convErr != nil {
		// A non-numeric context_id is not a situation id — a normal no-entity
		// case, deliberately not an error (the turn is consumed, nothing staged).
		return nil, nil //nolint:nilerr
	}
	signals, err := p.db.ListSituationSignals(sid)
	if err != nil {
		return nil, fmt.Errorf("listing signals: %w", err)
	}
	var refs []string
	for _, sig := range signals {
		refs = append(refs, sig.ChannelID, sig.SenderUserID)
	}
	return p.resolveSubjectRefs(refs), nil
}

// trackSubjects resolves a track's OWN entity mirror (track:<id> — 5C, present
// only behind memory.sources.operational) plus its channel_ids + participant/
// assignee/requester/owner user ids to memory entity ids (deduped, mirror
// first). A non-numeric context id is a normal no-entity case; a DB read error
// propagates (the caller holds the floor). When the mirror does not exist,
// resolveSubjectRefs silently skips its unresolved alias — byte-identical to
// the pre-mirror (slice-2) behavior.
func (p *Pipeline) trackSubjects(trackID string) ([]string, error) {
	tid, convErr := strconv.Atoi(strings.TrimSpace(trackID))
	if convErr != nil {
		return nil, nil //nolint:nilerr
	}
	refs, err := p.db.TrackSubjectRefs(tid)
	if err != nil {
		return nil, fmt.Errorf("track subjects: %w", err)
	}
	allRefs := append([]string{trackMirrorAlias(tid)}, refs...)
	return p.resolveSubjectRefs(allRefs), nil
}

// targetSubjects prepends the target's OWN entity mirror (target:<id> — 5C,
// present only behind memory.sources.operational) to the union of its linked
// track(s)' entities (tracks.linked_target_id). Before mirrors existed, targets
// carried no channels/members of their own, so the linked track was the only
// mechanical mapping (resolved ambiguity #7); now a bare target with no linked
// track still maps to its own mirror when one exists, and to nothing when it
// does not — resolveSubjectRefs silently skips the unresolved alias, so gate-off
// / mirror-absent behavior is byte-identical to slice 2.
func (p *Pipeline) targetSubjects(targetID string) ([]string, error) {
	tid, convErr := strconv.Atoi(strings.TrimSpace(targetID))
	if convErr != nil {
		return nil, nil //nolint:nilerr
	}
	trackIDs, err := p.db.TrackIDsForTarget(tid)
	if err != nil {
		return nil, fmt.Errorf("target subjects: %w", err)
	}
	seen := map[string]bool{}
	var out []string
	for _, id := range p.resolveSubjectRefs([]string{targetMirrorAlias(tid)}) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	for _, tkID := range trackIDs {
		refs, rerr := p.db.TrackSubjectRefs(tkID)
		if rerr != nil {
			return nil, fmt.Errorf("target subjects: track %d: %w", tkID, rerr)
		}
		for _, id := range p.resolveSubjectRefs(refs) {
			if !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
	}
	return out, nil
}

// resolveSubjectRefs resolves raw refs (channel ids, user ids) to the distinct
// memory entity ids they alias, in first-seen order — the shared tail of every
// chatSubjects branch. A ref with no memory alias, or one that resolves to a
// non-entity, is an ordinary skip.
func (p *Pipeline) resolveSubjectRefs(refs []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, ref := range refs {
		if ref == "" {
			continue
		}
		n, rerr := Resolve(p.vault, p.db, ref)
		if rerr != nil || n.Type != "entity" {
			continue
		}
		if !seen[n.ID] {
			seen[n.ID] = true
			out = append(out, n.ID)
		}
	}
	return out
}
