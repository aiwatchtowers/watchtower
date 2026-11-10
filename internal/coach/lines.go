package coach

import (
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/logredact"
)

// lineDestinations keep their text as database rows, one line per row tagged
// with the proposal that added it: a prompt's additions and a pack skill's
// overlay. Edits are whole lines; the text is the rows joined, one per line.
var lineDestinations = map[string]bool{DestPromptAdd: true, DestPackOverlay: true}

// lineRow is one row of a line destination.
type lineRow struct {
	ID         int64
	Text       string
	ProposalID int64
}

// lineStore reads and edits the rows of one line destination; edit removes
// removeIDs and adds add in one transaction and returns the added ids.
type lineStore struct {
	list func() ([]lineRow, error)
	edit func(removeIDs []int64, add []lineRow, now time.Time) ([]int64, error)
}

// linesOf is the store of p's line destination.
func (a *Applier) linesOf(p db.CoachProposal) lineStore {
	if p.Destination == DestPackOverlay {
		return lineStore{
			list: func() ([]lineRow, error) {
				rows, err := a.DB.ListSkillPackOverlays(p.Skill)
				out := make([]lineRow, len(rows))
				for i, r := range rows {
					out[i] = lineRow{ID: r.ID, Text: r.Text, ProposalID: r.ProposalID}
				}
				return out, err
			},
			edit: func(removeIDs []int64, add []lineRow, now time.Time) ([]int64, error) {
				rows := make([]db.SkillPackOverlay, len(add))
				for i, r := range add {
					rows[i] = db.SkillPackOverlay{Text: r.Text, ProposalID: r.ProposalID}
				}
				return a.DB.EditSkillPackOverlays(p.Skill, removeIDs, rows, now)
			},
		}
	}
	return lineStore{
		list: func() ([]lineRow, error) {
			rows, err := a.DB.ListPromptAdditions(p.PromptID)
			out := make([]lineRow, len(rows))
			for i, r := range rows {
				out[i] = lineRow{ID: r.ID, Text: r.Text, ProposalID: r.ProposalID}
			}
			return out, err
		},
		edit: func(removeIDs []int64, add []lineRow, now time.Time) ([]int64, error) {
			rows := make([]db.PromptAddition, len(add))
			for i, r := range add {
				rows[i] = db.PromptAddition{Text: r.Text, ProposalID: r.ProposalID}
			}
			return a.DB.EditPromptAdditions(p.PromptID, removeIDs, rows, now)
		},
	}
}

func joinLines(rows []lineRow) string {
	lines := make([]string, len(rows))
	for i, r := range rows {
		lines[i] = r.Text
	}
	return strings.Join(lines, "\n")
}

// linesStillHold is whether every row p added is still there with its text.
func (a *Applier) linesStillHold(p db.CoachProposal) (bool, error) {
	rows, err := a.linesOf(p).list()
	if err != nil {
		return false, err
	}
	added := linesAdded(p.BeforeText, p.AfterText)
	left := countLines(added)
	tagged := 0
	for _, r := range rows {
		if r.ProposalID != p.ID {
			continue
		}
		tagged++
		if k := strings.TrimSpace(r.Text); left[k] > 0 {
			left[k]--
			continue
		}
		return false, nil
	}
	return tagged == len(added), nil
}

// writeLines makes the destination's rows the lines of after: the rows whose
// text after still has are kept (in their order), the others removed, and the
// new lines added, tagged with this proposal.
func (a *Applier) writeLines(p db.CoachProposal, after string, now time.Time) (written, error) {
	store := a.linesOf(p)
	rows, err := store.list()
	if err != nil {
		return written{}, err
	}
	want := countLines(nonEmptyLines(after))
	var kept, removed []lineRow
	var removeIDs []int64
	for _, r := range rows {
		if k := strings.TrimSpace(r.Text); want[k] > 0 {
			want[k]--
			kept = append(kept, r)
			continue
		}
		removed = append(removed, r)
		removeIDs = append(removeIDs, r.ID)
	}
	have := map[string]int{}
	for _, r := range kept {
		have[strings.TrimSpace(r.Text)]++
	}
	var add []lineRow
	for _, line := range nonEmptyLines(after) {
		if have[line] > 0 {
			have[line]--
			continue
		}
		add = append(add, lineRow{Text: line, ProposalID: p.ID})
	}
	addedIDs, err := store.edit(removeIDs, add, now)
	if err != nil {
		return written{}, err
	}
	result := append(append([]lineRow{}, kept...), add...)
	return written{result: joinLines(result), undo: func() error {
		// Put the removed rows back with their own proposal tags.
		_, err := store.edit(addedIDs, removed, now)
		return err
	}}, nil
}

