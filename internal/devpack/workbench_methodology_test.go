package devpack

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func flowSkillFile(folder string) string {
	return filepath.Join(folder, ".claude", "skills", FlowSkillName, "SKILL.md")
}

func codexFlowSkillFile(folder string) string {
	return filepath.Join(folder, ".agents", "skills", FlowSkillName, "SKILL.md")
}

func TestInstallWorkbench_WritesTheCoreAndThePreset(t *testing.T) {
	folder := fakeRepo(t)
	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, newFakeClaude()))
	require.NoError(t, err)
	assert.Equal(t, StateInstalled, rep.Skill.State)
	assert.Equal(t, StateInstalled, rep.Flow.State)
	assert.False(t, rep.SingleFileLayout)
	assert.Equal(t, flowSkill().Content, readTestFile(t, flowSkillFile(folder)))
	assert.Contains(t, excludeOf(t, folder), ".claude/skills/"+FlowSkillName+"/")
}

// PROJ-04 (spec §4.3): preset none removes the preset only when its bytes
// are ours; an edited or foreign copy stays byte-identical and is reported.
func TestProj04_PresetNoneRemovesOnlyOurFlow(t *testing.T) {
	ctx := context.Background()
	none := func(folder string, f *fakeClaude) WorkbenchInstallOptions {
		o := workbenchOpts(folder, f)
		o.PresetNone = true
		return o
	}
	t.Run("ours is removed", func(t *testing.T) {
		folder, f := fakeRepo(t), newFakeClaude()
		_, err := InstallWorkbench(ctx, workbenchOpts(folder, f))
		require.NoError(t, err)
		rep, err := InstallWorkbench(ctx, none(folder, f))
		require.NoError(t, err)
		assert.Equal(t, StateRemoved, rep.Flow.State)
		assert.False(t, exists(filepath.Dir(flowSkillFile(folder))))
		assert.Equal(t, workbenchSkill().Content, readTestFile(t, workbenchSkillFile(folder)), "the core stays")
	})
	t.Run("an edited copy is kept", func(t *testing.T) {
		folder, f := fakeRepo(t), newFakeClaude()
		_, err := InstallWorkbench(ctx, workbenchOpts(folder, f))
		require.NoError(t, err)
		edited := flowSkill().Content + "\nOur own review rule.\n"
		writeTestFile(t, flowSkillFile(folder), edited)
		rep, err := InstallWorkbench(ctx, none(folder, f))
		require.NoError(t, err)
		assert.Equal(t, StateDrifted, rep.Flow.State)
		assert.Equal(t, edited, readTestFile(t, flowSkillFile(folder)))
	})
	t.Run("a foreign file is never touched", func(t *testing.T) {
		folder := fakeRepo(t)
		foreign := "---\nname: watchtower-flow\ndescription: mine\n---\nMy flow.\n"
		writeTestFile(t, flowSkillFile(folder), foreign)
		rep, err := InstallWorkbench(ctx, none(folder, newFakeClaude()))
		require.NoError(t, err)
		assert.Equal(t, StateForeign, rep.Flow.State)
		assert.Equal(t, foreign, readTestFile(t, flowSkillFile(folder)))
	})
}

// PROJ-04 (spec §4.3): an owner-edited v8 single file is kept as it is and
// gets no preset beside it — it carries its own copy of the methodology.
func TestProj04_DriftedV8KeepsSingleFileNoFlow(t *testing.T) {
	ctx := context.Background()
	edited := v8Skill(t) + "\nMy own note.\n"
	t.Run("claude", func(t *testing.T) {
		folder := fakeRepo(t)
		writeTestFile(t, workbenchSkillFile(folder), edited)
		require.NoError(t, writeShippedDigest(filepath.Dir(workbenchSkillFile(folder)), v8CoreSHA256))
		rep, err := InstallWorkbench(ctx, workbenchOpts(folder, newFakeClaude()))
		require.NoError(t, err)
		assert.Equal(t, StateDrifted, rep.Skill.State)
		assert.True(t, rep.SingleFileLayout)
		assert.Equal(t, edited, readTestFile(t, workbenchSkillFile(folder)))
		assert.False(t, exists(filepath.Dir(flowSkillFile(folder))), "no preset beside a single-file skill")
	})
	t.Run("codex", func(t *testing.T) {
		folder := fakeRepo(t)
		writeTestFile(t, codexSkillFile(folder), edited)
		st, err := InstallCodex(ctx, codexOpts(folder), codexNotFound)
		require.NoError(t, err)
		assert.Equal(t, StateDrifted, st.SkillState)
		assert.True(t, st.SingleFileLayout)
		assert.Equal(t, edited, readTestFile(t, codexSkillFile(folder)))
		assert.False(t, exists(filepath.Dir(codexFlowSkillFile(folder))))
	})
}

