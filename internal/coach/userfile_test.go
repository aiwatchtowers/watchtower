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
	realDir := t.TempDir()
	writeFile(t, filepath.Join(realDir, "SKILL.md"), "X")
	for _, f := range fileDests()[:2] {
		a := fileApplier(t, d)
		link := filepath.Dir(f.path(a)) // skills/a
		require.NoError(t, os.MkdirAll(filepath.Dir(link), 0o700))
		require.NoError(t, os.Symlink(realDir, link))
		_, err := a.readCurrent(f.proposal("X", "XY"))
		require.ErrorIs(t, err, errUnsafeFile, f.dest)
	}

	// Below a symlinked ~/.claude the skills folder may not be a link either.
	a := newApplier(t, d)
	dot := t.TempDir()
	require.NoError(t, os.Symlink(dot, filepath.Join(a.Home, ".claude")))
	require.NoError(t, os.Symlink(realDir, filepath.Join(dot, "skills")))
	_, err := a.readCurrent(db.CoachProposal{Destination: DestClaudeSkillUser, Skill: "a"})
	require.ErrorIs(t, err, errUnsafeFile, "symlinked skills/ under a symlinked ~/.claude")
}

// The home folder itself (~/.claude, ~/.agents, the Codex home) may be a
// symlink to a real folder (dotfiles, ask #1202): the edit lands in the
// resolved folder; a link below it, or the file as a link, is still refused.
func TestUserFile_SymlinkedHomeFolderAllowed(t *testing.T) {
	d := openDBs(t)
	cases := []struct {
		top  func(a *Applier) string
		dest string
		rel  string
	}{
		{func(a *Applier) string { return filepath.Join(a.Home, ".claude") }, DestClaudeSkillUser, "skills/a/SKILL.md"},
		{func(a *Applier) string { return filepath.Join(a.Home, ".agents") }, DestCodexSkillUser, "skills/a/SKILL.md"},
		{func(a *Applier) string { return filepath.Join(a.Home, ".codex") }, DestCodexSkillUser, "skills/a/SKILL.md"},
		{func(a *Applier) string { return filepath.Join(a.Home, ".codex") }, DestCodexAgentsMDUser, "AGENTS.md"},
	}
	for _, c := range cases {
		a := newApplier(t, d)
		dot := t.TempDir()
		require.NoError(t, os.Symlink(dot, c.top(a)))
		target := filepath.Join(dot, c.rel)
		writeFile(t, target, "Before.\n")
		skill := ""
		if c.dest != DestCodexAgentsMDUser {
			skill = "a"
		}
		id := propose(t, d, db.CoachProposal{Destination: c.dest, Skill: skill, BeforeText: "Before.\n",
			AfterText: "Before.\nAfter.\n", Kind: "replace", Fingerprint: c.dest + "|" + target})
		require.NoError(t, a.Accept(id, ""), c.rel)
		assert.Equal(t, "Before.\nAfter.\n", readFile(t, target), "written in the resolved folder")
		fi, err := os.Lstat(c.top(a))
		require.NoError(t, err)
		assert.NotZero(t, fi.Mode()&os.ModeSymlink, "the link itself is kept")
		_, err = a.Rollback(id, false)
		require.NoError(t, err)
		assert.Equal(t, "Before.\n", readFile(t, target))

		// The file itself as a link is refused under the resolved folder.
		require.NoError(t, os.Remove(target))
		other := filepath.Join(t.TempDir(), "x.md")
		writeFile(t, other, "Before.\n")
		require.NoError(t, os.Symlink(other, target))
		_, err = a.readCurrent(db.CoachProposal{Destination: c.dest, Skill: skill})
		require.ErrorIs(t, err, errUnsafeFile, c.rel)
	}

	// The Codex home as $CODEX_HOME may be a link too.
	a := newApplier(t, d)
	dot := t.TempDir()
	a.CodexHome = filepath.Join(t.TempDir(), "codex-link")
	require.NoError(t, os.Symlink(dot, a.CodexHome))
	id := propose(t, d, db.CoachProposal{Destination: DestCodexAgentsMDUser, AfterText: "Rule.\n", Fingerprint: "agents|ch"})
	require.NoError(t, a.Accept(id, ""))
	assert.Equal(t, "Rule.\n", readFile(t, filepath.Join(dot, "AGENTS.md")))

	// A top that is a link to a file, not a folder, is refused.
	a = newApplier(t, d)
	f := filepath.Join(t.TempDir(), "file")
	writeFile(t, f, "x")
	require.NoError(t, os.Symlink(f, filepath.Join(a.Home, ".claude")))
	_, err := a.readCurrent(db.CoachProposal{Destination: DestClaudeSkillUser, Skill: "a"})
	require.ErrorIs(t, err, errUnsafeFile)
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

func TestCodexSkillPath_OneCopyOnly(t *testing.T) {
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
	_, ok = CodexSkillPath(e, "x")
	assert.False(t, ok, "both: neither copy wins")

	require.NoError(t, os.Remove(legacy))
	got, ok = CodexSkillPath(e, "x")
	require.True(t, ok)
	assert.Equal(t, agents, got)

	// CODEX_HOME is honoured for the second folder.
	ch := t.TempDir()
	e = Env{Home: t.TempDir(), CodexHome: ch}
	writeFile(t, filepath.Join(ch, "skills", "x", "SKILL.md"), "C")
	got, ok = CodexSkillPath(e, "x")
	require.True(t, ok)
	assert.Equal(t, filepath.Join(ch, "skills", "x", "SKILL.md"), got)
	assert.Equal(t, filepath.Join(ch, "AGENTS.md"), codexAgentsMDPath(e))
	assert.Equal(t, filepath.Join(home, ".codex", "AGENTS.md"), codexAgentsMDPath(Env{Home: home}))
}

// A Codex skill in both folders is refused at propose (readCurrent), Accept and
// Rollback with the owner's sentence; neither file is touched (ask #1202).
func TestCodexSkill_TwoCopiesRefused(t *testing.T) {
	d := openDBs(t)
	const want = "Codex sees this skill in two folders (~/.agents/skills and ~/.codex/skills) — remove one copy first."
	a := newApplier(t, d)
	agents := filepath.Join(a.Home, ".agents", "skills", "a", "SKILL.md")
	legacy := filepath.Join(a.Home, ".codex", "skills", "a", "SKILL.md")
	writeFile(t, agents, "Before.\n")
	writeFile(t, legacy, "Before.\n")
	p := db.CoachProposal{Destination: DestCodexSkillUser, Skill: "a", BeforeText: "Before.\n", AfterText: "Before.\nAfter.\n"}

	_, err := a.readCurrent(p)
	require.ErrorIs(t, err, errCodexSkillTwice)
	assert.Equal(t, want, err.Error())

	id := propose(t, d, p)
	err = a.Accept(id, "")
	require.ErrorIs(t, err, errCodexSkillTwice)
	assert.Contains(t, err.Error(), want)
	assert.Equal(t, "open", proposal(t, d, id).Status)
	assert.Equal(t, "Before.\n", readFile(t, agents))
	assert.Equal(t, "Before.\n", readFile(t, legacy))

	// With $CODEX_HOME the sentence names the real folder.
	a.CodexHome = t.TempDir()
	writeFile(t, filepath.Join(a.CodexHome, "skills", "a", "SKILL.md"), "Before.\n")
	_, err = a.readCurrent(p)
	assert.Equal(t, "Codex sees this skill in two folders (~/.agents/skills and "+
		filepath.Join(a.CodexHome, "skills")+") — remove one copy first.", err.Error())

	// One copy: Accept works; a second copy appearing since refuses Rollback.
	b := newApplier(t, d)
	only := filepath.Join(b.Home, ".codex", "skills", "a", "SKILL.md")
	writeFile(t, only, "Before.\n")
	p.Fingerprint = "two|rollback"
	id = propose(t, d, p)
	require.NoError(t, b.Accept(id, ""))
	writeFile(t, filepath.Join(b.Home, ".agents", "skills", "a", "SKILL.md"), "Before.\nAfter.\n")
	_, err = b.Rollback(id, false)
	require.ErrorIs(t, err, errCodexSkillTwice)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
	assert.Equal(t, "Before.\nAfter.\n", readFile(t, only))
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
		p := f.proposal("Read the plan.\n", "Read the plan.\nRun package tests only.\n")
		p.Kind, p.Fingerprint = "replace", f.dest+"|rt"
		id := propose(t, d, p)
		require.NoError(t, a.Accept(id, ""), f.dest)
		assert.Equal(t, "Read the plan.\nRun package tests only.\n", readFile(t, path))
		fi, err := os.Stat(path)
		require.NoError(t, err)
		assert.Equal(t, os.FileMode(0o640), fi.Mode().Perm(), "mode kept")
		assert.Equal(t, "accepted", proposal(t, d, id).Status)

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

func TestWriteCut_CodexDestinationReadsCodexHome(t *testing.T) {
	d := openDBs(t)
	home, ch := t.TempDir(), t.TempDir()
	t.Setenv("CODEX_HOME", ch)
	writeFile(t, filepath.Join(ch, "AGENTS.md"), "Be brief.\nRun tests.\n")
	p := db.CoachProposal{ID: 1, Destination: DestCodexAgentsMDUser, BeforeText: "Be brief.\n",
		AfterText: "Be brief.\nRun tests.\n", Title: "t", Metric: "corrections"}
	wrote, err := writeCut(d.DB, d.al, home, p, applyNow)
	require.NoError(t, err)
	require.True(t, wrote, "the cut reads $CODEX_HOME/AGENTS.md, not <home>/.codex")
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.NotContains(t, open[0].AfterText, "Run tests.")
	assert.Contains(t, open[0].AfterText, "Be brief.")
}