// restoreLines removes p's rows and re-adds the lines it removed, unless
// still there. Their original proposal tags are not stored, so they come back
// untagged.
func (a *Applier) restoreLines(p db.CoachProposal, now time.Time) error {
	store := a.linesOf(p)
	rows, err := store.list()
	if err != nil {
		return err
	}
	var removeIDs []int64
	left := map[string]int{}
	for _, r := range rows {
		if r.ProposalID == p.ID {
			removeIDs = append(removeIDs, r.ID)
			continue
		}
		left[strings.TrimSpace(r.Text)]++
	}
	gone := countLines(nonEmptyLines(p.BeforeText))
	for _, l := range nonEmptyLines(p.AfterText) {
		gone[l]--
	}
	var add []lineRow
	for _, l := range nonEmptyLines(p.BeforeText) {
		if gone[l] <= 0 {
			continue
		}
		gone[l]--
		if left[l] > 0 {
			left[l]--
			continue
		}
		add = append(add, lineRow{Text: l})
	}
	_, err = store.edit(removeIDs, add, now)
	return err
}

// rerenderPack brings every installed copy of pack skill to the shipped skill
// rendered with its overlay rows: <folder>/.claude/skills and
// <folder>/.agents/skills of each workbench, and <Home>/.claude/skills. A copy
// edited by hand is left as it is and counted as drifted (DEV-04); a missing
// copy is not created. The overlay rows are the truth: a folder that cannot be
// read or written is logged (a fingerprint, never a path) and skipped, and the
// next integrate or workbench open renders it.
func (a *Applier) rerenderPack(skill string) (updated, drifted int) {
	rows, err := a.DB.ListSkillPackOverlays(skill)
	if err != nil {
		log.Printf("coach: re-rendering pack skill %s: %s", skill, logredact.Body([]byte(err.Error())))
		return 0, 0
	}
	lines := make([]string, len(rows))
	for i, r := range rows {
		lines[i] = r.Text
	}
	count := func(st devpack.State) {
		switch st {
		case devpack.StateUpdated:
			updated++
		case devpack.StateDrifted:
			drifted++
		}
	}
	wbs, err := a.DB.ListWorkbenches()
	if err != nil {
		log.Printf("coach: re-rendering pack skill %s: listing workbenches: %s", skill, logredact.Body([]byte(err.Error())))
	}
	for _, wb := range wbs {
		if _, err := os.Stat(wb.FolderPath); errors.Is(err, fs.ErrNotExist) {
			continue // a folder that went away has nothing to render
		}
		for _, dir := range []string{filepath.Join(wb.FolderPath, ".claude", "skills"), filepath.Join(wb.FolderPath, ".agents", "skills")} {
			st, err := devpack.RerenderFolderSkill(wb.FolderPath, dir, skill, lines)
			if err != nil {
				log.Printf("coach: re-rendering pack skill %s in workbench %d: %s", skill, wb.ID, logredact.Body([]byte(err.Error())))
				continue
			}
			count(st)
		}
	}
	if a.Home != "" {
		st, err := devpack.RerenderSkill(filepath.Join(a.Home, ".claude", "skills"), skill, lines)
		if err != nil {
			log.Printf("coach: re-rendering pack skill %s in the home folder: %s", skill, logredact.Body([]byte(err.Error())))
		} else {
			count(st)
		}
	}
	return updated, drifted
}
