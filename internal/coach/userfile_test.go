package coach

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// fileApplier is an Applier with a temp home and a separate temp Codex home.
func fileApplier(t *testing.T, d dbs) *Applier {
	t.Helper()
	a := newApplier(t, d)
	a.CodexHome = t.TempDir()
	return a
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, []byte(text), 0o640))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(raw)
}

// fileDest is one file destination under test: where its file is and how to
// name it in a proposal.
type fileDest struct {
	dest, skill string
	path        func(a *Applier) string
}

func fileDests() []fileDest {
	return []fileDest{
		{DestClaudeSkillUser, "a", func(a *Applier) string { return ClaudeSkillPath(a.env(), "a") }},
		{DestCodexSkillUser, "a", func(a *Applier) string {
			return filepath.Join(a.Home, ".agents", "skills", "a", "SKILL.md")
		}},
		{DestCodexAgentsMDUser, "", func(a *Applier) string { return codexAgentsMDPath(a.env()) }},
	}
}

func (f fileDest) proposal(before, after string) db.CoachProposal {
	return db.CoachProposal{Destination: f.dest, Skill: f.skill, BeforeText: before, AfterText: after}
}

func TestUserFile_RefusesSymlinkFile(t *testing.T) {
	d := openDBs(t)
	for _, f := range fileDests() {
		a := fileApplier(t, d)
		target := filepath.Join(t.TempDir(), "elsewhere.md")
		writeFile(t, target, "X")
		path := f.path(a)
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
		require.NoError(t, os.Symlink(target, path))
		_, err := a.readCurrent(f.proposal("X", "XY"))
		require.ErrorIs(t, err, errUnsafeFile, f.dest)
		assert.NotContains(t, err.Error(), a.Home, f.dest)
		assert.NotContains(t, err.Error(), a.CodexHome, f.dest)
	}
}

func TestUserFile_RefusesSymlinkedSkillFolder(t *testing.T) {
	d := openDBs(t)
	real := t.TempDir()
	writeFile(t, filepath.Join(real, "SKILL.md"), "X")
	for _, f := range fileDests()[:2] {
		a := fileApplier(t, d)
		link := filepath.Dir(f.path(a)) // skills/a
		require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o700))
		require.NoError(t, os.Symlink(real, link))
		_, err := a.readCurrent(f.proposal("X", "XY"))
		require.ErrorIs(t, err, errUnsafeFile, f.dest)
	}

	// A symlinked ~/.claude, and a symlinked ~/.codex when no CODEX_HOME is set.
	a := newApplier(t, d)
	writeFile(t, filepath.Join(real, "skills", "a", "SKILL.md"), "X")
	require.NoError(t, os.Symlink(real, filepath.Join(a.Home, ".claude")))
	_, err := a.readCurrent(fileDests()[0].proposal("X", "XY"))
	require.ErrorIs(t, err, errUnsafeFile)

	a = newApplier(t, d)
	writeFile(t, filepath.Join(real, "AGENTS.md"), "X")
	require.NoError(t, os.Symlink(real, filepath.Join(a.Home, ".codex")))
	_, err = a.readCurrent(fileDests()[2].proposal("X", "XY"))
	require.ErrorIs(t, err, errUnsafeFile)
	_, err = a.readCurrent(db.CoachProposal{Destination: DestCodexSkillUser, Skill: "a"})
	require.ErrorIs(t, err, errUnsafeFile, "the ~/.codex/skills copy behind a symlinked ~/.codex")
}

func TestUserFile_RefusesOversized(t *testing.T) {
	d := openDBs(t)
	for _, f := range fileDests() {
		a := fileApplier(t, d)
		writeFile(t, f.path(a), strings.Repeat("a", claudeMDMaxBytes+1))
		_, err := a.readCurrent(f.proposal("", "x"))
		require.ErrorIs(t, err, errUnsafeFile, f.dest)
	}
}

func TestUserFile_RefusesNonUTF8(t *testing.T) {
	d := openDBs(t)
	for _, f := range fileDests() {
		a := fileApplier(t, d)
		writeFile(t, f.path(a), string([]byte{0xff}))
		_, err := a.readCurrent(f.proposal("", "x"))
		require.ErrorIs(t, err, errUnsafeFile, f.dest)
	}
}

