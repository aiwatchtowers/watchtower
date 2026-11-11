package tuning

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchgit"
)

// gitRepoState is the RepoState cmd wires (workbenchgit.PathStatus, `git
// status` only), for the tests' temporary repositories.
func gitRepoState(folder, rel string) (coach.RepoFileState, error) {
	st, err := workbenchgit.PathStatus(context.Background(), workbenchgit.Options{Folder: folder}, rel)
	return coach.RepoFileState{Git: st.Git, Dirty: st.Dirty}, err
}

// runGit runs git in dir for a test's own setup, with the owner's config
// kept out.
func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	c := exec.Command(bin, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com")
	var stderr bytes.Buffer
	c.Stderr = &stderr
	require.NoError(t, c.Run(), "git %s: %s", strings.Join(args, " "), stderr.String())
}

func put(t *testing.T, path, text string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o644))
}

// rows calls a tool whose result is a JSON array and decodes it.
func (f *fixture) rows(t *testing.T, name, args string) []map[string]any {
	t.Helper()
	res, err := f.reg.CallRead(context.Background(), name, json.RawMessage(args), f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	var out []map[string]any
	require.NoError(t, json.Unmarshal(raw, &out), string(raw))
	return out
}

// find is the row of rows matching every key/value of want.
func find(rows []map[string]any, want map[string]any) map[string]any {
	for _, r := range rows {
		ok := true
		for k, v := range want {
			if r[k] != v {
				ok = false
				break
			}
		}
		if ok {
			return r
		}
	}
	return nil
}

// repoWorkbench makes the fixture's workbench folder a git repository whose
// one commit holds files.
func (f *fixture) repoWorkbench(t *testing.T, files map[string]string) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	runGit(t, dir, "init", "-q", "-b", "main")
	files["README.md"] = "acme\n"
	for rel, text := range files {
		put(t, filepath.Join(dir, filepath.FromSlash(rel)), text)
	}
	runGit(t, dir, "add", "-A")
	runGit(t, dir, "commit", "-q", "-m", "init")
	f.wb, err = f.d.CreateWorkbench("repo", dir)
	require.NoError(t, err)
	return dir
}

func TestGetSkill_Refusals(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, skillDir string)
	}{
		{"symlinked SKILL.md", func(t *testing.T, skillDir string) {
			target := filepath.Join(t.TempDir(), "target.md")
			put(t, target, "Real.\n")
			require.NoError(t, os.MkdirAll(skillDir, 0o755))
			require.NoError(t, os.Symlink(target, filepath.Join(skillDir, "SKILL.md")))
		}},
		{"too large", func(t *testing.T, skillDir string) {
			put(t, filepath.Join(skillDir, "SKILL.md"), strings.Repeat("a", 300<<10))
		}},
		{"not UTF-8", func(t *testing.T, skillDir string) {
			put(t, filepath.Join(skillDir, "SKILL.md"), "ok \xff\xfe\n")
		}},
		{"missing", func(*testing.T, string) {}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			skillDir := filepath.Join(f.home, ".claude", "skills", "acme")
			c.setup(t, skillDir)
			before := snapshot(t, f.home)
			_, err := f.call(t, "get_skill", `{"agent":"claude","name":"acme"}`)
			require.Error(t, err)
			var ve *tools.ValidationError
			require.ErrorAs(t, err, &ve)
			assert.Contains(t, err.Error(), "acme")
			assert.Equal(t, before, snapshot(t, f.home), "nothing written")
		})
	}
}

// snapshot is every path under root with its size: a cheap "nothing written".
func snapshot(t *testing.T, root string) map[string]int64 {
	t.Helper()
	out := map[string]int64{}
	require.NoError(t, filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		out[p] = fi.Size()
		return nil
	}))
	return out
}

func TestGetSkill_ClaudeHome(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.home, ".claude", "skills", "acme", "SKILL.md"), "Read the plan.\n")
	out, err := f.call(t, "get_skill", `{"agent":"claude","name":"acme"}`)
	require.NoError(t, err)
	assert.Equal(t, "Read the plan.\n", out["text"])
	assert.Equal(t, "~/.claude/skills/acme/SKILL.md", out["path"])
	assert.Equal(t, "home", out["scope"])
	assert.Equal(t, coach.DestClaudeSkillUser, out["destination"])
	assert.InDelta(t, coach.BudgetOf(coach.DestClaudeSkillUser, "Read the plan.\n"), out["budget_runes"], 0)
}

