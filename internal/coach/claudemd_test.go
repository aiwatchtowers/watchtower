package coach

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func writeMD(t *testing.T, home, text string) string {
	t.Helper()
	p := claudeMDPath(home)
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o700))
	require.NoError(t, os.WriteFile(p, []byte(text), 0o640))
	return p
}

func TestClaudeMD_AppendAndRollback(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	p := writeMD(t, a.Home, "Be brief.\n")
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, BeforeText: "Be brief.\n",
		AfterText: "Be brief.\nRun package tests only.\n"})
	require.NoError(t, a.Accept(id, ""))
	raw, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Equal(t, "Be brief.\nRun package tests only.\n", string(raw))
	fi, err := os.Stat(p)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o640), fi.Mode().Perm(), "mode kept")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	// The owner edits it by hand: rollback shows the diff and writes nothing.
	require.NoError(t, os.WriteFile(p, []byte("Be brief.\nRun package tests only.\nMine.\n"), 0o640))
	diff, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Contains(t, diff, "+Mine.")
	assert.NotContains(t, err.Error(), a.Home)
	raw, _ = os.ReadFile(p)
	assert.Contains(t, string(raw), "Mine.")

	_, err = a.Rollback(id, true)
	require.NoError(t, err)
	raw, _ = os.ReadFile(p)
	assert.Equal(t, "Be brief.\n", string(raw))
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestClaudeMD_CreatesMissingFileAndFolder(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, AfterText: "Rule.\n"})
	require.NoError(t, a.Accept(id, ""))
	p := claudeMDPath(a.Home)
	raw, err := os.ReadFile(p)
	require.NoError(t, err)
	assert.Equal(t, "Rule.\n", string(raw))
	fi, _ := os.Stat(p)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	di, _ := os.Stat(filepath.Dir(p))
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())

	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	raw, _ = os.ReadFile(p)
	assert.Empty(t, raw)
}

func TestClaudeMD_RefusesSymlink(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	target := filepath.Join(t.TempDir(), "elsewhere.md")
	require.NoError(t, os.WriteFile(target, []byte("X"), 0o600))
	require.NoError(t, os.MkdirAll(filepath.Join(a.Home, ".claude"), 0o700))
	require.NoError(t, os.Symlink(target, claudeMDPath(a.Home)))

	id := propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, BeforeText: "X", AfterText: "XY"})
	err := a.Accept(id, "")
	require.ErrorIs(t, err, errClaudeMDNotRegular)
	assert.NotContains(t, err.Error(), a.Home)
	raw, _ := os.ReadFile(target)
	assert.Equal(t, "X", string(raw))
	assert.Equal(t, "open", proposal(t, d, id).Status)

	// The proposer is not shown it either.
	home := fakeHome(t)
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.Symlink(target, claudeMDPath(home)))
	_, ok := readClaudeMDText()
	assert.False(t, ok)
}

func TestClaudeMD_StaleRefused(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	p := writeMD(t, a.Home, "Changed by hand.\n")
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, BeforeText: "Old.\n", AfterText: "Old.\nNew.\n"})
	require.ErrorIs(t, a.Accept(id, ""), ErrStale)
	assert.Equal(t, "superseded", proposal(t, d, id).Status)
	raw, _ := os.ReadFile(p)
	assert.Equal(t, "Changed by hand.\n", string(raw))
}

func TestClaudeMD_ChangedBeforeRenameRefused(t *testing.T) {
	home := t.TempDir()
	p := writeMD(t, home, "A")
	_, err := replaceClaudeMD(p, "B", "C")
	require.ErrorIs(t, err, errClaudeMDChanged)
	// The writer itself re-reads just before the rename.
	raw, mode, exists, err := readClaudeMDFile(p)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(p, []byte("A2"), 0o640))
	require.ErrorIs(t, writeAtomic(claudeMDKind, p, []byte("C"), mode, raw, exists), errClaudeMDChanged)
	got, _ := os.ReadFile(p)
	assert.Equal(t, "A2", string(got))
	ents, _ := os.ReadDir(filepath.Dir(p))
	assert.Len(t, ents, 1, "no temp file left")
}

func TestClaudeMD_OversizeAndSpecialNotRead(t *testing.T) {
	home := t.TempDir()
	p := writeMD(t, home, strings.Repeat("a", claudeMDMaxBytes+1))
	_, err := readClaudeMD(p)
	require.ErrorIs(t, err, errClaudeMDTooBig)
	require.NoError(t, os.Remove(p))
	require.NoError(t, os.Mkdir(p, 0o700))
	_, err = readClaudeMD(p)
	require.ErrorIs(t, err, errClaudeMDNotRegular)
}

func TestValidate_ClaudeMDGrowthCap(t *testing.T) {
	home := fakeHome(t)
	writeMD(t, home, "Short.\n")
	d := openDBs(t)
	in, err := Collect(context.Background(), d.DB, nil, noFeed, sigNow)
	require.NoError(t, err)
	var md CurrentText
	for _, x := range in.Texts {
		if x.Destination == DestClaudeMDUser {
			md = x
		}
	}
	require.Equal(t, "Short.\n", md.Text)
	assert.Equal(t, len("Short.\n")+claudeMDGrowth, md.Budget)

	fits := strings.Repeat("a", claudeMDGrowth-1)
	over := strings.Repeat("a", claudeMDGrowth+10)
	assert.NoError(t, ValidateAfter(md, md.Text+fits))
	assert.Error(t, ValidateAfter(md, md.Text+over))

	in = proposeInputs()
	in.Texts = append(in.Texts, md)
	reply := func(replace string) string {
		return `{"proposals":[{"title":"t","why":"w","destination":"claude_md_user","kind":"add","find":"","replace":"` +
			replace + `","metric":"corrections","evidence":["s1","s2","s3"]}]}`
	}
	got, err := Validate(reply(fits), in)
	require.NoError(t, err)
	assert.Len(t, got, 1)
	got, err = Validate(reply(over), in)
	require.NoError(t, err)
	assert.Empty(t, got)

	// No text in Inputs (symlink, oversize): the destination is unavailable.
	in = proposeInputs()
	got, err = Validate(reply("x"), in)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestCollect_ClaudeMDMissingIsEmptyText(t *testing.T) {
	fakeHome(t)
	d := openDBs(t)
	in, err := Collect(context.Background(), d.DB, nil, noFeed, sigNow)
	require.NoError(t, err)
	found := false
	for _, x := range in.Texts {
		if x.Destination == DestClaudeMDUser {
			found = true
			assert.Empty(t, x.Text)
			assert.Equal(t, claudeMDGrowth, x.Budget)
		}
	}
	assert.True(t, found)
}

func TestWriteCut_UnreadableClaudeMDFilesNoCut(t *testing.T) {
	d := openDBs(t)
	home := t.TempDir()
	p := db.CoachProposal{ID: 1, Destination: DestClaudeMDUser, BeforeText: "", AfterText: "Rule.", Title: "t", Metric: "corrections"}
	md := writeMD(t, home, strings.Repeat("a", claudeMDMaxBytes+1))
	wrote, err := writeCut(d.DB, d.al, home, p, applyNow)
	require.NoError(t, err)
	assert.False(t, wrote, "oversize")
	require.NoError(t, os.Remove(md))
	require.NoError(t, os.Symlink(filepath.Join(home, "x"), md))
	wrote, err = writeCut(d.DB, d.al, home, p, applyNow)
	require.NoError(t, err)
	assert.False(t, wrote, "symlink")
}
