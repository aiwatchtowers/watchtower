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

var (
	claudeSkills = skillKind{agentkind.Claude, coach.DestClaudeSkillUser, coach.DestRepoClaudeSkill, ".claude"}
	codexSkills  = skillKind{agentkind.Codex, coach.DestCodexSkillUser, coach.DestRepoCodexSkill, ".agents"}
	skillKinds   = []skillKind{claudeSkills, codexSkills}
)

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
		readTool[struct{}]("list_coach_proposals",
			"List every coach proposal — open, accepted, declined, rolled back — with its texts, so you never "+
				"propose an edit that is already open, accepted or declined.",
			func(_ context.Context, d *db.DB, _ tools.Binding, _ struct{}) (any, error) {
				return listCoachProposals(d)
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
// folder's skills (when the chat has a workbench).
func listSkills(d *db.DB, deps Deps, b tools.Binding, wbArg int64) ([]skillRow, error) {
	env := deps.CoachEnv()
	if env.Home == "" {
		return nil, errors.New("no home folder")
	}
	out := []skillRow{}
	for _, name := range skillNames(filepath.Join(env.Home, ".claude"), "skills") {
		out = append(out, skillRow{Agent: string(claudeSkills.agent), Scope: scopeHome, Name: name,
			Path: homePath(env.Home, coach.ClaudeSkillPath(env, name)), Destination: coach.DestClaudeSkillUser})
	}
	agents, codexHome := filepath.Join(env.Home, ".agents"), codexHomeOf(env.Home, env.CodexHome)
	in := map[string][]string{}
	for _, top := range []string{agents, codexHome} {
		for _, name := range skillNames(top, "skills") {
			in[name] = append(in[name], filepath.Join(top, "skills", name, "SKILL.md"))
		}
	}
	for _, name := range slices.Sorted(maps.Keys(in)) {
		row := skillRow{Agent: string(codexSkills.agent), Scope: scopeHome, Name: name, Destination: coach.DestCodexSkillUser}
		if len(in[name]) > 1 {
			// Codex loads both copies; the coach refuses to edit either (ask #1202).
			row.Destination = ""
			if _, err := coach.ReadText(d, env, coach.DestCodexSkillUser, 0, "", name); err != nil {
				row.Note = err.Error()
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
	for _, k := range skillKinds {
		if !realDir(folder, k.repoTop) {
			continue
		}
		for _, name := range skillNames(filepath.Join(folder, k.repoTop), "skills") {
			rel, _ := coach.RepoRelPath(k.repo, name)
			out = append(out, skillRow{Agent: string(k.agent), Scope: scopeWorkbench, Name: name, Path: rel, Destination: k.repo})
		}
	}
	return out, nil
}

// skillNames is the skill folders in top/sub, sorted: valid skill names that
// are real folders (never a symlink) holding a SKILL.md entry, minus
// Watchtower's pack skills (listed once, as the pack). top itself may be a
// symlink (a dotfiles home, D71); sub must be a real folder. A folder that
// cannot be read lists nothing: get_skill reports why.
func skillNames(top, sub string) []string {
	if fi, err := os.Stat(top); err != nil || !fi.IsDir() || !realDir(top, sub) {
		return nil
	}
	entries, err := os.ReadDir(filepath.Join(top, sub))
	if err != nil {
		return nil
	}
	pack := devpack.PackSkillNames()
	var out []string
	for _, e := range entries {
		name := e.Name()
		// RepoRelPath accepts exactly the coach's skill names.
		if _, ok := coach.RepoRelPath(coach.DestRepoClaudeSkill, name); !ok || !e.IsDir() || slices.Contains(pack, name) {
			continue
		}
		if _, err := os.Lstat(filepath.Join(top, sub, name, "SKILL.md")); err == nil {
			out = append(out, name)
		}
	}
	return out
}

// realDir reports whether root/rel is a folder with no symlink among rel's
// components (root itself is resolved by the OS).
func realDir(root, rel string) bool {
	cur := root
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil || !fi.IsDir() {
			return false
		}
	}
	return true
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
		return nil, &tools.ValidationError{Msg: fmt.Sprintf("invalid scope %q: must be home or workbench", a.Scope)}
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
	kind, _ := agentkind.Parse(a.Agent)
	k := skillKinds[slices.IndexFunc(skillKinds, func(k skillKind) bool { return k.agent == kind })]
	env := deps.CoachEnv()
	row := skillRow{Agent: a.Agent, Scope: a.Scope, Name: a.Name, Destination: k.home}
	var wb int64
	if a.Scope == scopeWorkbench {
		var err error
		if wb, err = workbenchOf(d, b, a.WorkbenchID); err != nil {
			return nil, err
		}
		row.Destination = k.repo
		row.Path, _ = coach.RepoRelPath(k.repo, a.Name)
	} else {
		// The Claude skill's path, or the one Codex copy (none when the skill
		// is in neither or both Codex folders: the read says which).
		p, ok := coach.ClaudeSkillPath(env, a.Name), true
		if k.home == coach.DestCodexSkillUser {
			p, ok = coach.CodexSkillPath(env, a.Name)
		}
		if ok {
			row.Path = homePath(env.Home, p)
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
	env := deps.CoachEnv()
	if env.Home == "" {
		return nil, errors.New("no home folder")
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
			row.Error = "workbench folder not found"
			out = append(out, row)
			continue
		}
		readInto(&row, filepath.Join(folder, filepath.FromSlash(rel)),
			func() (coach.CurrentText, error) { return coach.ReadText(d, env, dest, wb, "", "") })
		if row.Error == "" {
			st, err := env.RepoState(folder, rel)
			switch {
			case err != nil:
				row.Error = "git state not read: " + err.Error()
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

// readInto fills row from the file at path: a missing file is an empty text
// with the destination's budget for an empty text (the missing rules file and
// workflow.md are errors to the coach's reader, but not to this list); an
// existing file the reader refuses carries the reason.
func readInto(row *instructionRow, path string, read func() (coach.CurrentText, error)) {
	_, err := os.Lstat(path)
	row.Exists = !errors.Is(err, fs.ErrNotExist)
	cur, err := read()
	switch {
	case err == nil:
		row.Text, row.BudgetRunes = cur.Text, cur.Budget
	case !row.Exists:
		row.BudgetRunes = coach.BudgetOf(row.Destination, "")
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
	BeforeText  string `json:"before_text"`
	AfterText   string `json:"after_text"`
}

// listCoachProposals is list_coach_proposals: every status, newest first.
func listCoachProposals(d *db.DB) ([]proposalRow, error) {
	ps, err := d.ListCoachProposals()
	if err != nil {
		return nil, err
	}
	out := make([]proposalRow, 0, len(ps))
	for _, p := range ps {
		out = append(out, proposalRow{ID: p.ID, Status: p.Status, Origin: p.Origin, Destination: p.Destination,
			Skill: p.Skill, PromptID: p.PromptID, WorkbenchID: p.WorkbenchID, Title: p.Title, Why: p.Why,
			BeforeText: p.BeforeText, AfterText: p.AfterText})
	}
	return out, nil
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
	if rel, err := filepath.Rel(home, p); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		return "~/" + filepath.ToSlash(rel)
	}
	return p
}
