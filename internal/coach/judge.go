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
	// repoCommitWait is how long an accepted workbench repository edit may
	// wait for the owner's commit: past it, still unseen at the folder's HEAD,
	// its verdict is a final too_little_data (spec §4.3a, D68).
	repoCommitWait = 30 * 24 * time.Hour
)

// Judge gives the accepted proposals a verdict by comparing the metric since
// the Accept with the baseline taken then. It shows correlation, not
// causation: other changes land in the same weeks. A proposal decided at least
// judgeAfter ago with no verdict, or with too_little_data (until judgeGiveUp),
// is measured over [decided_at, now) — for a workbench repository file over
// [measure_from, now), from when the daemon first saw the edit committed
// (windowStart; never committed within repoCommitWait: too_little_data,
// final): under judgeMinSessions sessions, no
// baseline or no value is too_little_data; a value at least judgeImprovement
// below the baseline is works; anything else is no_effect. A no_effect edit
// gets one mechanical cut proposal (no model call) when a slot is free. judged
// counts the works / no_effect verdicts, cuts the proposals written. Nothing
// is judged until RemeasureMixedBaselines is done (tried again first here), so
// no verdict compares one agent's value with a baseline of every agent's.
func Judge(d *db.DB, al *agentlogdb.DB, now time.Time) (judged, cuts int, err error) {
	if err := judgeReady(d, al); err != nil {
		return 0, 0, err
	}
	home, _ := os.UserHomeDir() // "": the allow list is not read, no cut for it
	return judge(d, al, home, now)
}

// errBaselinesPending skips a judge pass while the per-agent re-measure of
// the baselines waits for agentlog.db's move out of watchtower.db.
var errBaselinesPending = errors.New("baselines not yet re-measured per agent (agent analytics still moving); judging skipped")

func judgeReady(d *db.DB, al *agentlogdb.DB) error {
	if _, err := RemeasureMixedBaselines(d, al); err != nil {
		return fmt.Errorf("re-measuring baselines per agent: %w", err)
	}
	done, err := d.CoachBaselinesPerAgentDone()
	if err != nil {
		return err
	}
	if !done {
		return errBaselinesPending
	}
	return nil
}

