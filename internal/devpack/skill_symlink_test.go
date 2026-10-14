package devpack

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// treeSnapshot maps every path under root to its content ("<dir>" for a
// directory), so a test can tell nothing under root changed.
func treeSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	require.NoError(t, filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if d.IsDir() {
			out[rel] = "<dir>"
			return nil
		}
		b, err := os.ReadFile(p)
		out[rel] = string(b)
		return err
	}))
	return out
}

// seedOutsideSkill lays our current workbench skill out under dir (as a
// skills directory), so a removal through a link would take it.
func seedOutsideSkill(t *testing.T, dir string) {
	t.Helper()
	_, err := installSkill(dir, workbenchSkill())
	require.NoError(t, err)
}

// A .claude, .claude/skills or .agents/skills directory that is a symlink
// leaving the folder is refused by install and removal before the skill step
// writes or removes anything through it (PROJ-04, ask #109, target 156).
func TestProj04_SkillDirectoryLinkOutsideTheFolderIsRefused(t *testing.T) {
	cases := map[string]struct {
		link   string // the folder-relative path made a link
		skills string // the skills dir under the link's target
		codex  bool
	}{
		".claude":        {link: ".claude", skills: "skills"},
		".claude/skills": {link: filepath.Join(".claude", "skills"), skills: "."},
		".agents/skills": {link: filepath.Join(".agents", "skills"), skills: ".", codex: true},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			folder := fakeRepo(t)
			outside := t.TempDir()
			seedOutsideSkill(t, filepath.Join(outside, tc.skills))
			linkPath := filepath.Join(folder, tc.link)
			require.NoError(t, os.MkdirAll(filepath.Dir(linkPath), 0o755))
			require.NoError(t, os.Symlink(outside, linkPath))
			before := treeSnapshot(t, outside)

			if tc.codex {
				_, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound)
				require.ErrorIs(t, err, ErrSymlinkOutsideFolder)
				_, err = RemoveCodex(context.Background(), codexOpts(folder))
				require.ErrorIs(t, err, ErrSymlinkOutsideFolder)
			} else {
				f := newFakeClaude()
				_, err := InstallWorkbench(context.Background(), workbenchOpts(folder, f))
				require.ErrorIs(t, err, ErrSymlinkOutsideFolder)
				require.ErrorIs(t, RemoveWorkbench(context.Background(), workbenchOpts(folder, f)), ErrSymlinkOutsideFolder)
			}
			assert.Equal(t, before, treeSnapshot(t, outside), "nothing outside the folder is written or removed")
			got, err := os.Readlink(linkPath)
			require.NoError(t, err)
			assert.Equal(t, outside, got, "the link is untouched")
		})
	}
}

// A skills directory linked inside the folder is still written through and
// removed from.
func TestProj04_SkillDirectoryLinkInsideTheFolderIsFollowed(t *testing.T) {
	folder := fakeRepo(t)
	inside := filepath.Join(folder, "dotfiles", "skills")
	require.NoError(t, os.MkdirAll(inside, 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".claude"), 0o755))
	require.NoError(t, os.Symlink(inside, filepath.Join(folder, ".claude", "skills")))
	f := newFakeClaude()

	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, f))
	require.NoError(t, err)
	assert.Equal(t, StateInstalled, rep.Skill.State)
	assert.FileExists(t, filepath.Join(inside, WorkbenchSkillName, "SKILL.md"))

	require.NoError(t, RemoveWorkbench(context.Background(), workbenchOpts(folder, f)))
	assert.NoFileExists(t, filepath.Join(inside, WorkbenchSkillName, "SKILL.md"))

	agents := filepath.Join(folder, "dotfiles", "agents")
	require.NoError(t, os.MkdirAll(agents, 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".agents"), 0o755))
	require.NoError(t, os.Symlink(agents, filepath.Join(folder, ".agents", "skills")))
	st, err := InstallCodex(context.Background(), codexOpts(folder), codexNotFound)
	require.NoError(t, err)
	assert.True(t, st.Skill)
	assert.FileExists(t, filepath.Join(agents, WorkbenchSkillName, "SKILL.md"))
}

// A removal refused through a link names what it left outside and what to
// remove by hand (ask #118); a path that does not exist outside is no hint.
func TestOutsideFolderHints_NameTheLeftovers(t *testing.T) {
	folder := fakeRepo(t)
	outside := t.TempDir()
	seedOutsideSkill(t, outside)
	require.NoError(t, os.MkdirAll(filepath.Join(folder, ".claude"), 0o755))
	require.NoError(t, os.Symlink(outside, filepath.Join(folder, ".claude", "skills")))
	err := RemoveWorkbench(context.Background(), workbenchOpts(folder, newFakeClaude()))
	require.ErrorIs(t, err, ErrSymlinkOutsideFolder)
	realOutside, evalErr := filepath.EvalSymlinks(outside)
	require.NoError(t, evalErr)
	assert.Equal(t, []string{"Watchtower's skill stays in " + filepath.Join(realOutside, WorkbenchSkillName) + " — remove it by hand"},
		OutsideFolderHints(err))

	gone := &OutsideFolderError{Outside: filepath.Join(outside, "missing.json"), leftover: leftoverHooks}
	assert.Empty(t, OutsideFolderHints(gone))
}
