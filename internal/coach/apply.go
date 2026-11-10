package coach

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
	"watchtower/internal/logredact"
)

var (
	// ErrStale refuses an Accept whose destination no longer holds the text
	// the proposal was made against; the proposal is marked superseded.
	ErrStale = errors.New("the text changed since this proposal — it is superseded")
	// ErrChangedSince refuses a Rollback whose destination no longer holds the
	// accepted text; the owner sees the diff and may force it.
	ErrChangedSince = errors.New("the text changed since this edit")
	// ErrInvalidEdit refuses an Accept whose text breaks the destination's rules.
	ErrInvalidEdit = errors.New("the text breaks its destination's rules")

	errNotSupported = errors.New("this destination is not supported yet")
)

// baselineWindow is the period before an Accept its baseline is measured over.
const baselineWindow = 14 * 24 * time.Hour

// Applier carries out the owner's decisions on coach proposals: the only code
// that writes the owner's setup. Errors name the proposal id and destination,
// never the text (FILES-01).
type Applier struct {
	DB       *db.DB
	AgentLog *agentlogdb.DB
	// Home is the home folder ~/.claude/settings.json lives in (a seam:
	// os.UserHomeDir in production, a temp dir in tests).
	Home string
	// CodexHome is Codex's home ($CODEX_HOME when the owner set one); ""
	// means <Home>/.codex.
	CodexHome string
	Now       func() time.Time
	// RepoState reads the git state of one workbench repository file
	// (folder, its relative path); RepoBranch the branch checked out in a
	// workbench folder ("detached:<short sha>" for a detached HEAD). Both are
	// seams with no default here — internal/coach runs no git (COACH-01) — and
	// cmd fills them over workbenchgit's read-only helpers. A nil RepoState
	// refuses every Accept of a repository file.
	RepoState  func(folder, rel string) (RepoFileState, error)
	RepoBranch func(folder string) (string, error)
}

// env is where a's file destinations live.
func (a *Applier) env() Env {
	return Env{Home: a.Home, CodexHome: a.CodexHome, RepoState: a.RepoState}
}

func (a *Applier) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

// AcceptResult is what an Accept changed beyond the destination: for a pack
// overlay, how many installed copies of the skill were re-rendered and how
// many were left because the owner edited them by hand; for a workbench
// repository file, the file written, relative to the workbench folder ("" for
// every other destination).
type AcceptResult struct {
	PackCopiesUpdated, PackCopiesDrifted int
	WrittenPath                          string
}

// Accept applies an open proposal (accept); a pack overlay then re-renders
// the skill's installed copies (rerenderPack) and the result counts them.
func (a *Applier) Accept(id int64, edited string) (AcceptResult, error) {
	p, err := a.DB.GetCoachProposal(id)
	if err != nil {
		return AcceptResult{}, err
	}
	if err := a.accept(p, edited); err != nil {
		return AcceptResult{}, err
	}
	var r AcceptResult
	if p.Destination == DestPackOverlay {
		r.PackCopiesUpdated, r.PackCopiesDrifted = a.rerenderPack(p.Skill)
	}
	if repoDestinations[p.Destination] {
		r.WrittenPath, _ = RepoRelPath(p.Destination, p.Skill)
	}
	return r, nil
}