// D71: the home folder itself may be a symlink (a dotfiles setup).
func TestSkills_SymlinkedHomeFolder(t *testing.T) {
	f := newFixture(t)
	target := t.TempDir()
	put(t, filepath.Join(target, "skills", "acme", "SKILL.md"), "Linked.\n")
	require.NoError(t, os.Symlink(target, filepath.Join(f.home, ".claude")))
	out, err := f.call(t, "get_skill", `{"agent":"claude","name":"acme"}`)
	require.NoError(t, err)
	assert.Equal(t, "Linked.\n", out["text"])
	assert.NotNil(t, find(f.rows(t, "list_skills", `{}`), map[string]any{"agent": "claude", "scope": "home", "name": "acme"}))
}

func TestGetSkill_CodexOneFolder(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.home, ".codex", "skills", "acme", "SKILL.md"), "Codex home copy.\n")
	out, err := f.call(t, "get_skill", `{"agent":"codex","name":"acme"}`)
	require.NoError(t, err)
	assert.Equal(t, "Codex home copy.\n", out["text"])
	assert.Equal(t, "~/.codex/skills/acme/SKILL.md", out["path"])
	assert.Equal(t, coach.DestCodexSkillUser, out["destination"])
}

// Codex loads a skill from both folders; a name in both is shown twice with
// the two-folders note and is not proposable (owner, ask #1202).
func TestGetSkill_CodexBothFolders(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.home, ".agents", "skills", "acme", "SKILL.md"), "Agents copy.\n")
	put(t, filepath.Join(f.home, ".codex", "skills", "acme", "SKILL.md"), "Codex home copy.\n")
	const note = "Codex sees this skill in two folders (~/.agents/skills and ~/.codex/skills) — remove one copy first."

	_, err := f.call(t, "get_skill", `{"agent":"codex","name":"acme"}`)
	require.Error(t, err)
	assert.Contains(t, err.Error(), note)

	rows := f.rows(t, "list_skills", `{}`)
	var copies []map[string]any
	for _, r := range rows {
		if r["agent"] == "codex" && r["name"] == "acme" {
			copies = append(copies, r)
		}
	}
	require.Len(t, copies, 2)
	assert.Equal(t, "~/.agents/skills/acme/SKILL.md", copies[0]["path"])
	assert.Equal(t, "~/.codex/skills/acme/SKILL.md", copies[1]["path"])
	for _, c := range copies {
		assert.Equal(t, note, c["note"])
		assert.Nil(t, c["destination"], "not proposable")
	}
}

func TestListSkills_HomeAndPack(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.home, ".claude", "skills", "acme", "SKILL.md"), "A.\n")
	put(t, filepath.Join(f.home, ".agents", "skills", "beta", "SKILL.md"), "B.\n")
	// A pack copy in the home folder is listed once, as the pack skill.
	pack, _ := devpack.WorkbenchSkill()
	put(t, filepath.Join(f.home, ".claude", "skills", pack, "SKILL.md"), "copy\n")
	// Not skills: a folder without SKILL.md, a dot folder, a plain file.
	require.NoError(t, os.MkdirAll(filepath.Join(f.home, ".claude", "skills", "empty"), 0o755))
	put(t, filepath.Join(f.home, ".codex", "skills", ".system", "x", "SKILL.md"), "S.\n")
	put(t, filepath.Join(f.home, ".claude", "skills", "notes.md"), "N.\n")
	_, err := f.d.EditSkillPackOverlays(pack, nil, []db.SkillPackOverlay{{Skill: pack, Text: "Ask before pushing."}}, testNow)
	require.NoError(t, err)

	rows := f.rows(t, "list_skills", `{}`)
	claude := find(rows, map[string]any{"agent": "claude", "name": "acme"})
	require.NotNil(t, claude)
	assert.Equal(t, coach.DestClaudeSkillUser, claude["destination"])
	codex := find(rows, map[string]any{"agent": "codex", "name": "beta"})
	require.NotNil(t, codex)
	assert.Equal(t, coach.DestCodexSkillUser, codex["destination"])
	assert.Nil(t, codex["note"])
	assert.Nil(t, find(rows, map[string]any{"agent": "claude", "name": pack}))
	assert.Nil(t, find(rows, map[string]any{"name": "empty"}))
	assert.Nil(t, find(rows, map[string]any{"name": ".system"}))
	assert.Nil(t, find(rows, map[string]any{"name": "notes.md"}))

	ws := find(rows, map[string]any{"agent": "watchtower", "name": pack})
	require.NotNil(t, ws)
	assert.Equal(t, "pack", ws["scope"])
	assert.Equal(t, coach.DestPackOverlay, ws["destination"])
	assert.Equal(t, []any{"Ask before pushing."}, ws["overlay_lines"])
	for _, name := range devpack.PackSkillNames() {
		assert.NotNil(t, find(rows, map[string]any{"agent": "watchtower", "name": name}), name)
	}
}

