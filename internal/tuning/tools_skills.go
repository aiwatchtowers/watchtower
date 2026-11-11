package tuning

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"watchtower/internal/agentkind"
	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/tools"
)

// The skill, instruction and proposal reads of the tuning chat (spec §4.2,
// §4.3, §4.3a). Every file is read through the coach's own reader
// (coach.ReadText: a regular UTF-8 file up to 256 KB, no symlink below the
// home folder or the workbench folder), so the chat sees exactly the text a
// proposal would edit. Git state comes only through Deps.CoachEnv's
// RepoState seam, the read-only `git status` cmd wires (COACH-01).

// Agents and scopes of a skill row. The pack's agent is "watchtower": its
// skills ship inside Watchtower and the owner changes them only through an
// overlay.
const (
	agentWatchtower = "watchtower"
	scopeHome       = "home"
	scopeWorkbench  = "workbench"
	scopePack       = "pack"
)

// skillKind is one agent's skills: the home destination, the workbench
// folder's destination and the folder in the workbench folder that holds
// the skills (<repoTop>/skills).
type skillKind struct {
	agent      agentkind.Kind
	home, repo string
	repoTop    string
}

// skillKinds has a row for every agentkind (TestSkillKinds_EveryAgent).
var skillKinds = map[agentkind.Kind]skillKind{
	agentkind.Claude: {agentkind.Claude, coach.DestClaudeSkillUser, coach.DestRepoClaudeSkill, ".claude"},
	agentkind.Codex:  {agentkind.Codex, coach.DestCodexSkillUser, coach.DestRepoCodexSkill, ".agents"},
}

// unreadableSkills is the note of a skills folder that exists but could not
// be listed: never an all-clear.
const unreadableSkills = "this skills folder could not be read (a symlink, or no permission): its skills are not listed"

// codexTwoFolders is the note of a Codex skill in both folders when the
// coach's own sentence is not at hand (a copy went between the listing and
// the read).
const codexTwoFolders = "Codex sees this skill in two folders — remove one copy first."

// repoFolderGone is the note and the row error of a workbench folder that
// is gone (or is not a folder).
const repoFolderGone = "workbench folder not found"

// skillTools are list_skills, get_skill, get_agent_instructions and
// list_coach_proposals.
func skillTools(deps Deps) []*tools.Tool {
	return []*tools.Tool{
		readTool[listSkillsArgs]("list_skills",
			"List the owner's skills: global Claude Code skills (~/.claude/skills), global Codex skills "+
				"(~/.agents/skills and the Codex home's skills), Watchtower's pack skills with the owner's overlay "+
				"lines, and the workbench folder's .claude/skills and .agents/skills. destination is what "+
				"propose_tuning_edit takes for that skill; a row without one cannot be proposed (its note says why). "+
				"Open one with get_skill.",
			func(_ context.Context, d *db.DB, b tools.Binding, a listSkillsArgs) (any, error) {
				return listSkills(d, deps, b, a.WorkbenchID)
			}),
		readTool[getSkillArgs]("get_skill",
			"Read one skill's text and the most runes an edit may leave in it. agent claude, codex or watchtower "+
				"(a pack skill: the shipped text with the owner's overlay); scope home (default) or workbench "+
				"(the workbench folder's copy).",
			func(_ context.Context, d *db.DB, b tools.Binding, a getSkillArgs) (any, error) {
				return getSkill(d, deps, b, a)
			}),
		readTool[listSkillsArgs]("get_agent_instructions",
			"Read the owner's agent instructions with each one's budget: ~/.claude/CLAUDE.md, the Codex AGENTS.md, "+
				"the Claude Code allow list, the Codex rules file, and the workbench folder's CLAUDE.md, AGENTS.md "+
				"and .watchtower/workflow.md with their git state (clean, changed or not_git).",
			func(_ context.Context, d *db.DB, b tools.Binding, a listSkillsArgs) (any, error) {
				return agentInstructions(d, deps, b, a.WorkbenchID)
			}),
		readTool[listProposalsArgs]("list_coach_proposals",
			"List the coach's proposals — open, accepted, declined, rolled back — newest first, without their "+
				"texts, so you never propose an edit that is already open, accepted or declined. Narrow with "+
				"destination and skill; limit defaults to 50 (at most 100). Pass id for one proposal with its "+
				"before and after texts.",
			func(_ context.Context, d *db.DB, _ tools.Binding, a listProposalsArgs) (any, error) {
				return listCoachProposals(d, a)
			}),
	}
}