// accept applies p. edited "" applies the proposed text; otherwise edited is
// the owner's own whole after-text, checked by the same rules. The
// destination must still hold the proposal's before-text, else the proposal
// is superseded and ErrStale returned; an owner text is written by a
// compare-and-set on that before-text, so an edit made after the check is
// never overwritten. When the destination already holds the proposal's own
// after-text (an earlier Accept wrote it but failed to record it), only the
// status is written; an edited text never takes that shortcut. The
// destination is written first, then the status; when the status write fails
// the before-state is put back.
func (a *Applier) accept(p db.CoachProposal, edited string) error {
	id := p.ID
	if p.Status != "open" {
		return fmt.Errorf("coach proposal %d is %s, not open: %w", id, p.Status, db.ErrCoachStateChanged)
	}
	now := a.now()
	// The slow measure runs first so the read and the write stay adjacent.
	baseline, n, err := a.baseline(p, now)
	if err != nil {
		return fmt.Errorf("coach proposal %d: measuring the baseline: %w", id, err)
	}
	if repoDestinations[p.Destination] {
		// The git check is not repeated after the write, which makes the path
		// dirty itself (spec §4.3a).
		if err := a.checkRepo(p); err != nil {
			return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
		}
	}
	cur, err := a.readCurrent(p)
	if err != nil {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	after := p.AfterText
	if edited != "" {
		after = edited
	}
	if cur.Text != p.BeforeText {
		// Recovery only: an edited text always takes the normal path below.
		if cur.Text == p.AfterText {
			if err := a.DB.MarkCoachAccepted(id, cur.Text, baseline, n, now); err != nil {
				return fmt.Errorf("accepting coach proposal %d: %w", id, err)
			}
			return nil
		}
		return a.supersede(p, now)
	}
	if err := ValidateAfter(cur, after); err != nil {
		return logredact.Errorf("coach proposal %d (%s): %w: %s", id, p.Destination, ErrInvalidEdit,
			logredact.Text(err.Error()))
	}
	w, err := a.writeDestination(p, cur, after, now)
	if errors.Is(err, ErrStale) {
		return a.supersede(p, now)
	}
	if err != nil {
		return fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if err := a.DB.MarkCoachAccepted(id, w.result, baseline, n, now); err != nil {
		err = fmt.Errorf("accepting coach proposal %d: %w", id, err)
		if uerr := w.undo(); uerr != nil {
			return errors.Join(err, fmt.Errorf("restoring %s of coach proposal %d: %w", p.Destination, id, uerr))
		}
		return err
	}
	return nil
}

// supersede closes p because its destination no longer holds its before-text.
func (a *Applier) supersede(p db.CoachProposal, now time.Time) error {
	if err := a.DB.DecideCoachProposal(p.ID, "open", "superseded", now); err != nil {
		return fmt.Errorf("coach proposal %d: %w", p.ID, err)
	}
	return fmt.Errorf("coach proposal %d (%s): %w", p.ID, p.Destination, ErrStale)
}

// Decline closes an open proposal for good: its fingerprint never returns.
func (a *Applier) Decline(id int64) error {
	if err := a.DB.DecideCoachProposal(id, "open", "declined", a.now()); err != nil {
		return fmt.Errorf("declining coach proposal %d: %w", id, err)
	}
	return nil
}

// Rollback undoes an accepted proposal. When the destination no longer holds
// the accepted edit (stillHolds) and force is false, nothing is written and it
// returns a unified diff (accepted → now) with ErrChangedSince. An owner text gets its
// before-text back; a prompt or a pack skill's overlay loses the lines this
// proposal made and gets back the ones it removed (an overlay then re-renders
// the skill's installed copies); the allow list loses the rules this proposal
// added, every other key and rule staying as it is.
func (a *Applier) Rollback(id int64, force bool) (string, error) {
	p, err := a.DB.GetCoachProposal(id)
	if err != nil {
		return "", err
	}
	if p.Status != "accepted" {
		return "", fmt.Errorf("coach proposal %d is %s, not accepted: %w", id, p.Status, db.ErrCoachStateChanged)
	}
	cur, err := a.readCurrent(p)
	if err != nil {
		return "", fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	holds, err := a.stillHolds(p, cur)
	if err != nil {
		return "", fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if !holds && !force {
		return unifiedDiff(p.AfterText, cur.Text), fmt.Errorf("coach proposal %d (%s): %w", id, p.Destination, ErrChangedSince)
	}
	now := a.now()
	if err := a.restoreDestination(p, cur, now); err != nil {
		return "", fmt.Errorf("rolling back coach proposal %d (%s): %w", id, p.Destination, err)
	}
	if p.Destination == DestPackOverlay {
		// The rows are back: the copies follow them whatever the status write
		// does. The counts are reported for an Accept only.
		_, _ = a.rerenderPack(p.Skill)
	}
	// The destination is back; only the status is left. An accepted proposal
	// can only move to rolled_back, so a failed CAS means another rollback won.
	if err := a.DB.DecideCoachProposal(id, "accepted", "rolled_back", now); err != nil {
		return "", fmt.Errorf("rolling back coach proposal %d: %w", id, err)
	}
	return "", nil
}

// stillHolds is whether the destination still contains p's accepted edit: an
// owner text is exactly the after-text; a prompt or a pack skill's overlay
// still has every row this proposal added, with the same text; the allow list
// or the Codex rules still have every rule the proposal added. Later
// additions and rules of others do not count.
func (a *Applier) stillHolds(p db.CoachProposal, cur CurrentText) (bool, error) {
	switch p.Destination {
	case DestPromptAdd, DestPackOverlay:
		return a.linesStillHold(p)
	case DestSettingsAllow, DestCodexRulesAllow:
		have := countLines(nonEmptyLines(cur.Text))
		for _, r := range linesAdded(p.BeforeText, p.AfterText) {
			if have[r] == 0 {
				return false, nil
			}
		}
		return true, nil
	}
	return cur.Text == p.AfterText, nil
}

// linesAdded is the lines of after that before lacks (counting repeats).
func linesAdded(before, after string) []string {
	had := countLines(nonEmptyLines(before))
	var out []string
	for _, l := range nonEmptyLines(after) {
		if had[l] > 0 {
			had[l]--
			continue
		}
		out = append(out, l)
	}
	return out
}

func (a *Applier) baseline(p db.CoachProposal, now time.Time) (*float64, int, error) {
	if a.AgentLog == nil {
		return nil, 0, errors.New("no agent log database")
	}
	m, err := Measure(a.DB, a.AgentLog, p.WorkbenchID, now.Add(-baselineWindow), now, AgentFor(p.Destination))
	if err != nil {
		return nil, 0, err
	}
	v := m.Of(p.Metric)
	if !v.Known {
		return nil, 0, nil
	}
	return &v.V, v.N, nil
}

func instructionField(dest string) db.InstructionField {
	switch dest {
	case DestSession:
		return db.InstructionSession
	case DestProcedure:
		return db.InstructionProcedure
	}
	return db.InstructionChat
}

func (a *Applier) settingsPath() (string, error) {
	if a.Home == "" {
		return "", errors.New("no home folder")
	}
	return claudeSettingsPath(a.Home), nil
}

func (a *Applier) claudeMDPath() (string, error) {
	if a.Home == "" {
		return "", errors.New("no home folder")
	}
	return claudeMDPath(a.Home), nil
}

// readCurrent reads p's destination as the proposer saw it (currentTexts):
// the owner text, the prompt's additions one per line, or the allow list one
// rule per line — except that a settings file the coach cannot write safely
// (a symlink, invalid JSON) is an error here, not an empty list.
func (a *Applier) readCurrent(p db.CoachProposal) (CurrentText, error) {
	t := CurrentText{Destination: p.Destination, WorkbenchID: p.WorkbenchID, PromptID: p.PromptID, Skill: p.Skill}
	if globalDestinations[p.Destination] && p.WorkbenchID != 0 {
		return CurrentText{}, errors.New("this destination has no per-workbench text")
	}
	switch p.Destination {
	case DestSession, DestProcedure, DestChat:
		t.Budget = BudgetOf(p.Destination, "")
		var o db.OwnerInstructions
		var err error
		if p.WorkbenchID == 0 {
			o, err = a.DB.GetOwnerInstructions()
		} else {
			o, err = a.DB.GetWorkbenchInstructions(p.WorkbenchID)
		}
		if err != nil {
			return CurrentText{}, err
		}
		switch p.Destination {
		case DestSession:
			t.Text = o.Session
		case DestProcedure:
			t.Text = o.Procedure
		default:
			t.Text = o.Chat
		}
	case DestPromptAdd, DestPackOverlay:
		t.Budget = BudgetOf(p.Destination, "")
		rows, err := a.linesOf(p).list()
		if err != nil {
			return CurrentText{}, err
		}
		t.Text = joinLines(rows)
	case DestSettingsAllow:
		path, err := a.settingsPath()
		if err != nil {
			return CurrentText{}, err
		}
		rules, err := readAllowRules(path)
		if err != nil {
			return CurrentText{}, err
		}
		t.Text = strings.Join(rules, "\n")
	case DestClaudeMDUser:
		path, err := a.claudeMDPath()
		if err != nil {
			return CurrentText{}, err
		}
		if t, err = readClaudeMD(path); err != nil {
			return CurrentText{}, err
		}
		t.WorkbenchID, t.PromptID = p.WorkbenchID, p.PromptID
	case DestClaudeSkillUser, DestCodexSkillUser, DestCodexAgentsMDUser, DestCodexRulesAllow:
		u, err := userFileOf(a.env(), p.Destination, p.Skill)
		if err != nil {
			return CurrentText{}, err
		}
		if t.Text, err = u.readText(); err != nil {
			return CurrentText{}, err
		}
		t.Budget = BudgetOf(p.Destination, t.Text)
	case DestRepoClaudeMD, DestRepoAgentsMD, DestRepoClaudeSkill, DestRepoCodexSkill, DestRepoWorkflow:
		return a.readRepo(p, t)
	default:
		return CurrentText{}, errors.New("unknown destination")
	}
	return t, nil
}

// swapText sets p's owner text to body only while it is still from; false
// when someone changed it in between.
func (a *Applier) swapText(p db.CoachProposal, from, body string) (bool, error) {
	f := instructionField(p.Destination)
	if p.WorkbenchID == 0 {
		return a.DB.SwapOwnerInstruction(f, from, body)
	}
	return a.DB.SwapWorkbenchInstruction(p.WorkbenchID, f, from, body)
}

// written is a destination write: the text the destination now holds (stored
// as the proposal's after_text) and how to put the before-state back.
type written struct {
	result string
	undo   func() error
}

// writeDestination writes after to p's destination, which holds cur.
func (a *Applier) writeDestination(p db.CoachProposal, cur CurrentText, after string, now time.Time) (written, error) {
	switch p.Destination {
	case DestSession, DestProcedure, DestChat:
		ok, err := a.swapText(p, cur.Text, after)
		if err != nil {
			return written{}, err
		}
		if !ok {
			return written{}, ErrStale
		}
		return written{result: after, undo: func() error {
			ok, err := a.swapText(p, after, cur.Text)
			if err == nil && !ok {
				err = ErrChangedSince
			}
			return err
		}}, nil
	case DestPromptAdd, DestPackOverlay:
		return a.writeLines(p, after, now)
	case DestSettingsAllow:
		return a.writeAllow(p, cur, after)
	case DestClaudeMDUser:
		return a.writeClaudeMD(cur, after)
	case DestClaudeSkillUser, DestCodexSkillUser, DestCodexAgentsMDUser, DestCodexRulesAllow:
		// The Codex rules too: after is the whole file, its old text plus the
		// added lines (ValidateAfter).
		return a.writeUserFile(p, cur, after)
	case DestRepoClaudeMD, DestRepoAgentsMD, DestRepoClaudeSkill, DestRepoCodexSkill, DestRepoWorkflow:
		return a.writeRepoFile(p, cur, after)
	}
	return written{}, errNotSupported
}

// writeAllow appends the rules the proposal adds (after − its before-text);
// ValidateAfter has already refused an after that drops a rule. The result is
// the list as read plus those rules, so a rule someone else adds meanwhile is
// never recorded as this proposal's.
func (a *Applier) writeAllow(p db.CoachProposal, cur CurrentText, after string) (written, error) {
	path, err := a.settingsPath()
	if err != nil {
		return written{}, err
	}
	rules := linesAdded(p.BeforeText, after)
	before, out, err := AppendAllowRules(path, rules)
	if err != nil {
		return written{}, err
	}
	result := nonEmptyLines(cur.Text)
	have := countLines(result)
	for _, r := range rules {
		if have[r] == 0 {
			have[r]++
			result = append(result, r)
		}
	}
	w := written{result: strings.Join(result, "\n"), undo: func() error { return nil }}
	if bytes.Equal(before, out) {
		return w, nil
	}
	w.undo = func() error {
		raw, _, _, err := readSettingsFile(path)
		if err != nil {
			return err
		}
		if !bytes.Equal(raw, out) {
			return errSettingsChanged
		}
		return RestoreFile(path, before)
	}
	return w, nil
}

// writeClaudeMD replaces the file's text cur.Text by after, refused with
// ErrStale when the file is no longer cur.Text. The undo puts cur.Text back
// (removing a file this write created) only while the file still holds after.
func (a *Applier) writeClaudeMD(cur CurrentText, after string) (written, error) {
	path, err := a.claudeMDPath()
	if err != nil {
		return written{}, err
	}
	existed, err := replaceClaudeMD(path, cur.Text, after)
	if errors.Is(err, errClaudeMDChanged) {
		return written{}, ErrStale
	}
	if err != nil {
		return written{}, err
	}
	return written{result: after, undo: func() error {
		if !existed {
			raw, _, ok, err := readClaudeMDFile(path)
			if err != nil || !ok {
				return err
			}
			if string(raw) != after {
				return errClaudeMDChanged
			}
			return os.Remove(path)
		}
		_, err := replaceClaudeMD(path, after, cur.Text)
		return err
	}}, nil
}

// writeUserFile replaces a skill's or AGENTS.md's text cur.Text by after,
// refused with ErrStale when the file is no longer cur.Text. The undo puts
// cur.Text back only while the file still holds after; an AGENTS.md this write
// created is written back empty, never removed.
func (a *Applier) writeUserFile(p db.CoachProposal, cur CurrentText, after string) (written, error) {
	u, err := userFileOf(a.env(), p.Destination, p.Skill)
	if err != nil {
		return written{}, err
	}
	err = u.replaceText(cur.Text, after)
	if errors.Is(err, u.kind.changed) {
		return written{}, ErrStale
	}
	if err != nil {
		return written{}, err
	}
	return written{result: after, undo: func() error { return u.replaceText(after, cur.Text) }}, nil
}

// restoreDestination puts p's before-state back (see Rollback).
func (a *Applier) restoreDestination(p db.CoachProposal, cur CurrentText, now time.Time) error {
	switch p.Destination {
	case DestSession, DestProcedure, DestChat:
		ok, err := a.swapText(p, cur.Text, p.BeforeText)
		if err == nil && !ok {
			err = ErrChangedSince
		}
		return err
	case DestPromptAdd, DestPackOverlay:
		return a.restoreLines(p, now)
	case DestSettingsAllow:
		path, err := a.settingsPath()
		if err != nil {
			return err
		}
		_, _, err = removeAllowRules(path, linesAdded(p.BeforeText, p.AfterText))
		return err
	case DestClaudeMDUser:
		// The file must still be what Rollback read (and showed the owner as a
		// diff), whether or not the owner forced it.
		path, err := a.claudeMDPath()
		if err != nil {
			return err
		}
		if _, err := replaceClaudeMD(path, cur.Text, p.BeforeText); err != nil {
			if errors.Is(err, errClaudeMDChanged) {
				return ErrChangedSince
			}
			return err
		}
		return nil
	case DestClaudeSkillUser, DestCodexSkillUser, DestCodexAgentsMDUser:
		// Like CLAUDE.md: the file must still be what Rollback read. A created
		// AGENTS.md goes back to its empty before-text and stays.
		u, err := userFileOf(a.env(), p.Destination, p.Skill)
		if err != nil {
			return err
		}
		if err := u.replaceText(cur.Text, p.BeforeText); err != nil {
			if errors.Is(err, u.kind.changed) {
				return ErrChangedSince
			}
			return err
		}
		return nil
	case DestCodexRulesAllow:
		// Only the lines this proposal added go, from the text Rollback read;
		// the owner's own lines and bytes stay.
		u, err := userFileOf(a.env(), p.Destination, p.Skill)
		if err != nil {
			return err
		}
		to := removeCodexRules(cur.Text, linesAdded(p.BeforeText, p.AfterText))
		if err := u.replaceText(cur.Text, to); err != nil {
			if errors.Is(err, u.kind.changed) {
				return ErrChangedSince
			}
			return err
		}
		return nil
	case DestRepoClaudeMD, DestRepoAgentsMD, DestRepoClaudeSkill, DestRepoCodexSkill, DestRepoWorkflow:
		return a.restoreRepoFile(p, cur)
	}
	return errNotSupported
}

func countLines(lines []string) map[string]int {
	m := map[string]int{}
	for _, l := range lines {
		m[l]++
	}
	return m
}

// unifiedDiff is a one-hunk unified diff of two texts, line by line.
func unifiedDiff(from, to string) string {
	split := func(s string) []string {
		if s == "" {
			return nil
		}
		return strings.Split(s, "\n")
	}
	a, b := split(from), split(to)
	// lcs[i][j] is the longest common subsequence of a[i:] and b[j:].
	lcs := make([][]int, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	rng := func(n int) string {
		if n == 0 {
			return "0,0"
		}
		return fmt.Sprintf("1,%d", n)
	}
	var out strings.Builder
	fmt.Fprintf(&out, "--- accepted\n+++ now\n@@ -%s +%s @@\n", rng(len(a)), rng(len(b)))
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			out.WriteString(" " + a[i] + "\n")
			i++
			j++
		case i < len(a) && (j == len(b) || lcs[i+1][j] >= lcs[i][j+1]):
			out.WriteString("-" + a[i] + "\n")
			i++
		default:
			out.WriteString("+" + b[j] + "\n")
			j++
		}
	}
	return out.String()
}