// An owner-edited v9 core carries no methodology, so the preset still goes
// in beside it.
func TestInstallWorkbench_AnEditedV9CoreStillGetsThePreset(t *testing.T) {
	folder := fakeRepo(t)
	writeTestFile(t, workbenchSkillFile(folder), workbenchSkill().Content+"\nMy note.\n")
	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, newFakeClaude()))
	require.NoError(t, err)
	assert.Equal(t, StateDrifted, rep.Skill.State)
	assert.False(t, rep.SingleFileLayout)
	assert.Equal(t, StateInstalled, rep.Flow.State)
}

func TestV8CoreDigestIsTheShippedFixture(t *testing.T) {
	sum := sha256.Sum256([]byte(v8Skill(t)))
	assert.Equal(t, v8CoreSHA256, hex.EncodeToString(sum[:]))
}

// Spec §4.3: the shipped v8 bytes count as ours even without the sidecar.
func TestInstallWorkbench_AdoptsTheShippedV8WithoutASidecar(t *testing.T) {
	folder := fakeRepo(t)
	writeTestFile(t, workbenchSkillFile(folder), v8Skill(t))
	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, newFakeClaude()))
	require.NoError(t, err)
	assert.Equal(t, StateUpdated, rep.Skill.State)
	assert.Equal(t, StateInstalled, rep.Flow.State)
	assert.Equal(t, workbenchSkill().Content, readTestFile(t, workbenchSkillFile(folder)))
}

// PROJ-02 (spec §9): a removal takes our preset out of both skill
// directories, with its exclude line; an edited one stays with its line.
func TestProj02_RemoveTakesOurPresetAndKeepsAnEditedOne(t *testing.T) {
	ctx := context.Background()
	install := func(t *testing.T) (string, WorkbenchInstallOptions) {
		folder := fakeRepo(t)
		o := workbenchOpts(folder, newFakeClaude())
		_, err := InstallWorkbench(ctx, o)
		require.NoError(t, err)
		_, err = InstallCodex(ctx, codexOpts(folder), codexNotFound)
		require.NoError(t, err)
		return folder, o
	}
	folder, o := install(t)
	require.NoError(t, RemoveWorkbench(ctx, o))
	_, err := RemoveCodex(ctx, codexOpts(folder))
	require.NoError(t, err)
	assert.False(t, exists(filepath.Dir(flowSkillFile(folder))))
	assert.False(t, exists(filepath.Dir(codexFlowSkillFile(folder))))
	assert.NotContains(t, excludeOf(t, folder), FlowSkillName)

	folder, o = install(t)
	edited := flowSkill().Content + "\nOurs now.\n"
	writeTestFile(t, flowSkillFile(folder), edited)
	require.NoError(t, RemoveWorkbench(ctx, o))
	assert.Equal(t, edited, readTestFile(t, flowSkillFile(folder)))
	assert.Contains(t, excludeOf(t, folder), ".claude/skills/"+FlowSkillName+"/")
}

func TestSyncMethodology_FollowsThePresetInBothSkillDirs(t *testing.T) {
	ctx := context.Background()
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	_, err := InstallWorkbench(ctx, o)
	require.NoError(t, err)
	_, err = InstallCodex(ctx, codexOpts(folder), codexNotFound)
	require.NoError(t, err)

	o.PresetNone = true
	rep, err := SyncMethodology(o)
	require.NoError(t, err)
	assert.Equal(t, StateRemoved, rep.Claude.State)
	assert.Equal(t, StateRemoved, rep.Codex.State)
	assert.Equal(t, MethodologyLayout{Core: true}, FolderMethodologyLayout(folder))

	o.PresetNone = false
	rep, err = SyncMethodology(o)
	require.NoError(t, err)
	assert.Equal(t, StateInstalled, rep.Claude.State)
	assert.Equal(t, StateInstalled, rep.Codex.State)
	assert.Equal(t, MethodologyLayout{Core: true, Flow: true, FlowPresent: true}, FolderMethodologyLayout(folder))
}