type listSkillsArgs struct {
	WorkbenchID int64 `json:"workbench_id,omitempty" jsonschema:"the workbench whose folder is read; omit for the panel's workbench"`
}

type getSkillArgs struct {
	Agent       string `json:"agent" jsonschema:"claude, codex or watchtower"`
	Name        string `json:"name" jsonschema:"the skill's folder name, from list_skills"`
	Scope       string `json:"scope,omitempty" jsonschema:"home (default) or workbench; a pack skill takes none"`
	WorkbenchID int64  `json:"workbench_id,omitempty" jsonschema:"with scope workbench: the workbench; omit for the panel's workbench"`
}

type skillRow struct {
	Agent string `json:"agent"`
	Scope string `json:"scope"`
	Name  string `json:"name"`
	// Path is "~/…" under the home folder, relative to the workbench folder
	// for scope workbench, "" for a pack skill.
	Path         string   `json:"path"`
	Destination  string   `json:"destination,omitempty"`
	OverlayLines []string `json:"overlay_lines,omitempty"`
	Note         string   `json:"note,omitempty"`
}

type skillText struct {
	skillRow
	Text        string `json:"text"`
	BudgetRunes int    `json:"budget_runes"`
}

// listSkills is list_skills: home skills, pack skills, then the workbench
// folder's skills (when the chat has a workbench). A skills folder that
// exists but cannot be listed, and a workbench folder that is gone, are rows
// with a note and no name: never an empty all-clear.
func listSkills(d *db.DB, deps Deps, b tools.Binding, wbArg int64) ([]skillRow, error) {
	env, err := deps.coachEnv()
	if err != nil {
		return nil, err
	}
	claude, codex := skillKinds[agentkind.Claude], skillKinds[agentkind.Codex]
	out := []skillRow{}
	unreadable := func(k skillKind, scope, path string) {
		out = append(out, skillRow{Agent: string(k.agent), Scope: scope, Path: path, Note: unreadableSkills})
	}
	claudeTop := filepath.Join(env.Home, ".claude")
	names, ok := skillNames(claudeTop, "skills")
	if !ok {
		unreadable(claude, scopeHome, homePath(env.Home, filepath.Join(claudeTop, "skills")))
	}
	for _, name := range names {
		out = append(out, skillRow{Agent: string(claude.agent), Scope: scopeHome, Name: name,
			Path: homePath(env.Home, coach.ClaudeSkillPath(env, name)), Destination: claude.home})
	}
	in := map[string][]string{}
	for _, top := range []string{filepath.Join(env.Home, ".agents"), codexHomeOf(env.Home, env.CodexHome)} {
		names, ok := skillNames(top, "skills")
		if !ok {
			unreadable(codex, scopeHome, homePath(env.Home, filepath.Join(top, "skills")))
		}
		for _, name := range names {
			in[name] = append(in[name], filepath.Join(top, "skills", name, "SKILL.md"))
		}
	}
	for _, name := range slices.Sorted(maps.Keys(in)) {
		row := skillRow{Agent: string(codex.agent), Scope: scopeHome, Name: name, Destination: codex.home}
		if len(in[name]) > 1 {
			// Codex loads both copies; the coach refuses to edit either (ask #1202).
			row.Destination, row.Note = "", codexTwoFolders
			if _, err := coach.ReadText(d, env, codex.home, 0, "", name); err != nil {
				row.Note = err.Error() // the coach's sentence, naming the real Codex home
			}
		}
		for _, p := range in[name] {
			row.Path = homePath(env.Home, p)
			out = append(out, row)
		}
	}
	overlays, err := d.AllSkillPackOverlays()
	if err != nil {
		return nil, err
	}
	for _, name := range devpack.PackSkillNames() {
		out = append(out, skillRow{Agent: agentWatchtower, Scope: scopePack, Name: name,
			Destination: coach.DestPackOverlay, OverlayLines: overlays[name]})
	}
	if wbArg == 0 && b.ContextType != ContextType {
		return out, nil
	}
	wb, err := workbenchOf(d, b, wbArg)
	if err != nil {
		return nil, err
	}
	folder, err := folderOf(d, wb)
	if err != nil {
		return nil, err
	}
	for _, k := range []skillKind{claude, codex} {
		sub := filepath.Join(k.repoTop, "skills")
		if fi, err := os.Lstat(folder); err != nil || !fi.IsDir() {
			out = append(out, skillRow{Agent: string(k.agent), Scope: scopeWorkbench, Path: filepath.ToSlash(sub),
				Note: repoFolderGone})
			continue
		}
		names, ok := skillNames(folder, sub)
		if !ok {
			unreadable(k, scopeWorkbench, filepath.ToSlash(sub))
		}
		for _, name := range names {
			// name passed skillNames' name check, so the path exists.
			rel, _ := coach.RepoRelPath(k.repo, name)
			out = append(out, skillRow{Agent: string(k.agent), Scope: scopeWorkbench, Name: name, Path: rel, Destination: k.repo})
		}
	}
	return out, nil
}

