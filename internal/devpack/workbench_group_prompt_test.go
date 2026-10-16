package devpack

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Board #476: whether a skill knows the group first prompt is read off its
// content. v1..v3 predate the group rules (2026-10-08), v4..v9 and the
// shipped core name the prompt; an owner's copy counts for what it says.
func TestSkillKnowsGroupPrompt_ReadsTheContent(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		require.NoError(t, os.WriteFile(p, []byte(content), 0o600))
		return p
	}
	for v, want := range map[string]bool{"v1": false, "v2": false, "v3": false, "v4": true, "v5": true, "v6": true, "v7": true, "v8": true, "v9": true} {
		assert.Equal(t, want, skillKnowsGroupPrompt(filepath.Join("testdata", "watchtower-workbench-"+v+".md")), v)
	}
	// The Swift twin: TerminalLaunch.workOnGroupPrompt starts with this
	// (TerminalLaunchTests testPromptsNameTheFoldersSkill) — change both.
	assert.Equal(t, "Work on group #", groupPromptMarker)
	_, shipped := WorkbenchSkill()
	assert.True(t, skillKnowsGroupPrompt(write("shipped.md", string(shipped))), "the shipped core skill")

	cut := strings.ReplaceAll(string(shipped), groupPromptMarker, "Work on #")
	assert.False(t, skillKnowsGroupPrompt(write("cut.md", cut)), "an owner's copy without the group prompt")
	v3, err := os.ReadFile(filepath.Join("testdata", "watchtower-workbench-v3.md"))
	require.NoError(t, err)
	added := string(v3) + "\nThe first prompt `Work on group #<id>` hands you a group: work its leaves.\n"
	assert.True(t, skillKnowsGroupPrompt(write("added.md", added)), "an owner's v3 copy that added group rules")

	assert.False(t, skillKnowsGroupPrompt(filepath.Join(dir, "missing.md")))
	assert.False(t, skillKnowsGroupPrompt(dir), "a directory is no skill")
}

// The Claude Code part reports the skill the session reads: the current one,
// else the old one while it is all there is (spec 2026-10-02 §5.3).
func TestStatusWorkbench_GroupPromptFollowsTheSkillTheSessionReads(t *testing.T) {
	ctx := context.Background()

	t.Run("nothing installed", func(t *testing.T) {
		st, err := StatusWorkbench(ctx, workbenchOpts(fakeRepo(t), newFakeClaude()))
		require.NoError(t, err)
		assert.False(t, st.GroupPrompt)
	})
	t.Run("current skill", func(t *testing.T) {
		folder := fakeRepo(t)
		o := workbenchOpts(folder, newFakeClaude())
		_, err := InstallWorkbench(ctx, o)
		require.NoError(t, err)
		st, err := StatusWorkbench(ctx, o)
		require.NoError(t, err)
		assert.True(t, st.GroupPrompt)

		// An outdated v3 copy awaiting Repair: only a banner, so the
		// session still reads v3.
		v3, err := os.ReadFile(filepath.Join("testdata", "watchtower-workbench-v3.md"))
		require.NoError(t, err)
		writeTestFile(t, workbenchSkillFile(folder), string(v3))
		st, err = StatusWorkbench(ctx, o)
		require.NoError(t, err)
		assert.False(t, st.GroupPrompt)
	})
	t.Run("legacy folder", func(t *testing.T) {
		folder := fakeRepo(t)
		f := newFakeClaude()
		seedLegacyFolder(t, folder, f, legacySkillContent, true, legacyOwnerSettings)
		st, err := StatusWorkbench(ctx, legacyOpts(folder, f))
		require.NoError(t, err)
		require.Equal(t, StateMissing, st.Skill.State)
		assert.False(t, st.GroupPrompt, "the old skill has no group rules")

		seedLegacyFolder(t, folder, f, legacySkillContent+"\n`Work on group #<id>`: work its leaves.\n", false, legacyOwnerSettings)
		st, err = StatusWorkbench(ctx, legacyOpts(folder, f))
		require.NoError(t, err)
		assert.True(t, st.GroupPrompt, "an owner's old copy that names the group prompt")

		// Once the current skill is in, it is what the session reads, even
		// beside an old copy that names the prompt.
		_, shipped := WorkbenchSkill()
		writeTestFile(t, workbenchSkillFile(folder), strings.ReplaceAll(string(shipped), groupPromptMarker, "Work on #"))
		st, err = StatusWorkbench(ctx, legacyOpts(folder, f))
		require.NoError(t, err)
		require.NotEqual(t, StateMissing, st.Skill.State)
		assert.False(t, st.GroupPrompt, "the current copy without the group prompt wins over the old one")
	})
	t.Run("an old copy alone, nothing else legacy", func(t *testing.T) {
		// Not a legacy folder, so the Desktop names the current skill (Swift
		// WorkbenchInstallStatus.vocabulary): the old copy is not asked.
		folder := fakeRepo(t)
		f := newFakeClaude()
		writeTestFile(t, filepath.Join(legacySkillDir(folder), "SKILL.md"), legacySkillContent+"\n`Work on group #<id>`\n")
		st, err := StatusWorkbench(ctx, legacyOpts(folder, f))
		require.NoError(t, err)
		require.False(t, st.Legacy)
		require.NotEqual(t, StateMissing, st.LegacySkill.State)
		assert.False(t, st.GroupPrompt)
	})
}

func TestStatusCodex_GroupPromptReadsTheCodexCopy(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeAppServer(t)
	_, err := InstallCodex(context.Background(), codexOpts(folder), f.factory())
	require.NoError(t, err)
	v3, err := os.ReadFile(filepath.Join("testdata", "watchtower-workbench-v3.md"))
	require.NoError(t, err)
	writeTestFile(t, codexSkillFile(folder), string(v3))
	st, err := StatusCodex(context.Background(), codexOpts(folder), codexResolves, f.factory())
	require.NoError(t, err)
	assert.True(t, st.Skill)
	assert.False(t, st.GroupPrompt)
}
