package coach

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

const (
	// judgeAfter is how long an accepted edit works before it is judged.
	judgeAfter = 14 * 24 * time.Hour
	// judgeGiveUp is when a still unmeasurable edit stops being retried: its
	// too_little_data verdict is then final.
	judgeGiveUp = 42 * 24 * time.Hour
	// judgeMinSessions is the sessions a period needs to be judged at all.
	judgeMinSessions = 5
	// judgeImprovement is the drop in the metric, against the baseline, that
	// counts as "works".
	judgeImprovement = 0.10
)

// Judge gives the accepted proposals a verdict by comparing the metric since
// the Accept with the baseline taken then. It shows correlation, not
// causation: other changes land in the same weeks. A proposal decided at least
// judgeAfter ago with no verdict, or with too_little_data (until judgeGiveUp),
// is measured over [decided_at, now): under judgeMinSessions sessions, no
// baseline or no value is too_little_data; a value at least judgeImprovement
// below the baseline is works; anything else is no_effect. A no_effect edit
// gets one mechanical cut proposal (no model call) when a slot is free. judged
// counts the works / no_effect verdicts, cuts the proposals written.
func Judge(d *db.DB, al *agentlogdb.DB, now time.Time) (judged, cuts int, err error) {
	home, _ := os.UserHomeDir() // "": the allow list is not read, no cut for it
	return judge(d, al, home, now)
}

func judge(d *db.DB, al *agentlogdb.DB, home string, now time.Time) (judged, cuts int, err error) {
	accepted, err := d.ListCoachProposals("accepted")
	if err != nil {
		return 0, 0, err
	}
	var errs []error
	for _, p := range accepted {
		if p.DecidedAt.IsZero() || now.Sub(p.DecidedAt) < judgeAfter {
			continue
		}
		if p.Verdict != "" && p.Verdict != "too_little_data" {
			continue
		}
		if p.Verdict == "too_little_data" && !p.VerdictAt.Before(p.DecidedAt.Add(judgeGiveUp)) {
			continue // final
		}
		verdict, value, err := verdictOf(d, al, p, now)
		if err != nil {
			errs = append(errs, fmt.Errorf("judging coach proposal %d: %w", p.ID, err))
			continue
		}
		if err := d.SetCoachVerdict(p.ID, verdict, value, now); err != nil {
			if !errors.Is(err, db.ErrCoachStateChanged) { // rolled back meanwhile
				errs = append(errs, fmt.Errorf("judging coach proposal %d: %w", p.ID, err))
			}
			continue
		}
		if verdict == "too_little_data" {
			continue
		}
		judged++
		if verdict != "no_effect" {
			continue
		}
		wrote, err := writeCut(d, al, home, p, now)
		if err != nil {
			errs = append(errs, fmt.Errorf("cutting coach proposal %d: %w", p.ID, err))
		}
		if wrote {
			cuts++
		}
	}
	return judged, cuts, errors.Join(errs...)
}

// verdictOf measures p's period and names the verdict and the measured value.
func verdictOf(d *db.DB, al *agentlogdb.DB, p db.CoachProposal, now time.Time) (string, *float64, error) {
	m, err := Measure(d, al, p.WorkbenchID, p.DecidedAt, now)
	if err != nil {
		return "", nil, err
	}
	v := m.Of(p.Metric)
	if m.Sessions < judgeMinSessions || p.Baseline == nil || !v.Known {
		return "too_little_data", nil, nil
	}
	if v.V <= *p.Baseline*(1-judgeImprovement) {
		return "works", &v.V, nil
	}
	return "no_effect", &v.V, nil
}

// writeCut stores the removal of a no_effect edit as an open proposal: the
// destination's current text minus exactly what the edit added. Nothing is
// written when no slot is free, another open proposal edits the same text, the
// added part is no longer in the text, or the destination cannot be read.
func writeCut(d *db.DB, al *agentlogdb.DB, home string, p db.CoachProposal, now time.Time) (bool, error) {
	open, err := d.ListCoachProposals("open")
	if err != nil {
		return false, err
	}
	if len(open) >= maxOpen {
		return false, nil
	}
	key := keyOf(p.Destination, p.WorkbenchID, p.PromptID)
	for _, o := range open {
		if keyOf(o.Destination, o.WorkbenchID, o.PromptID) == key {
			return false, nil
		}
	}
	cur, err := (&Applier{DB: d, AgentLog: al, Home: home}).readCurrent(p)
	if err != nil {
		if errors.Is(err, errNotSupported) {
			return false, nil
		}
		return false, err
	}
	after, ok := withoutEdit(p, cur.Text)
	if !ok {
		return false, nil
	}
	fp, changed := fingerprint(key, cur.Text, after)
	if !changed {
		return false, nil
	}
	id, err := d.InsertCoachProposal(db.CoachProposal{
		Fingerprint: fp, Kind: "cut", Destination: key.dest, WorkbenchID: key.wb, PromptID: key.prompt,
		Title: cutTitle(p.Title), Why: cutWhy(p), Metric: p.Metric,
		BeforeText: cur.Text, AfterText: after, Evidence: p.Evidence, Sources: p.Sources, RevertsID: p.ID,
	}, now)
	return id != 0, err
}

// withoutEdit is cur minus what p's edit added: for an owner text the added
// part (once, where it still appears exactly once), for a prompt's additions
// or the allow list the added lines. ok is false when none of it is left.
func withoutEdit(p db.CoachProposal, cur string) (string, bool) {
	switch p.Destination {
	case DestPromptAdd, DestSettingsAllow:
		drop := countLines(linesAdded(p.BeforeText, p.AfterText))
		var keep []string
		removed := false
		for _, l := range nonEmptyLines(cur) {
			if drop[l] > 0 {
				drop[l]--
				removed = true
				continue
			}
			keep = append(keep, l)
		}
		return strings.Join(keep, "\n"), removed
	}
	_, added := changedPart(p.BeforeText, p.AfterText)
	if strings.TrimSpace(added) == "" || strings.Count(cur, added) != 1 {
		return "", false
	}
	i := strings.Index(cur, added)
	end := i + len(added)
	// Take one line break with a part that is a whole line, so no blank line
	// is left behind.
	switch {
	case i > 0 && cur[i-1] == '\n' && (end == len(cur) || cur[end] == '\n'):
		if end < len(cur) {
			end++
		} else {
			i--
		}
	case i == 0 && end < len(cur) && cur[end] == '\n':
		end++
	}
	return cur[:i] + cur[end:], true
}

func cutTitle(title string) string {
	t := "Remove: " + oneLine(title)
	if utf8.RuneCountInString(t) > maxTitleRunes {
		t = string([]rune(t)[:maxTitleRunes-1]) + "…"
	}
	return t
}

func cutWhy(p db.CoachProposal) string {
	return fmt.Sprintf("This edit was accepted on %s and the %s measure has not improved enough since "+
		"(correlation, not proof). Removing it keeps the text shorter.",
		p.DecidedAt.UTC().Format("2006-01-02"), strings.ReplaceAll(p.Metric, "_", " "))
}
