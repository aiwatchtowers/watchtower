package dayplan

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/memory"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// loopsCfg returns a day-plan config whose WorkspaceDir lands under a temp HOME,
// with the memory.surfaces.day_plan gate defaulted to the caller's choice.
func loopsCfg(t *testing.T, gateOn bool) *config.Config {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	c := pipeTestCfg()
	c.ActiveWorkspace = "default"
	c.Memory.Surfaces.DayPlan = gateOn
	return c
}

// vaultPathFor is <WorkspaceDir>/memory.
func vaultPathFor(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "memory")
}

// initLoopsVault initializes an empty memory vault at <WorkspaceDir>/memory.
func initLoopsVault(t *testing.T, cfg *config.Config) string {
	t.Helper()
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	vaultPath := vaultPathFor(cfg)
	_, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)
	return vaultPath
}

// writeEntityWithLoops writes an ACTIVE entity node carrying an "## Open loops"
// section and mirrors it into the SQLite index so ListMemoryNodes returns it.
func writeEntityWithLoops(t *testing.T, database *db.DB, vaultPath, id, title string, loops []string) {
	t.Helper()
	var b strings.Builder
	b.WriteString("# " + title + "\n\n## What\n" + title + "\n\n## Current\n\n## Facts\n\n## Links\n\n## Open loops\n")
	for _, l := range loops {
		b.WriteString("- " + l + "\n")
	}
	body := b.String()
	n := memory.Node{
		ID:     id,
		Type:   "entity",
		Tier:   "long",
		Status: "active",
		Title:  title,
		Body:   body,
	}
	rel := filepath.Join(vaultPath, "entities", id+".md")
	require.NoError(t, os.WriteFile(rel, n.Render(), 0o644))
	require.NoError(t, database.UpsertMemoryNode(db.MemoryNodeRow{
		ID:          id,
		Type:        "entity",
		Tier:        "long",
		Status:      "active",
		Title:       title,
		Path:        "entities/" + id + ".md",
		ContentHash: "h-" + id,
		IndexedAt:   "2026-07-16T00:00:00Z",
	}, body, nil))
}

// gitHeadCount returns the number of commits reachable from HEAD in the vault.
func gitHeadCount(t *testing.T, vaultPath string) string {
	t.Helper()
	cmd := exec.Command("git", "-C", vaultPath, "rev-list", "--count", "HEAD")
	out, err := cmd.Output()
	require.NoError(t, err)
	return strings.TrimSpace(string(out))
}

func TestGatherMemoryOpenLoops_GateOffReturnsSentinel(t *testing.T) {
	cfg := loopsCfg(t, false)
	vaultPath := initLoopsVault(t, cfg)
	d := gatherTestDB(t)
	writeEntityWithLoops(t, d, vaultPath, "ent_a", "Ship the release", []string{"cut the RC branch"})

	p := &Pipeline{db: d, cfg: cfg}
	assert.Equal(t, "(no memory open loops)", p.gatherMemoryOpenLoops())
}

func TestGatherMemoryOpenLoops_GateOnListsLoops(t *testing.T) {
	cfg := loopsCfg(t, true)
	vaultPath := initLoopsVault(t, cfg)
	d := gatherTestDB(t)
	writeEntityWithLoops(t, d, vaultPath, "ent_ship", "Ship the release", []string{"cut the RC branch", "ball on Bob, due 2026-07-20"})

	p := &Pipeline{db: d, cfg: cfg}
	got := p.gatherMemoryOpenLoops()

	assert.Contains(t, got, "Ship the release: cut the RC branch")
	assert.Contains(t, got, "Ship the release: ball on Bob, due 2026-07-20")
	assert.NotEqual(t, "(no memory open loops)", got)
}

func TestGatherMemoryOpenLoops_CapsAtTen(t *testing.T) {
	cfg := loopsCfg(t, true)
	vaultPath := initLoopsVault(t, cfg)
	d := gatherTestDB(t)
	loops := make([]string, 0, 15)
	for i := 0; i < 15; i++ {
		loops = append(loops, "loop item")
	}
	writeEntityWithLoops(t, d, vaultPath, "ent_big", "Big entity", loops)

	p := &Pipeline{db: d, cfg: cfg}
	got := p.gatherMemoryOpenLoops()

	lines := strings.Split(got, "\n")
	assert.LessOrEqual(t, len(lines), 10, "open-loops block must be capped at ~10 lines")
}

func TestGatherMemoryOpenLoops_VaultAbsentReturnsSentinelNoError(t *testing.T) {
	cfg := loopsCfg(t, true) // gate on, but no vault initialized
	d := gatherTestDB(t)

	p := &Pipeline{db: d, cfg: cfg}
	assert.Equal(t, "(no memory open loops)", p.gatherMemoryOpenLoops())
}

func TestGatherMemoryOpenLoops_NeverCreatesVault(t *testing.T) {
	cfg := loopsCfg(t, true) // gate on, no vault
	d := gatherTestDB(t)

	p := &Pipeline{db: d, cfg: cfg}
	_ = p.gatherMemoryOpenLoops()

	_, err := os.Stat(vaultPathFor(cfg))
	assert.True(t, os.IsNotExist(err), "gather must never create a vault")
}

func TestGatherMemoryOpenLoops_LeavesVaultGitLogUnchanged(t *testing.T) {
	cfg := loopsCfg(t, true)
	vaultPath := initLoopsVault(t, cfg)
	d := gatherTestDB(t)
	writeEntityWithLoops(t, d, vaultPath, "ent_x", "Entity X", []string{"do the thing"})

	before := gitHeadCount(t, vaultPath)
	p := &Pipeline{db: d, cfg: cfg}
	_ = p.gatherMemoryOpenLoops()
	after := gitHeadCount(t, vaultPath)

	assert.Equal(t, before, after, "gather must not create a git commit")
}

// TestBuildPrompt_GateOffMatchesSentinelSection asserts that with the gate off,
// the rendered prompt carries the sentinel-bearing MEMORY OPEN LOOPS section and
// contains no Sprintf arg-count artifacts.
func TestBuildPrompt_GateOffMatchesSentinelSection(t *testing.T) {
	p := newPromptPipeline("English")
	in := minimalInputs()
	in.MemoryOpenLoops = "(no memory open loops)"

	got, _ := p.buildPrompt(in)

	assert.Contains(t, got, "MEMORY OPEN LOOPS")
	assert.Contains(t, got, "(no memory open loops)")
	assert.NotContains(t, got, "%!", "no Sprintf arg-count artifacts")
	assert.NotContains(t, got, "MISSING")
}

// TestBuildPrompt_MemoryOpenLoopsRendered asserts the loops block reaches the
// rendered prompt when populated.
func TestBuildPrompt_MemoryOpenLoopsRendered(t *testing.T) {
	p := newPromptPipeline("English")
	in := minimalInputs()
	in.MemoryOpenLoops = "- Ship the release: cut the RC branch"

	got, _ := p.buildPrompt(in)

	assert.Contains(t, got, "- Ship the release: cut the RC branch")
	assert.NotContains(t, got, "%!")
}

func TestDayPlanGenerateVersionBumpedToThree(t *testing.T) {
	assert.Equal(t, 3, prompts.DefaultVersions[prompts.DayPlanGenerate])
}