func TestGetSkill_PackWithOverlay(t *testing.T) {
	f := newFixture(t)
	name, body := devpack.FlowSkill()
	_, err := f.d.EditSkillPackOverlays(name, nil, []db.SkillPackOverlay{{Skill: name, Text: "Keep plans short."}}, testNow)
	require.NoError(t, err)
	out, err := f.call(t, "get_skill", fmt.Sprintf(`{"agent":"watchtower","name":%q}`, name))
	require.NoError(t, err)
	want := devpack.Render(devpack.Skill{Name: name, Content: string(body)}, []string{"Keep plans short."}).Content
	assert.Equal(t, want, out["text"])
	assert.Equal(t, []any{"Keep plans short."}, out["overlay_lines"])
	assert.InDelta(t, coach.BudgetOf(coach.DestPackOverlay, ""), out["budget_runes"], 0)

	_, err = f.call(t, "get_skill", `{"agent":"watchtower","name":"acme"}`)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "acme is not a Watchtower pack skill")
	_, err = f.call(t, "get_skill", fmt.Sprintf(`{"agent":"claude","name":%q}`, name))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "is a Watchtower pack skill")
}

func TestGetSkill_BadArgs(t *testing.T) {
	f := newFixture(t)
	for args, want := range map[string]string{
		`{"agent":"gpt","name":"acme"}`:                         `invalid agent "gpt"`,
		`{"agent":"claude","name":"../x"}`:                      `"../x" is not a skill name`,
		`{"agent":"claude","name":"acme","scope":"global"}`:     `invalid scope "global"`,
		`{"agent":"watchtower","name":"x","scope":"workbench"}`: "pack skill has no workbench copy",
	} {
		_, err := f.call(t, "get_skill", args)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), want, args)
	}
}

func TestGetAgentInstructions_MissingCodexFiles(t *testing.T) {
	f := newFixture(t)
	rows := f.rows(t, "get_agent_instructions", `{}`)
	for _, dest := range []string{coach.DestCodexAgentsMDUser, coach.DestCodexRulesAllow} {
		r := find(rows, map[string]any{"destination": dest})
		require.NotNil(t, r, dest)
		assert.Equal(t, false, r["exists"], dest)
		assert.Equal(t, "", r["text"], dest)
		assert.InDelta(t, coach.BudgetOf(dest, ""), r["budget_runes"], 0, dest)
		assert.Nil(t, r["git"], dest)
		assert.Nil(t, r["error"], dest)
	}
}

func TestGetAgentInstructions_HomeFiles(t *testing.T) {
	f := newFixture(t)
	put(t, filepath.Join(f.home, ".claude", "CLAUDE.md"), "Run tests.\n")
	put(t, filepath.Join(f.home, ".claude", "settings.json"), `{"permissions":{"allow":["Bash(go test:*)"]}}`)
	put(t, filepath.Join(f.home, ".codex", "AGENTS.md"), "Be brief.\n")
	put(t, filepath.Join(f.home, ".codex", "rules", "default.rules"), coach.CodexRuleLine([]string{"ls"})+"\n")
	rows := f.rows(t, "get_agent_instructions", `{}`)
	for dest, want := range map[string]string{
		coach.DestClaudeMDUser:      "Run tests.\n",
		coach.DestSettingsAllow:     "Bash(go test:*)",
		coach.DestCodexAgentsMDUser: "Be brief.\n",
		coach.DestCodexRulesAllow:   coach.CodexRuleLine([]string{"ls"}) + "\n",
	} {
		r := find(rows, map[string]any{"destination": dest})
		require.NotNil(t, r, dest)
		assert.Equal(t, true, r["exists"], dest)
		assert.Equal(t, want, r["text"], dest)
	}
	assert.Equal(t, "~/.claude/CLAUDE.md", find(rows, map[string]any{"destination": coach.DestClaudeMDUser})["path"])
}