// skillNames is the skill folders in root/sub, sorted: valid skill names that
// are real folders (never a symlink) holding a SKILL.md entry, minus
// Watchtower's pack skills (listed once, as the pack). root itself may be a
// symlink (a dotfiles home, D71); no folder of sub may be. A missing folder
// is no skills; ok is false when a folder exists but cannot be listed.
func skillNames(root, sub string) (names []string, ok bool) {
	cur := root
	for i, part := range append([]string{""}, strings.Split(sub, string(filepath.Separator))...) {
		var fi os.FileInfo
		var err error
		if i == 0 {
			fi, err = os.Stat(root)
		} else {
			cur = filepath.Join(cur, part)
			fi, err = os.Lstat(cur)
		}
		if errors.Is(err, fs.ErrNotExist) {
			return nil, true
		}
		if err != nil || !fi.IsDir() {
			return nil, false
		}
	}
	entries, err := os.ReadDir(cur)
	if err != nil {
		return nil, false
	}
	pack := devpack.PackSkillNames()
	for _, e := range entries {
		name := e.Name()
		// RepoRelPath accepts exactly the coach's skill names.
		if _, valid := coach.RepoRelPath(coach.DestRepoClaudeSkill, name); !valid || !e.IsDir() || slices.Contains(pack, name) {
			continue
		}
		if _, err := os.Lstat(filepath.Join(cur, name, "SKILL.md")); err == nil {
			names = append(names, name)
		}
	}
	return names, true
}

// getSkill is get_skill.
func getSkill(d *db.DB, deps Deps, b tools.Binding, a getSkillArgs) (*skillText, error) {
	if a.Scope == "" {
		a.Scope = scopeHome
	}
	switch {
	case a.Agent != agentWatchtower && !agentkind.IsAgent(a.Agent):
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("invalid agent %q: must be claude, codex or watchtower", a.Agent)}
	case a.Scope != scopeHome && a.Scope != scopeWorkbench && a.Scope != scopePack:
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("invalid scope %q: must be home, workbench or (agent watchtower) pack", a.Scope)}
	}
	if _, ok := coach.RepoRelPath(coach.DestRepoClaudeSkill, a.Name); !ok {
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("%q is not a skill name", a.Name)}
	}
	if a.Agent == agentWatchtower {
		if a.Scope == scopeWorkbench {
			return nil, &tools.ValidationError{Msg: "a pack skill has no workbench copy to read: read it without a scope"}
		}
		return packSkill(d, a.Name)
	}
	if a.Scope == scopePack {
		return nil, &tools.ValidationError{Msg: "scope pack is for agent watchtower"}
	}
	if slices.Contains(devpack.PackSkillNames(), a.Name) {
		return nil, &tools.ValidationError{Msg: a.Name + " is a Watchtower pack skill: read it with agent watchtower"}
	}
	k, ok := skillKinds[agentkind.Kind(a.Agent)]
	if !ok {
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("agent %s has no skill folders", a.Agent)}
	}
	env, err := deps.coachEnv()
	if err != nil {
		return nil, err
	}
	row := skillRow{Agent: a.Agent, Scope: a.Scope, Name: a.Name, Destination: k.home}
	var wb int64
	if a.Scope == scopeWorkbench {
		if wb, err = workbenchOf(d, b, a.WorkbenchID); err != nil {
			return nil, err
		}
		row.Destination = k.repo
		row.Path, _ = coach.RepoRelPath(k.repo, a.Name) // the name passed the skill-name check above
	} else {
		// The Claude skill's path, or the one Codex copy (none when the skill
		// is in neither or both Codex folders: the read says which).
		if k.home == coach.DestCodexSkillUser {
			if p, ok := coach.CodexSkillPath(env, a.Name); ok {
				row.Path = homePath(env.Home, p)
			}
		} else {
			row.Path = homePath(env.Home, coach.ClaudeSkillPath(env, a.Name))
		}
	}
	cur, err := coach.ReadText(d, env, row.Destination, wb, "", a.Name)
	if err != nil {
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("skill %s cannot be read: %v", a.Name, err), Err: err}
	}
	return &skillText{skillRow: row, Text: cur.Text, BudgetRunes: cur.Budget}, nil
}