func TestUserFile_MissingSkillRefused(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	for _, dest := range []string{DestClaudeSkillUser, DestCodexSkillUser} {
		_, err := a.readCurrent(db.CoachProposal{Destination: dest, Skill: "nope"})
		require.ErrorIs(t, err, errSkillNotFound, dest)
	}
	cur, err := a.readCurrent(db.CoachProposal{Destination: DestCodexAgentsMDUser})
	require.NoError(t, err)
	assert.Empty(t, cur.Text)
	assert.Equal(t, 400, cur.Budget)

	// Accept never creates a skill.
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeSkillUser, Skill: "nope", AfterText: "New."})
	require.ErrorIs(t, a.Accept(id, ""), errSkillNotFound)
	assert.NoFileExists(t, ClaudeSkillPath(a.env(), "nope"))
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestUserFile_BadSkillNameRefused(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	for _, name := range []string{"../x", "a/b", "", "..", ".hidden", "a|b", strings.Repeat("a", 65)} {
		for _, dest := range []string{DestClaudeSkillUser, DestCodexSkillUser} {
			_, err := a.readCurrent(db.CoachProposal{Destination: dest, Skill: name})
			require.ErrorIs(t, err, errBadSkillName, "%s %q", dest, name)
		}
	}
	require.NoError(t, checkSkillName("review-pr_2.v1"))
}

func TestUserFile_PackCopyRefused(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	writeFile(t, ClaudeSkillPath(a.env(), "watchtower-workbench"),
		"---\nname: watchtower-workbench\nx-watchtower-pack: 1\n---\nBody.\n")
	_, err := a.readCurrent(db.CoachProposal{Destination: DestClaudeSkillUser, Skill: "watchtower-workbench"})
	require.ErrorIs(t, err, errPackSkill)
}

func TestCodexSkillPath_Precedence(t *testing.T) {
	home := t.TempDir()
	e := Env{Home: home}
	legacy := filepath.Join(home, ".codex", "skills", "x", "SKILL.md")
	agents := filepath.Join(home, ".agents", "skills", "x", "SKILL.md")

	_, ok := CodexSkillPath(e, "x")
	assert.False(t, ok, "neither")

	writeFile(t, legacy, "L")
	got, ok := CodexSkillPath(e, "x")
	require.True(t, ok)
	assert.Equal(t, legacy, got)

	writeFile(t, agents, "A")
	got, ok = CodexSkillPath(e, "x")
	require.True(t, ok)
	assert.Equal(t, agents, got, "~/.agents/skills wins")

	// CODEX_HOME is honoured for the second root.
	ch := t.TempDir()
	e = Env{Home: t.TempDir(), CodexHome: ch}
	writeFile(t, filepath.Join(ch, "skills", "x", "SKILL.md"), "C")
	got, ok = CodexSkillPath(e, "x")
	require.True(t, ok)
	assert.Equal(t, filepath.Join(ch, "skills", "x", "SKILL.md"), got)
	assert.Equal(t, filepath.Join(ch, "AGENTS.md"), codexAgentsMDPath(e))
	assert.Equal(t, filepath.Join(home, ".codex", "AGENTS.md"), codexAgentsMDPath(Env{Home: home}))
}

func TestBudgetOf_NewDestinations(t *testing.T) {
	assert.Equal(t, 2100, BudgetOf(DestClaudeSkillUser, strings.Repeat("a", 100)))
	assert.Equal(t, 20000, BudgetOf(DestCodexSkillUser, strings.Repeat("a", 19000)))
	assert.Equal(t, 21000, BudgetOf(DestClaudeSkillUser, strings.Repeat("a", 21000)))
	assert.Equal(t, 400, BudgetOf(DestCodexAgentsMDUser, ""))
	assert.Equal(t, 1000, BudgetOf(DestPackOverlay, ""))
	assert.Equal(t, 0, BudgetOf(DestCodexRulesAllow, ""))

	// ValidateAfter holds the three file destinations to their budget.
	for _, dest := range []string{DestClaudeSkillUser, DestCodexSkillUser, DestCodexAgentsMDUser} {
		cur := CurrentText{Destination: dest, Text: "a", Budget: BudgetOf(dest, "a")}
		require.NoError(t, ValidateAfter(cur, "ab"), dest)
		require.Error(t, ValidateAfter(cur, strings.Repeat("b", cur.Budget+1)), dest)
	}
}