func TestGetAgentInstructions_UnsafeFileIsARowError(t *testing.T) {
	f := newFixture(t)
	target := filepath.Join(t.TempDir(), "target.md")
	put(t, target, "Real.\n")
	require.NoError(t, os.MkdirAll(filepath.Join(f.home, ".claude"), 0o755))
	require.NoError(t, os.Symlink(target, filepath.Join(f.home, ".claude", "CLAUDE.md")))
	rows := f.rows(t, "get_agent_instructions", `{}`)
	r := find(rows, map[string]any{"destination": coach.DestClaudeMDUser})
	require.NotNil(t, r)
	assert.Equal(t, true, r["exists"])
	assert.Equal(t, "", r["text"])
	assert.NotEmpty(t, r["error"])
	assert.NotContains(t, r["error"], f.home, "no path in the error")
}

func TestListCoachProposals_IncludesDeclinedChat(t *testing.T) {
	f := newFixture(t)
	id, err := f.d.InsertCoachProposal(db.CoachProposal{
		Fingerprint: "fp-1", Kind: "add", Destination: coach.DestClaudeMDUser,
		Title: "Run tests first", Why: "asked in the chat", Metric: "corrections", AfterText: "Run tests first.\n", Origin: "chat",
	}, testNow)
	require.NoError(t, err)
	require.NoError(t, f.d.DecideCoachProposal(id, "open", "declined", testNow))

	rows := f.rows(t, "list_coach_proposals", `{}`)
	require.Len(t, rows, 1)
	r := rows[0]
	assert.InDelta(t, id, r["id"], 0)
	assert.Equal(t, "declined", r["status"])
	assert.Equal(t, "chat", r["origin"])
	assert.Equal(t, coach.DestClaudeMDUser, r["destination"])
	assert.Equal(t, "Run tests first", r["title"])
	assert.NotContains(t, r, "after_text", "a listing carries no texts")

	rows = f.rows(t, "list_coach_proposals", fmt.Sprintf(`{"id":%d}`, id))
	require.Len(t, rows, 1)
	assert.Equal(t, "Run tests first.\n", rows[0]["after_text"])
}

// A history of skill-sized proposals stays under the read cap: the listing
// carries no texts and one proposal's texts come by id (review F1).
func TestListCoachProposals_LargeHistoryStaysUnderReadCap(t *testing.T) {
	f := newFixture(t)
	big := strings.Repeat("Ж", 19000) + "\n"
	var last int64
	for i := range 120 {
		id, err := f.d.InsertCoachProposal(db.CoachProposal{
			Fingerprint: fmt.Sprintf("fp-%d", i), Kind: "replace", Destination: coach.DestClaudeSkillUser, Skill: fmt.Sprintf("s%d", i%3),
			Title: fmt.Sprintf("Edit %d", i), Why: strings.Repeat("w", 500), Metric: "corrections",
			BeforeText: big, AfterText: big + "More.\n", Origin: "chat",
		}, testNow)
		require.NoError(t, err)
		require.NoError(t, f.d.DecideCoachProposal(id, "open", "declined", testNow))
		last = id
	}
	rows := f.rows(t, "list_coach_proposals", `{}`)
	assert.Len(t, rows, 50, "default limit")
	assert.InDelta(t, last, rows[0]["id"], 0, "newest first")
	assert.Len(t, f.rows(t, "list_coach_proposals", `{"limit":500}`), 100, "limit is clamped")

	rows = f.rows(t, "list_coach_proposals", `{"destination":"claude_skill_user","skill":"s1","limit":100}`)
	assert.Len(t, rows, 40)
	for _, r := range rows {
		assert.Equal(t, "s1", r["skill"])
	}
	assert.Empty(t, f.rows(t, "list_coach_proposals", `{"destination":"claude_md_user"}`))

	rows = f.rows(t, "list_coach_proposals", fmt.Sprintf(`{"id":%d}`, last))
	require.Len(t, rows, 1)
	assert.Equal(t, big, rows[0]["before_text"])

	_, err := f.call(t, "list_coach_proposals", `{"id":999999}`)
	require.Error(t, err)
}

func TestListCoachProposals_Empty(t *testing.T) {
	f := newFixture(t)
	assert.Empty(t, f.rows(t, "list_coach_proposals", `{}`))
}

