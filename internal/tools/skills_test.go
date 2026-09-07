package tools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedSkills writes a small catalog: one enabled skill and one disabled one.
func seedSkills(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"status-update.md": "---\ndescription: Draft a status update.\nenabled: true\n---\n# Draft a status update\n\nAsk the owner what it should say.\n",
		"quiet-skill.md":   "---\ndescription: Switched off.\nenabled: false\n---\n# Quiet\n\nBody.\n",
	}
	for name, content := range files {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644))
	}
	return dir
}

func callLoadSkill(t *testing.T, dir, name string) (loadSkillResult, error) {
	t.Helper()
	reg := New(openDB(t))
	require.NoError(t, reg.Register(NewLoadSkill(dir)))
	data, err := reg.CallRead(context.Background(), "load_skill", json.RawMessage(`{"name":`+strconv.Quote(name)+`}`))
	if err != nil {
		return loadSkillResult{}, err
	}
	var out loadSkillResult
	require.NoError(t, remarshal(data, &out))
	return out, nil
}

func TestLoadSkill_HappyPath(t *testing.T) {
	got, err := callLoadSkill(t, seedSkills(t), "status-update")
	require.NoError(t, err)
	assert.Equal(t, "status-update", got.Name)
	assert.True(t, got.Enabled)
	assert.Contains(t, got.Body, "Ask the owner what it should say.")
	assert.NotContains(t, got.Body, "description:", "the frontmatter block is stripped")
}

// A disabled skill still loads — the enable toggle gates the listing, not the
// read.
func TestLoadSkill_DisabledStillLoads(t *testing.T) {
	got, err := callLoadSkill(t, seedSkills(t), "quiet-skill")
	require.NoError(t, err)
	assert.False(t, got.Enabled)
}

func TestLoadSkill_UnknownName(t *testing.T) {
	_, err := callLoadSkill(t, seedSkills(t), "does-not-exist")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no skill named")
}

// Every name that could escape the skills directory is rejected on the name
// itself, before any path is built.
func TestLoadSkill_RejectsTraversal(t *testing.T) {
	dir := seedSkills(t)
	secret := filepath.Join(filepath.Dir(dir), "secret.md")
	require.NoError(t, os.WriteFile(secret, []byte("---\ndescription: S.\n---\ntop secret\n"), 0o644))

	for _, name := range []string{"../secret", "../../etc/passwd", "sub/dir", "Status-Update", "status_update", ".."} {
		_, err := callLoadSkill(t, dir, name)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
		assert.Contains(t, verr.Msg, "invalid skill name", name)
		assert.NotContains(t, verr.Msg, "top secret", name)
	}
}

func TestLoadSkill_BlankName(t *testing.T) {
	_, err := callLoadSkill(t, seedSkills(t), "  ")
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "name is required")
}

// With no skills directory the tool still exists but degrades to a soft
// "unavailable" answer.
func TestLoadSkill_NoDir(t *testing.T) {
	_, err := callLoadSkill(t, "", "status-update")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no skills directory is configured")
}