func judge(d *db.DB, al *agentlogdb.DB, home string, now time.Time) (judged, cuts int, err error) {
	accepted, err := d.ListCoachProposals("accepted")
	if err != nil {
		return 0, 0, err
	}
	var errs []error
	for _, p := range accepted {
		if isRepoDestination(p.Destination) && p.MeasureFrom.IsZero() {
			// Not committed yet: no window to measure. Past repoCommitWait
			// it never will be (the daily commit check skips a judged row).
			if p.Verdict != "" || p.DecidedAt.IsZero() || now.Sub(p.DecidedAt) < repoCommitWait {
				continue
			}
			if err := d.SetCoachVerdict(p.ID, "too_little_data", nil, now); err != nil &&
				!errors.Is(err, db.ErrCoachStateChanged) {
				errs = append(errs, fmt.Errorf("judging coach proposal %d: %w", p.ID, err))
			}
			continue
		}
		start := windowStart(p)
		if start.IsZero() || now.Sub(start) < judgeAfter {
			continue
		}
		if p.Verdict != "" && p.Verdict != "too_little_data" {
			continue
		}
		if p.Verdict == "too_little_data" && !p.VerdictAt.Before(start.Add(judgeGiveUp)) {
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

// windowStart is where p's verdict window starts: measure_from for a
// workbench repository file (zero until its commit is seen), the Accept for
// every other destination.
func windowStart(p db.CoachProposal) time.Time {
	if isRepoDestination(p.Destination) {
		return p.MeasureFrom
	}
	return p.DecidedAt
}

// verdictOf measures p's period and names the verdict and the measured value.
func verdictOf(d *db.DB, al *agentlogdb.DB, p db.CoachProposal, now time.Time) (string, *float64, error) {
	m, err := Measure(d, al, p.WorkbenchID, windowStart(p), now, AgentFor(p.Destination))
	if err != nil {
		return "", nil, err
	}
	v := m.Of(p.Metric)
	if m.Sessions < judgeMinSessions || p.Baseline == nil || *p.Baseline <= 0 || !v.Known {
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
	// No cut for the allow lists (Claude's and the Codex rules): an Accept may
	// only grow them, so a cut could never be accepted and would hold a slot.
	// The owner removes such a rule with Rollback of the original proposal;
	// its no_effect verdict stands. No cut for a workbench repository file
	// either: it is the owner's change to commit (spec §4.3a, D67).
	if p.Destination == DestSettingsAllow || p.Destination == DestCodexRulesAllow || isRepoDestination(p.Destination) {
		return false, nil
	}
	open, err := d.ListCoachProposals("open")
	if err != nil {
		return false, err
	}
	// Only weekly proposals hold a slot: open chat proposals must not stop
	// a cut, whose verdict is stored once and never comes back.
	if weeklyOpen(open) >= maxOpen {
		return false, nil
	}
	key := keyOf(p.Destination, p.WorkbenchID, p.PromptID, p.Skill)
	for _, o := range open {
		if keyOf(o.Destination, o.WorkbenchID, o.PromptID, o.Skill) == key {
			return false, nil
		}
	}
	cur, err := (&Applier{DB: d, AgentLog: al, Home: home, CodexHome: CodexHomeFromEnv()}).readCurrent(p)
	if err != nil {
		// A destination the coach cannot read safely is not cut.
		if errors.Is(err, errNotSupported) || errors.Is(err, errClaudeMDNotRegular) ||
			errors.Is(err, errClaudeMDTooBig) || errors.Is(err, errUnsafeFile) ||
			errors.Is(err, errSkillNotFound) || errors.Is(err, errBadSkillName) || errors.Is(err, errPackSkill) ||
			errors.Is(err, errCodexRulesMissing) || errors.Is(err, errCodexSkillTwice) {
			return false, nil
		}
		return false, err
	}
	after, ok := withoutEdit(p, cur.Text)
	if !ok {
		return false, nil
	}
	// Accept runs the same check: a restored replaced part may not fit.
	if verr := ValidateAfter(cur, after); verr != nil {
		return false, nil //nolint:nilerr // an edit Accept would refuse is not filed
	}
	fp, changed := fingerprint(key, cur.Text, after)
	if !changed {
		return false, nil
	}
	kind := "cut"
	if !kindFits("cut", cur.Text, after) { // a replaced part came back: not shorter
		kind = "replace"
	}
	id, err := d.InsertCoachProposal(db.CoachProposal{
		Fingerprint: fp, Kind: kind, Destination: key.dest, WorkbenchID: key.wb, PromptID: key.prompt, Skill: key.skill,
		Title: cutTitle(p.Title), Why: cutWhy(p), Metric: p.Metric,
		BeforeText: cur.Text, AfterText: after, Evidence: p.Evidence, Sources: p.Sources, RevertsID: p.ID,
	}, now)
	return id != 0, err
}

// isRepoDestination reports a workbench repository file destination (the
// five of spec §4.3a).
func isRepoDestination(dest string) bool { return repoDestinations[dest] }

// withoutEdit is cur with p's edit undone: for an owner text the added part
// (where it still appears exactly once) is replaced by what the edit removed,
// or dropped for a pure addition; for a prompt's additions or a pack skill's
// overlay the added lines are dropped and the removed ones come back in place.
// ok is false when none of the added part is left.
func withoutEdit(p db.CoachProposal, cur string) (string, bool) {
	if lineDestinations[p.Destination] {
		drop := countLines(linesAdded(p.BeforeText, p.AfterText))
		back := linesAdded(p.AfterText, p.BeforeText) // lines a replacing edit removed
		var keep []string
		removed := false
		for _, l := range nonEmptyLines(cur) {
			if drop[l] > 0 {
				drop[l]--
				if !removed {
					keep = append(keep, back...)
				}
				removed = true
				continue
			}
			keep = append(keep, l)
		}
		return strings.Join(keep, "\n"), removed
	}
	gone, added := changedPart(p.BeforeText, p.AfterText)
	if strings.TrimSpace(added) == "" || strings.Count(cur, added) != 1 {
		return "", false
	}
	i := strings.Index(cur, added)
	end := i + len(added)
	if gone != "" { // a replacing edit: the old part comes back
		return cur[:i] + gone + cur[end:], true
	}
	// A pure addition: take one line break with a part that is a whole line,
	// so no blank line is left behind.
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