func TestWorkbenchFiles_Read(t *testing.T) {
	f := newFixture(t)
	dir := f.repoWorkbench(t, map[string]string{
		"CLAUDE.md":                 "Run tests.\n",
		".claude/skills/x/SKILL.md": "Workbench skill.\n",
		".agents/skills/y/SKILL.md": "Workbench codex skill.\n",
		".watchtower/workflow.md":   "# Workflow\n",
	})

	rows := f.rows(t, "list_skills", `{}`)
	x := find(rows, map[string]any{"agent": "claude", "scope": "workbench", "name": "x"})
	require.NotNil(t, x)
	assert.Equal(t, ".claude/skills/x/SKILL.md", x["path"])
	assert.Equal(t, coach.DestRepoClaudeSkill, x["destination"])
	y := find(rows, map[string]any{"agent": "codex", "scope": "workbench", "name": "y"})
	require.NotNil(t, y)
	assert.Equal(t, coach.DestRepoCodexSkill, y["destination"])

	out, err := f.call(t, "get_skill", `{"agent":"claude","name":"x","scope":"workbench"}`)
	require.NoError(t, err)
	assert.Equal(t, "Workbench skill.\n", out["text"])
	assert.Equal(t, ".claude/skills/x/SKILL.md", out["path"])

	inst := f.rows(t, "get_agent_instructions", `{}`)
	md := find(inst, map[string]any{"destination": coach.DestRepoClaudeMD})
	require.NotNil(t, md)
	assert.Equal(t, "CLAUDE.md", md["path"])
	assert.Equal(t, "Run tests.\n", md["text"])
	assert.Equal(t, "clean", md["git"])
	agents := find(inst, map[string]any{"destination": coach.DestRepoAgentsMD})
	require.NotNil(t, agents)
	assert.Equal(t, false, agents["exists"])
	assert.Equal(t, "clean", agents["git"])
	wf := find(inst, map[string]any{"destination": coach.DestRepoWorkflow})
	require.NotNil(t, wf)
	assert.Equal(t, ".watchtower/workflow.md", wf["path"])
	assert.Equal(t, "# Workflow\n", wf["text"])

	// An unstaged edit → changed; after a commit → clean again.
	put(t, filepath.Join(dir, "CLAUDE.md"), "Run tests twice.\n")
	md = find(f.rows(t, "get_agent_instructions", `{}`), map[string]any{"destination": coach.DestRepoClaudeMD})
	assert.Equal(t, "changed", md["git"])
	runGit(t, dir, "commit", "-q", "-am", "edit")
	md = find(f.rows(t, "get_agent_instructions", `{}`), map[string]any{"destination": coach.DestRepoClaudeMD})
	assert.Equal(t, "clean", md["git"])

	// A symlinked .agents folder: its skills are not listed and not read.
	other := t.TempDir()
	put(t, filepath.Join(other, "skills", "z", "SKILL.md"), "Linked.\n")
	require.NoError(t, os.RemoveAll(filepath.Join(dir, ".agents")))
	require.NoError(t, os.Symlink(other, filepath.Join(dir, ".agents")))
	assert.Nil(t, find(f.rows(t, "list_skills", `{}`), map[string]any{"scope": "workbench", "name": "z"}))
	_, err = f.call(t, "get_skill", `{"agent":"codex","name":"z","scope":"workbench"}`)
	require.Error(t, err)
	var ve *tools.ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, err.Error(), "z")
}

