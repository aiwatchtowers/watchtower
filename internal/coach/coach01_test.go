package coach

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// coach01State is every destination the coach can write, read back as the
// owner would see it: the three global texts, the spec reviewer's additions
// and the two files under the home folder.
func coach01State(t *testing.T, d dbs, home string) map[string]string {
	t.Helper()
	g, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	adds, err := d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	state := map[string]string{
		"session": g.Session, "procedure": g.Procedure, "chat": g.Chat,
		"additions": joinAdditions(adds),
	}
	for _, name := range []string{"settings.json", "CLAUDE.md"} {
		b, err := os.ReadFile(filepath.Join(home, ".claude", name))
		require.NoError(t, err)
		state[name] = string(b)
	}
	return state
}

// COACH-01: nothing the coach proposes changes the owner's setup until the
// owner's Accept, and no destination is a repository file.
func TestCOACH01_NothingAppliedWithoutAccept(t *testing.T) {
	d := openDBs(t)
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	settings := "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls:*)\"\n    ]\n  }\n}\n"
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "settings.json"), []byte(settings), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", "CLAUDE.md"), []byte("Be kind.\n"), 0o600))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Run tests. Run lint.\nKeep commits small."))
	_, err := d.AddPromptAddition(prompts.SpecReview, "Do not flag naming choices.", 0, t0)
	require.NoError(t, err)

	before := coach01State(t, d, home)

	// The weekly pass: the model proposes a session, a chat and a prompt edit.
	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }, Logger: log.New(&bytes.Buffer{}, "", 0)}
	n, _, err := p.Run(context.Background(), proposeInputs())
	require.NoError(t, err)
	require.Equal(t, 3, n, "the proposals are stored")
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 3)

	assert.Equal(t, before, coach01State(t, d, home), "a stored proposal changes no destination")

	// Only Accept writes, and only its own destination.
	var chat db.CoachProposal
	for _, pr := range open {
		if pr.Destination == DestChat {
			chat = pr
		}
	}
	require.NotZero(t, chat.ID)
	require.NoError(t, (&Applier{DB: d.DB, AgentLog: d.al, Home: home, Now: func() time.Time { return applyNow }}).acceptErr(chat.ID, ""))
	after := coach01State(t, d, home)
	assert.NotEqual(t, before["chat"], after["chat"], "Accept applies the edit")
	for _, k := range []string{"session", "procedure", "additions", "settings.json", "CLAUDE.md"} {
		assert.Equal(t, before[k], after[k], "accepting one proposal leaves %s alone", k)
	}
}

// COACH-01: the destination set is the owner's own setup; a destination that
// names a repository file is not one, and the two files the coach writes live
// under the home folder's .claude directory.
func TestCOACH01_DestinationsAreNeverRepoFiles(t *testing.T) {
	want := []string{DestClaudeMDUser, DestChat, DestProcedure, DestPromptAdd, DestSession, DestSettingsAllow}
	var got []string
	for dest := range textDestinations {
		got = append(got, dest)
	}
	sort.Strings(got)
	sort.Strings(want)
	assert.Equal(t, want, got, "adding a destination is an owner decision: update COACH-01")

	home := filepath.FromSlash("/home/owner")
	for _, path := range []string{claudeSettingsPath(home), claudeMDPath(home)} {
		assert.True(t, strings.HasPrefix(path, filepath.Join(home, ".claude")+string(filepath.Separator)), path)
	}

	// A model that names a repository file as the destination is dropped.
	for _, dest := range []string{"repo_claude_md", "CLAUDE.md", ".watchtower/workflow.md", ".claude/skills/x/SKILL.md"} {
		raw := `{"proposals":[{"title":"t","why":"w","destination":"` + dest + `","workbench_id":0,"prompt_id":"",` +
			`"kind":"add","find":"","replace":"Keep it short.","metric":"corrections","evidence":["s1","s2","s3"]}]}`
		got, err := Validate(raw, proposeInputs())
		require.NoError(t, err)
		assert.Empty(t, got, dest)
	}
}

// COACH-01: the destinations a tuning chat may name are the six weekly ones
// plus five in the owner's home folders (the Claude and Codex user skills, the
// Watchtower pack overlay, ~/.codex/AGENTS.md and the Codex rules). All five
// are global: none is a per-workbench or repository text. The paths they
// resolve to are pinned by the destination tasks.
func TestCOACH01_HomeDestinationsStayUnderHome(t *testing.T) {
	home := []string{DestClaudeSkillUser, DestCodexSkillUser, DestPackOverlay, DestCodexAgentsMDUser, DestCodexRulesAllow}
	want := append([]string{DestClaudeMDUser, DestChat, DestProcedure, DestPromptAdd, DestSession, DestSettingsAllow}, home...)
	var got []string
	for dest := range chatDestinations {
		got = append(got, dest)
	}
	sort.Strings(got)
	sort.Strings(want)
	assert.Equal(t, want, got, "adding a destination is an owner decision: update COACH-01")

	for _, dest := range home {
		assert.True(t, globalDestinations[dest], dest)
		assert.False(t, textDestinations[dest], "%s is not a weekly destination", dest)
		assert.False(t, strings.HasPrefix(dest, "repo_"), dest)
	}

	// The file destinations resolve under <Home>/.claude/, <Home>/.agents/ or
	// <CodexHome>/, with and without an own CODEX_HOME.
	hdir := t.TempDir()
	under := func(path string, roots ...string) bool {
		for _, r := range roots {
			if strings.HasPrefix(path, r+string(filepath.Separator)) {
				return true
			}
		}
		return false
	}
	for _, e := range []Env{{Home: hdir}, {Home: hdir, CodexHome: t.TempDir()}} {
		roots := []string{filepath.Join(hdir, ".claude"), filepath.Join(hdir, ".agents"), e.codexHome()}
		assert.True(t, under(ClaudeSkillPath(e, "x"), filepath.Join(hdir, ".claude")))
		assert.True(t, under(codexAgentsMDPath(e), e.codexHome()))
		assert.True(t, under(codexRulesPath(e), e.codexHome()))
		_, ok := CodexSkillPath(e, "x")
		assert.False(t, ok)
		for _, p := range []string{filepath.Join(e.codexHome(), "skills", "x", "SKILL.md"),
			filepath.Join(hdir, ".agents", "skills", "x", "SKILL.md")} {
			require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o700))
			require.NoError(t, os.WriteFile(p, []byte("x"), 0o600))
			got, ok := CodexSkillPath(e, "x")
			require.True(t, ok)
			assert.True(t, under(got, roots...), got)
			require.NoError(t, os.Remove(p))
		}
		require.NoError(t, os.RemoveAll(filepath.Join(hdir, ".agents")))
	}
	// With a symlinked ~/.claude (dotfiles) the written file is under the
	// folder it resolves to, never anywhere else.
	dot := t.TempDir()
	linked := t.TempDir()
	require.NoError(t, os.Symlink(dot, filepath.Join(linked, ".claude")))
	u, err := userFileOf(Env{Home: linked}, DestClaudeSkillUser, "x")
	require.NoError(t, err)
	resolved, err := filepath.EvalSymlinks(dot)
	require.NoError(t, err)
	assert.True(t, under(u.path, resolved), u.path)

	// A skill name never leaves its skills folder.
	for _, dest := range []string{DestClaudeSkillUser, DestCodexSkillUser} {
		_, err := userFileOf(Env{Home: hdir}, dest, "../../x")
		require.ErrorIs(t, err, errBadSkillName)
	}
}