// packSkill is a pack skill as an install renders it: the shipped text with
// the owner's overlay block; the budget is the overlay's.
func packSkill(d *db.DB, name string) (*skillText, error) {
	var content string
	wbName, wbBody := devpack.WorkbenchSkill()
	flowName, flowBody := devpack.FlowSkill()
	switch name {
	case wbName:
		content = string(wbBody)
	case flowName:
		content = string(flowBody)
	default:
		for _, s := range devpack.Skills() {
			if s.Name == name {
				content = s.Content
			}
		}
	}
	if content == "" {
		return nil, &tools.ValidationError{Msg: name + " is not a Watchtower pack skill"}
	}
	rows, err := d.ListSkillPackOverlays(name)
	if err != nil {
		return nil, err
	}
	lines := make([]string, 0, len(rows))
	for _, r := range rows {
		lines = append(lines, r.Text)
	}
	return &skillText{
		skillRow: skillRow{Agent: agentWatchtower, Scope: scopePack, Name: name, Destination: coach.DestPackOverlay, OverlayLines: lines},
		Text:     devpack.Render(devpack.Skill{Name: name, Content: content}, lines).Content,
		// The overlay is the only text an edit reaches.
		BudgetRunes: coach.BudgetOf(coach.DestPackOverlay, ""),
	}, nil
}

type instructionRow struct {
	Destination string `json:"destination"`
	// Path is "~/…" under the home folder, relative to the workbench folder
	// for the workbench's files.
	Path        string `json:"path"`
	Exists      bool   `json:"exists"`
	Text        string `json:"text"`
	BudgetRunes int    `json:"budget_runes"`
	// Git is the workbench file's git state: clean, changed or not_git;
	// empty for the home files.
	Git string `json:"git,omitempty"`
	// Error is why an existing file was not read (a symlink, too large, not
	// text) — it never names a folder.
	Error string `json:"error,omitempty"`
}

const (
	gitClean   = "clean"
	gitChanged = "changed"
	gitNotGit  = "not_git"
)

// agentInstructions is get_agent_instructions: the four home texts, then the
// workbench folder's three (when the chat has a workbench).
func agentInstructions(d *db.DB, deps Deps, b tools.Binding, wbArg int64) ([]instructionRow, error) {
	env, err := deps.coachEnv()
	if err != nil {
		return nil, err
	}
	codexHome := codexHomeOf(env.Home, env.CodexHome)
	out := []instructionRow{}
	for _, h := range []struct{ dest, path string }{
		{coach.DestClaudeMDUser, filepath.Join(env.Home, ".claude", "CLAUDE.md")},
		{coach.DestCodexAgentsMDUser, filepath.Join(codexHome, "AGENTS.md")},
		{coach.DestSettingsAllow, filepath.Join(env.Home, ".claude", "settings.json")},
		{coach.DestCodexRulesAllow, filepath.Join(codexHome, "rules", "default.rules")},
	} {
		row := instructionRow{Destination: h.dest, Path: homePath(env.Home, h.path)}
		readInto(&row, h.path, func() (coach.CurrentText, error) { return coach.ReadText(d, env, h.dest, 0, "", "") })
		out = append(out, row)
	}
	if wbArg == 0 && b.ContextType != ContextType {
		return out, nil
	}
	wb, err := workbenchOf(d, b, wbArg)
	if err != nil {
		return nil, err
	}
	if env.RepoState == nil {
		return nil, errors.New("the git state reader is not wired")
	}
	folder, err := folderOf(d, wb)
	if err != nil {
		return nil, err
	}
	gone := false
	if fi, err := os.Lstat(folder); err != nil || !fi.IsDir() {
		gone = true
	}
	for _, dest := range []string{coach.DestRepoClaudeMD, coach.DestRepoAgentsMD, coach.DestRepoWorkflow} {
		rel, _ := coach.RepoRelPath(dest, "")
		row := instructionRow{Destination: dest, Path: rel}
		if gone {
			row.Error = repoFolderGone
			out = append(out, row)
			continue
		}
		readInto(&row, filepath.Join(folder, filepath.FromSlash(rel)),
			func() (coach.CurrentText, error) { return coach.ReadText(d, env, dest, wb, "", "") })
		if row.Error == "" {
			st, err := env.RepoState(folder, rel)
			switch {
			case err != nil:
				// git's own words may name folders (FILES-01).
				row.Error = "the git state of " + rel + " could not be read"
			case !st.Git:
				row.Git = gitNotGit
			case st.Dirty:
				row.Git = gitChanged
			default:
				row.Git = gitClean
			}
		}
		out = append(out, row)
	}
	return out, nil
}