func TestWorkbenchFiles_NotGit(t *testing.T) {
	f := newFixture(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	put(t, filepath.Join(dir, "CLAUDE.md"), "Plain.\n")
	f.wb, err = f.d.CreateWorkbench("plain", dir)
	require.NoError(t, err)
	md := find(f.rows(t, "get_agent_instructions", `{}`), map[string]any{"destination": coach.DestRepoClaudeMD})
	require.NotNil(t, md)
	assert.Equal(t, "not_git", md["git"])
	assert.Equal(t, "Plain.\n", md["text"])
}

func TestWorkbenchFiles_FolderGone(t *testing.T) {
	f := newFixture(t)
	dir := filepath.Join(t.TempDir(), "gone")
	var err error
	f.wb, err = f.d.CreateWorkbench("gone", dir)
	require.NoError(t, err)
	rows := f.rows(t, "get_agent_instructions", `{}`)
	md := find(rows, map[string]any{"destination": coach.DestRepoClaudeMD})
	require.NotNil(t, md)
	assert.Equal(t, "workbench folder not found", md["error"])
	assert.Nil(t, md["git"])
	// The home rows are still read.
	assert.NotNil(t, find(rows, map[string]any{"destination": coach.DestClaudeMDUser}))
}

func TestSkillKinds_EveryAgent(t *testing.T) {
	for _, k := range agentkind.All() {
		_, ok := skillKinds[k]
		assert.True(t, ok, "agent %s has no skill folders", k)
	}
}

func TestSkillTools_CoachEnvNotWired(t *testing.T) {
	f := newFixture(t)
	reg := tools.New(f.d)
	for _, tl := range ReadTools(Deps{}) {
		require.NoError(t, reg.Register(tl))
	}
	for _, name := range []string{"list_skills", "get_agent_instructions"} {
		_, err := reg.CallRead(context.Background(), name, json.RawMessage(`{}`), f.binding(fmt.Sprint(f.wb)))
		require.Error(t, err, name)
		assert.Contains(t, err.Error(), "not wired", name)
	}
	_, err := reg.CallRead(context.Background(), "get_skill", json.RawMessage(`{"agent":"claude","name":"acme"}`), f.binding(fmt.Sprint(f.wb)))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not wired")
}

// A skills folder that exists but cannot be listed is a note row, never an
// empty all-clear.
func TestListSkills_UnreadableFolderIsANote(t *testing.T) {
	f := newFixture(t)
	target := t.TempDir()
	put(t, filepath.Join(target, "acme", "SKILL.md"), "Linked.\n")
	require.NoError(t, os.MkdirAll(filepath.Join(f.home, ".claude"), 0o755))
	require.NoError(t, os.Symlink(target, filepath.Join(f.home, ".claude", "skills")))
	rows := f.rows(t, "list_skills", `{}`)
	assert.Nil(t, find(rows, map[string]any{"name": "acme"}))
	note := find(rows, map[string]any{"agent": "claude", "scope": "home", "path": "~/.claude/skills"})
	require.NotNil(t, note)
	assert.Equal(t, unreadableSkills, note["note"])
	assert.Nil(t, note["destination"])
}

func TestListSkills_WorkbenchFolderGone(t *testing.T) {
	f := newFixture(t)
	var err error
	f.wb, err = f.d.CreateWorkbench("gone", filepath.Join(t.TempDir(), "gone"))
	require.NoError(t, err)
	rows := f.rows(t, "list_skills", `{}`)
	for _, path := range []string{".claude/skills", ".agents/skills"} {
		r := find(rows, map[string]any{"scope": "workbench", "path": path})
		require.NotNil(t, r, path)
		assert.Equal(t, repoFolderGone, r["note"], path)
	}
}

// git's own error text may name folders: the row says which file, never why.
func TestGetAgentInstructions_GitErrorNamesNoFolder(t *testing.T) {
	f := newFixture(t)
	dir := f.repoWorkbench(t, map[string]string{"CLAUDE.md": "Run tests.\n"})
	reg := tools.New(f.d)
	deps := Deps{CoachEnv: func() coach.Env {
		return coach.Env{Home: f.home, RepoState: func(folder, _ string) (coach.RepoFileState, error) {
			return coach.RepoFileState{}, errors.New("git failed in " + folder)
		}}
	}}
	for _, tl := range ReadTools(deps) {
		require.NoError(t, reg.Register(tl))
	}
	res, err := reg.CallRead(context.Background(), "get_agent_instructions", json.RawMessage(`{}`), f.binding(fmt.Sprint(f.wb)))
	require.NoError(t, err)
	raw, err := json.Marshal(res)
	require.NoError(t, err)
	assert.NotContains(t, string(raw), dir)
	assert.Contains(t, string(raw), "the git state of CLAUDE.md could not be read")
}

// A symlinked folder above a missing file is a refusal, not "absent".
func TestGetAgentInstructions_SymlinkedFolderMissingFile(t *testing.T) {
	f := newFixture(t)
	dir := f.repoWorkbench(t, map[string]string{"CLAUDE.md": "Run tests.\n"})
	require.NoError(t, os.Symlink(t.TempDir(), filepath.Join(dir, ".watchtower")))
	wf := find(f.rows(t, "get_agent_instructions", `{}`), map[string]any{"destination": coach.DestRepoWorkflow})
	require.NotNil(t, wf)
	assert.NotEmpty(t, wf["error"])
	assert.Nil(t, wf["git"])
}
