package coach

import (
	"database/sql"
	"strconv"
	"time"

	"watchtower/internal/db"
)

// maxImportTitleRunes cuts a carried suggestion's text to a title.
const maxImportTitleRunes = 80

// ImportSuggestions is the one-time fold of the instruction miner into the
// coach (spec 2026-10-28 §6). It acts only on open suggestions not yet moved
// and leaves none behind, so after its first run it is a no-op (nothing writes
// new suggestions any more). In one transaction the newest rows (by
// last_seen_at) that fit the free slots (maxOpen − open proposals), whose
// destination no open proposal edits, and whose appended text passes
// ValidateAfter become open "add" proposals to the same text; each such row's
// moved_to is its proposal id, every other open row's -1 (its owner lines stay
// coach signals). No model call. It returns the proposals written.
func ImportSuggestions(main *db.DB, lang string, now time.Time) (int, error) {
	return main.FoldInstructionSuggestions(now, func(open []db.CoachProposal, s db.InstructionSuggestion, before string) (db.CoachProposal, bool) {
		return suggestionProposal(open, s, before, lang)
	})
}

// suggestionProposal builds the proposal a suggestion folds into, or false
// when it is retired: no free slot, a busy or unknown destination, a chat
// suggestion bound to a workbench, or a text that fails validation.
func suggestionProposal(open []db.CoachProposal, s db.InstructionSuggestion, before, lang string) (db.CoachProposal, bool) {
	if len(open) >= maxOpen {
		return db.CoachProposal{}, false
	}
	var dest string
	switch s.Field {
	case db.InstructionSession:
		dest = DestSession
	case db.InstructionProcedure:
		dest = DestProcedure
	case db.InstructionChat:
		if s.WorkbenchID.Valid { // the chat text is global only; never redirected
			return db.CoachProposal{}, false
		}
		dest = DestChat
	default:
		return db.CoachProposal{}, false
	}
	key := keyOf(dest, nullID(s.WorkbenchID), "")
	for _, p := range open {
		if keyOf(p.Destination, p.WorkbenchID, p.PromptID) == key { // accepting one would supersede the other
			return db.CoachProposal{}, false
		}
	}
	t := CurrentText{Destination: dest, WorkbenchID: key.wb, Text: before, Budget: BudgetOf(dest, before)}
	after, ok := applyEdit(t, "", s.Text)
	if !ok || !kindFits("add", before, after) || ValidateAfter(t, after) != nil {
		return db.CoachProposal{}, false
	}
	fp, changed := fingerprint(key, before, after)
	if !changed {
		return db.CoachProposal{}, false
	}
	return db.CoachProposal{Fingerprint: fp, Kind: "add", Destination: dest, WorkbenchID: key.wb,
		Title: cutRunes(oneLine(s.Text), maxImportTitleRunes), Why: importWhy(lang, s.SessionCount),
		Metric: "owner_loop", BeforeText: before, AfterText: after,
		Evidence: []db.CoachEvidence{{Kind: "suggestion", Ref: "sg:" + strconv.FormatInt(s.ID, 10)}},
		Sources:  s.SessionCount}, true
}

func nullID(n sql.NullInt64) int64 {
	if n.Valid {
		return n.Int64
	}
	return 0
}