// readInto fills row from the file at path: a file the coach's reader calls
// missing (the rules file, workflow.md) is an empty text with the budget of
// an empty text, as AGENTS.md and CLAUDE.md read when absent; a refused read
// (a symlink anywhere below the root, too large, not text) carries the reason.
func readInto(row *instructionRow, path string, read func() (coach.CurrentText, error)) {
	_, err := os.Lstat(path)
	row.Exists = !errors.Is(err, fs.ErrNotExist)
	cur, err := read()
	switch {
	case err == nil:
		row.Text, row.BudgetRunes = cur.Text, cur.Budget
	case coach.IsMissing(err):
		row.Exists, row.BudgetRunes = false, coach.BudgetOf(row.Destination, "")
	default:
		row.Error = err.Error()
	}
}

type proposalRow struct {
	ID          int64  `json:"id"`
	Status      string `json:"status"`
	Origin      string `json:"origin"`
	Destination string `json:"destination"`
	Skill       string `json:"skill,omitempty"`
	PromptID    string `json:"prompt_id,omitempty"`
	WorkbenchID int64  `json:"workbench_id,omitempty"`
	Title       string `json:"title"`
	Why         string `json:"why"`
	// The texts come only with id: a listing of skill-sized texts would pass
	// the read cap (tools.MaxReadResultBytes) after a few proposals.
	BeforeText *string `json:"before_text,omitempty"`
	AfterText  *string `json:"after_text,omitempty"`
}

type listProposalsArgs struct {
	ID          int64  `json:"id,omitempty" jsonschema:"one proposal, with its before and after texts"`
	Destination string `json:"destination,omitempty" jsonschema:"only proposals for this destination"`
	Skill       string `json:"skill,omitempty" jsonschema:"only proposals for this skill"`
	Limit       int    `json:"limit,omitempty" jsonschema:"most rows to return; default 50, at most 100"`
}

const (
	proposalsDefaultLimit = 50
	proposalsMaxLimit     = 100 // rows carry why (≤ 600 runes): 100 stay well under the read cap
)

// listCoachProposals is list_coach_proposals: every status, newest first,
// without texts; with id, that one proposal with its texts.
func listCoachProposals(d *db.DB, a listProposalsArgs) ([]proposalRow, error) {
	if a.ID != 0 {
		p, err := d.GetCoachProposal(a.ID)
		if err != nil {
			return nil, err
		}
		r := proposalRowOf(p)
		r.BeforeText, r.AfterText = &p.BeforeText, &p.AfterText
		return []proposalRow{r}, nil
	}
	limit := a.Limit
	switch {
	case limit <= 0:
		limit = proposalsDefaultLimit
	case limit > proposalsMaxLimit:
		limit = proposalsMaxLimit
	}
	ps, err := d.ListCoachProposals()
	if err != nil {
		return nil, err
	}
	out := make([]proposalRow, 0, min(len(ps), limit))
	for _, p := range ps {
		if (a.Destination != "" && p.Destination != a.Destination) || (a.Skill != "" && p.Skill != a.Skill) {
			continue
		}
		if len(out) == limit {
			break
		}
		out = append(out, proposalRowOf(p))
	}
	return out, nil
}

func proposalRowOf(p db.CoachProposal) proposalRow {
	return proposalRow{ID: p.ID, Status: p.Status, Origin: p.Origin, Destination: p.Destination,
		Skill: p.Skill, PromptID: p.PromptID, WorkbenchID: p.WorkbenchID, Title: p.Title, Why: p.Why}
}

// folderOf is the workbench's own folder (projects.folder_path).
func folderOf(d *db.DB, wb int64) (string, error) {
	w, err := d.GetWorkbench(wb)
	if err != nil {
		return "", err
	}
	return w.FolderPath, nil
}

// codexHomeOf is Codex's home: codexHome when set, else <home>/.codex (the
// coach's own rule).
func codexHomeOf(home, codexHome string) string {
	if codexHome != "" {
		return codexHome
	}
	return filepath.Join(home, ".codex")
}

// homePath shows p as "~/…" when it is under home, else as it is (a
// $CODEX_HOME elsewhere).
func homePath(home, p string) string {
	if rel, err := filepath.Rel(home, p); err == nil && rel != "." && rel != ".." &&
		!strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "~/" + filepath.ToSlash(rel)
	}
	return p
}