// An owner-edited preset is present but not ours (the brief's mismatch check).
func TestFolderMethodologyLayout_SeesAnEditedPreset(t *testing.T) {
	ctx := context.Background()
	folder := fakeRepo(t)
	_, err := InstallWorkbench(ctx, workbenchOpts(folder, newFakeClaude()))
	require.NoError(t, err)
	_, body := FlowSkill()
	writeTestFile(t, flowSkillFile(folder), string(body)+"\nMy own step.\n")
	assert.Equal(t, MethodologyLayout{Core: true, FlowPresent: true}, FolderMethodologyLayout(folder))
}

// A folder without the core skill (never set up) is left alone.
func TestSyncMethodology_LeavesAFolderWithoutTheCoreAlone(t *testing.T) {
	folder := fakeRepo(t)
	rep, err := SyncMethodology(workbenchOpts(folder, newFakeClaude()))
	require.NoError(t, err)
	assert.Equal(t, MethodologyReport{}, rep)
	assert.False(t, exists(filepath.Join(folder, ".claude")))
	assert.Equal(t, MethodologyLayout{}, FolderMethodologyLayout(folder))
}

func TestFolderMethodologyLayout_SeesASingleFileCore(t *testing.T) {
	folder := fakeRepo(t)
	writeTestFile(t, workbenchSkillFile(folder), v8Skill(t)+"\nedited\n")
	assert.Equal(t, MethodologyLayout{Core: true, SingleFile: true}, FolderMethodologyLayout(folder))
}

// Spec §4.3: a preset change upgrades a pre-v9 core of ours to the split
// layout before it syncs the preset (with none, the v8 single file would
// still carry the whole methodology); an owner-edited core stays as it is
// (PROJ-04).
func TestSyncMethodology_UpgradesAPreV9CoreOfOurs(t *testing.T) {
	for _, tc := range []struct {
		name    string
		sidecar bool
	}{{"with the sidecar", true}, {"the shipped bytes without it", false}} {
		t.Run(tc.name, func(t *testing.T) {
			folder := fakeRepo(t)
			writeTestFile(t, workbenchSkillFile(folder), v8Skill(t))
			writeTestFile(t, codexSkillFile(folder), v8Skill(t))
			if tc.sidecar {
				require.NoError(t, writeShippedDigest(filepath.Dir(workbenchSkillFile(folder)), v8CoreSHA256))
				require.NoError(t, writeShippedDigest(filepath.Dir(codexSkillFile(folder)), v8CoreSHA256))
			}
			o := workbenchOpts(folder, newFakeClaude())
			o.PresetNone = true

			rep, err := SyncMethodology(o)

			require.NoError(t, err)
			assert.Equal(t, workbenchSkill().Content, readTestFile(t, workbenchSkillFile(folder)))
			assert.Equal(t, workbenchSkill().Content, readTestFile(t, codexSkillFile(folder)))
			assert.Equal(t, StateMissing, rep.Claude.State)
			assert.False(t, rep.SingleFileLayout)
			assert.Equal(t, MethodologyLayout{Core: true}, FolderMethodologyLayout(folder))
		})
	}
	t.Run("an edited v8 is left alone", func(t *testing.T) {
		folder := fakeRepo(t)
		edited := v8Skill(t) + "\nMy own note.\n"
		writeTestFile(t, workbenchSkillFile(folder), edited)
		require.NoError(t, writeShippedDigest(filepath.Dir(workbenchSkillFile(folder)), v8CoreSHA256))
		o := workbenchOpts(folder, newFakeClaude())

		rep, err := SyncMethodology(o)

		require.NoError(t, err)
		assert.Equal(t, edited, readTestFile(t, workbenchSkillFile(folder)))
		assert.True(t, rep.SingleFileLayout)
		assert.False(t, exists(filepath.Dir(flowSkillFile(folder))))
	})
}