func TestAccept_SkillRoundTrip(t *testing.T) {
	d := openDBs(t)
	for _, f := range fileDests()[:2] {
		a := fileApplier(t, d)
		path := f.path(a)
		writeFile(t, path, "Read the plan.\n")
		// For Codex the losing copy is never touched.
		loser := filepath.Join(a.CodexHome, "skills", "a", "SKILL.md")
		writeFile(t, loser, "Read the plan.\n")

		p := f.proposal("Read the plan.\n", "Read the plan.\nRun package tests only.\n")
		p.Kind, p.Fingerprint = "replace", f.dest+"|rt"
		id := propose(t, d, p)
		require.NoError(t, a.Accept(id, ""), f.dest)
		assert.Equal(t, "Read the plan.\nRun package tests only.\n", readFile(t, path))
		fi, err := os.Stat(path)
		require.NoError(t, err)
		assert.Equal(t, os.FileMode(0o640), fi.Mode().Perm(), "mode kept")
		assert.Equal(t, "accepted", proposal(t, d, id).Status)
		if f.dest == DestCodexSkillUser {
			assert.Equal(t, "Read the plan.\n", readFile(t, loser), "loser byte-identical")
		}

		_, err = a.Rollback(id, false)
		require.NoError(t, err, f.dest)
		assert.Equal(t, "Read the plan.\n", readFile(t, path))
		assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
	}
}

func TestAccept_SkillChangedAfterReread_IsStale(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	f := fileDests()[0]
	path := f.path(a)
	writeFile(t, path, "Before.")
	id := propose(t, d, f.proposal("Before.", "After."))
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	writeFile(t, path, "The owner's edit.") // lands after the read
	_, err = a.writeDestination(p, cur, "After.", applyNow)
	require.ErrorIs(t, err, ErrStale)
	assert.Equal(t, "The owner's edit.", readFile(t, path))

	// Through Accept the proposal is superseded and the file kept.
	require.ErrorIs(t, a.Accept(id, ""), ErrStale)
	assert.Equal(t, "superseded", proposal(t, d, id).Status)
	assert.Equal(t, "The owner's edit.", readFile(t, path))

	// The writer itself re-reads just before the rename.
	raw, mode, exists, err := skillFileKind.read(a.Home, path)
	require.NoError(t, err)
	writeFile(t, path, "Later.")
	require.ErrorIs(t, writeAtomic(skillFileKind.atomic(a.Home), path, []byte("X"), mode, raw, exists),
		skillFileKind.changed)
	assert.Equal(t, "Later.", readFile(t, path))
}

func TestRollback_CreatedAgentsMDLeftEmpty(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d) // default Codex home: <Home>/.codex, created by Accept
	path := codexAgentsMDPath(a.env())
	id := propose(t, d, db.CoachProposal{Destination: DestCodexAgentsMDUser, AfterText: "Run tests.\n"})
	require.NoError(t, a.Accept(id, ""))
	assert.Equal(t, "Run tests.\n", readFile(t, path))
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	di, err := os.Stat(filepath.Dir(path))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())

	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	fi, err = os.Stat(path)
	require.NoError(t, err, "never removed")
	assert.Zero(t, fi.Size())
}

func TestAccept_CreatedAgentsMDStatusFailureLeavesEmpty(t *testing.T) {
	d := openDBs(t)
	a := fileApplier(t, d)
	path := codexAgentsMDPath(a.env())
	id := propose(t, d, db.CoachProposal{Destination: DestCodexAgentsMDUser, AfterText: "Run tests.\n"})
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	w, err := a.writeDestination(p, cur, "Run tests.\n", applyNow)
	require.NoError(t, err)
	require.NoError(t, d.DecideCoachProposal(id, "open", "declined", applyNow))
	require.ErrorIs(t, d.MarkCoachAccepted(id, w.result, nil, 0, applyNow), db.ErrCoachStateChanged)
	require.NoError(t, w.undo())
	fi, err := os.Stat(path)
	require.NoError(t, err, "never removed")
	assert.Zero(t, fi.Size())
}
