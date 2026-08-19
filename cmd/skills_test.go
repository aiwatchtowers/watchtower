package cmd

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/skills"
)

// deployHarness points cfg.WorkspaceDir() at a temp HOME and returns the
// skills directory it resolves to plus a logger writing into buf.
func deployHarness(t *testing.T, buf *bytes.Buffer) (*config.Config, string, *log.Logger) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	return cfg, skills.Dir(cfg.WorkspaceDir()), log.New(buf, "", 0)
}

// TestDeployPersonaSkills_InstallsShippedPack: a workspace that has never seen
// the pack gets every shipped file written, each reported once.
func TestDeployPersonaSkills_InstallsShippedPack(t *testing.T) {
	var buf bytes.Buffer
	cfg, dir, logger := deployHarness(t, &buf)

	deployPersonaSkills(cfg, logger)

	listed, skipped, err := skills.ListWithSkips(dir)
	require.NoError(t, err)
	assert.Empty(t, skipped, "the shipped pack must never contain a file the catalog skips")
	assert.Len(t, listed, len(skills.Shipped()))
	for _, s := range skills.Shipped() {
		assert.FileExists(t, filepath.Join(dir, s.Name+".md"))
		assert.Contains(t, buf.String(), "skills: installed")
		assert.Contains(t, buf.String(), s.Name+".md")
	}
}

// TestDeployPersonaSkills_LeavesForeignFileAndSaysSo: a file the owner put
// under a name we also ship is never overwritten, and the log names it — the
// owner's copy of a shipped skill must not disappear on a daemon start.
func TestDeployPersonaSkills_LeavesForeignFileAndSaysSo(t *testing.T) {
	var buf bytes.Buffer
	cfg, dir, logger := deployHarness(t, &buf)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	foreign := filepath.Join(dir, skills.Shipped()[0].Name+".md")
	const ownersContent = "---\ndescription: Mine, not yours.\npersona: secretary\n---\nowner body\n"
	require.NoError(t, os.WriteFile(foreign, []byte(ownersContent), 0o644))

	deployPersonaSkills(cfg, logger)

	got, err := os.ReadFile(foreign)
	require.NoError(t, err)
	assert.Equal(t, ownersContent, string(got), "a file we never wrote must survive Deploy byte for byte")
	assert.Contains(t, buf.String(), "not shipped over")
	assert.Contains(t, buf.String(), foreign)
}

// TestDeployPersonaSkills_ReportsUnlistableFiles: a broken skill file (the
// owner's or ours) is logged as skipped, so it is visible in the daemon log
// instead of just missing from every chat's AVAILABLE SKILLS block.
func TestDeployPersonaSkills_ReportsUnlistableFiles(t *testing.T) {
	var buf bytes.Buffer
	cfg, dir, logger := deployHarness(t, &buf)
	require.NoError(t, os.MkdirAll(dir, 0o755))
	broken := filepath.Join(dir, "owner-broken.md")
	require.NoError(t, os.WriteFile(broken, []byte("no frontmatter at all\n"), 0o644))

	deployPersonaSkills(cfg, logger)

	assert.Contains(t, buf.String(), "skills: skipping "+broken)
	assert.Contains(t, buf.String(), "missing YAML frontmatter",
		"the log must carry the reason, not just the path")
}

// TestDeployPersonaSkills_UnwritableDirIsLoggedNotFatal: the whole call is
// best-effort — an unusable skills directory costs the owner the starter pack,
// never the daemon start.
func TestDeployPersonaSkills_UnwritableDirIsLoggedNotFatal(t *testing.T) {
	var buf bytes.Buffer
	cfg, dir, logger := deployHarness(t, &buf)
	// A regular file where the skills directory should be: MkdirAll fails.
	require.NoError(t, os.MkdirAll(filepath.Dir(dir), 0o755))
	require.NoError(t, os.WriteFile(dir, []byte("not a directory"), 0o644))

	deployPersonaSkills(cfg, logger)

	assert.Contains(t, buf.String(), "skills: deploy failed")
	assert.Contains(t, buf.String(), "skills: listing failed")
}

// TestDeployPersonaSkills_SecondRunIsQuiet: nothing changed, so nothing is
// logged — the daemon starts often and an unchanged pack must not add noise.
func TestDeployPersonaSkills_SecondRunIsQuiet(t *testing.T) {
	var buf bytes.Buffer
	cfg, _, logger := deployHarness(t, &buf)
	deployPersonaSkills(cfg, logger)

	buf.Reset()
	deployPersonaSkills(cfg, logger)

	assert.Empty(t, buf.String(), "a no-op deploy must log nothing")
}
