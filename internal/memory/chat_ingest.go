package memory

import (
	"fmt"
	"strconv"
	"strings"
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

// stagedChat is the owner Discuss evidence ingestChatStatements folded for THIS
// run's belief pass: the verbatim statements for the OWNER SAID prompt block,
// the chat: ref keys to admit into the belief-pass input set, and the union of
// entity ids to widen the candidate scope by.
type stagedChat struct {
	statements []ownerStatement
	refs       map[string]bool
	subjects   map[string]bool
}

// mergeStaged unions two staged-input sets for the belief pass — the Phase-4
// chat turns and the Phase-5 act: interaction refs. Either may be nil. The chat
// set (a) is mutated in place and returned; only chat turns carry verbatim
// statements (the act path stages refs + subjects only, never OWNER SAID prose).
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
func (p *Pipeline) ingestChatStatements(floor int64) (staged *stagedChat, newFloor int64, err error) {
	turns, err := p.db.ListOwnerChatTurns(floor)
	if err != nil {
		return nil, floor, err
	}
	if len(turns) == 0 {
		return nil, floor, nil
	}

	newFloor = floor
	sc := &stagedChat{refs: map[string]bool{}, subjects: map[string]bool{}}
	for _, t := range turns {
		// Resolve the turn's situation BEFORE advancing the floor: a genuine DB
		// error mapping the situation must NOT consume the turn (freeze the whole
		// ingest and re-scan next run — the ingest-floor "advance only past
		// fully-processed" discipline). Turns are id-ascending, so returning here
		// leaves every turn at/above this one to be re-scanned.
		subjects, serr := p.situationSubjects(t.SituationID)
		if serr != nil {
			return nil, floor, fmt.Errorf("memory: chat ingest: situation %s: %w", t.SituationID, serr)
		}
		if t.ID > newFloor {
			newFloor = t.ID // consumed: advance past it whether or not it maps to an entity
		}
		if len(subjects) == 0 {
			// An owner turn about a situation memory has no entity for: consumed
			// (the floor advances) but nothing to stage. Logged rather than silent
			// so a systemically unmappable owner is visible.
			p.logf("memory: chat ingest: turn %d (situation %s) maps to no memory entity — consumed, not staged", t.ID, t.SituationID)
			continue
		}
		text := strings.Join(strings.Fields(t.Text), " ")
		if text == "" {
			continue
		}
		st := ownerStatement{conversationID: t.ConversationID, turnTS: t.TurnTS, text: text, subjects: subjects}
		sc.statements = append(sc.statements, st)
		sc.refs[st.refKey()] = true
		for _, s := range subjects {
			sc.subjects[s] = true
		}
	}
	if len(sc.statements) == 0 {
		// Turns were scanned but none mapped to an entity: advance the floor (they
		// are consumed) but stage nothing for the belief pass.
		return nil, newFloor, nil
	}
	return sc, newFloor, nil
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
// context_id (Atoi failure) is a normal no-entity case, not an error. Per-signal
// Resolve misses (a channel/user with no memory alias) are ordinary skips.
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
	seen := map[string]bool{}
	var out []string
	add := func(ref string) {
		if ref == "" {
			return
		}
		n, rerr := Resolve(p.vault, p.db, ref)
		if rerr != nil || n.Type != "entity" {
			return
		}
		if !seen[n.ID] {
			seen[n.ID] = true
			out = append(out, n.ID)
		}
	}
	for _, sig := range signals {
		add(sig.ChannelID)
		add(sig.SenderUserID)
	}
	return out, nil
}
