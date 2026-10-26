package coach

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAppendAllowRules_PreservesOtherKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	orig := `{
  "model": "opus",
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a && b <x>"}]}]},
  "big": 12345678901234567890,
  "permissions": {"allow": ["Read", "Bash(ls:*)"], "deny": ["Bash(rm:*)"], "defaultMode": "plan"}
}`
	require.NoError(t, os.WriteFile(path, []byte(orig), 0o640))

	before, after, err := AppendAllowRules(path, []string{"Bash(ls:*)", "Bash(go test:*)", "Bash(go test:*)"})
	require.NoError(t, err)
	assert.Equal(t, orig, string(before), "the exact before bytes")
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, string(after), string(raw))

	var got, want map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw, &got))
	require.NoError(t, json.Unmarshal([]byte(orig), &want))
	for _, k := range []string{"model", "hooks", "big"} {
		assert.JSONEq(t, string(want[k]), string(got[k]), k)
	}
	assert.Contains(t, string(raw), "12345678901234567890", "numbers are kept as written")
	assert.Contains(t, string(raw), "a && b <x>", "no HTML escaping")
	assert.JSONEq(t, `{"allow": ["Read", "Bash(ls:*)", "Bash(go test:*)"], "deny": ["Bash(rm:*)"], "defaultMode": "plan"}`,
		string(got["permissions"]), "only allow changes, deduplicated")

	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o640), fi.Mode().Perm())
	entries, err := os.ReadDir(filepath.Dir(path))
	require.NoError(t, err)
	assert.Len(t, entries, 1, "no temp file left behind")

	// Nothing new: the file is not written.
	b2, a2, err := AppendAllowRules(path, []string{"Read"})
	require.NoError(t, err)
	assert.Equal(t, b2, a2)
	raw2, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, raw, raw2)

	require.NoError(t, RestoreFile(path, before))
	raw, err = os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, orig, string(raw))
}

func TestAppendAllowRules_MissingFileCreated(t *testing.T) {
	home := t.TempDir()
	path := claudeSettingsPath(home)

	before, after, err := AppendAllowRules(path, []string{"Bash(go test:*)"})
	require.NoError(t, err)
	assert.Nil(t, before)
	assert.JSONEq(t, `{"permissions": {"allow": ["Bash(go test:*)"]}}`, string(after))
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	di, err := os.Stat(filepath.Dir(path))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())

	require.NoError(t, RestoreFile(path, nil))
	assert.NoFileExists(t, path)

	// No rules on a missing file: nothing is created.
	_, _, err = AppendAllowRules(path, nil)
	require.NoError(t, err)
	assert.NoFileExists(t, path)
}

func TestAppendAllowRules_RefusesSymlinkAndInvalidJSON(t *testing.T) {
	dir := t.TempDir()

	target := filepath.Join(dir, "real.json")
	content := []byte(`{"permissions":{"allow":["Read"]}}`)
	require.NoError(t, os.WriteFile(target, content, 0o600))
	link := filepath.Join(dir, "link.json")
	require.NoError(t, os.Symlink(target, link))
	_, _, err := AppendAllowRules(link, []string{"Bash(go test:*)"})
	require.ErrorIs(t, err, errSettingsNotRegular)
	raw, err := os.ReadFile(target)
	require.NoError(t, err)
	assert.Equal(t, content, raw, "the symlink target is untouched")
	require.ErrorIs(t, RestoreFile(link, []byte(`{}`)), errSettingsNotRegular)

	for name, body := range map[string]string{
		"invalid":     `{"permissions": {"allow": [`,
		"empty":       ``,
		"null":        `null`,
		"array":       `[]`,
		"perms-null":  `{"permissions": null}`,
		"perms-array": `{"permissions": []}`,
		"allow-mixed": `{"permissions": {"allow": ["Read", 1]}}`,
		"allow-str":   `{"permissions": {"allow": "Read"}}`,
	} {
		path := filepath.Join(dir, name+".json")
		require.NoError(t, os.WriteFile(path, []byte(body), 0o600))
		_, _, err := AppendAllowRules(path, []string{"Bash(go test:*)"})
		require.ErrorIs(t, err, errSettingsInvalid, name)
		got, err := os.ReadFile(path)
		require.NoError(t, err)
		assert.Equal(t, body, string(got), name+": the file is untouched")
	}
}

func TestRemoveAllowRules_KeepsTheRest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	require.NoError(t, os.WriteFile(path, []byte(`{"permissions":{"allow":["A","B","A","C"]}}`), 0o600))
	_, _, err := removeAllowRules(path, []string{"A"})
	require.NoError(t, err)
	rules, err := readAllowRules(path)
	require.NoError(t, err)
	assert.Equal(t, []string{"B", "C"}, rules)
}

func TestWriteFileAtomic_RefusesAChangedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	require.NoError(t, os.WriteFile(path, []byte(`{"a":2}`), 0o600))
	err := writeFileAtomic(path, []byte(`{"b":1}`), 0o600, []byte(`{"a":1}`), true)
	require.ErrorIs(t, err, errSettingsChanged)
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, `{"a":2}`, string(raw), "nothing replaced")
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	assert.Len(t, entries, 1, "the temp file is removed")

	// A file that appeared while it was expected to be absent.
	require.ErrorIs(t, writeFileAtomic(path, []byte(`{}`), 0o600, nil, false), errSettingsChanged)
}

func TestSettingsErrors_CarryNoPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "missing-folder", "settings.json")
	require.NoError(t, os.WriteFile(filepath.Join(dir, "missing-folder"), nil, 0o600)) // a file where the folder should be
	_, _, err := AppendAllowRules(path, []string{"Bash(go test:*)"})
	require.Error(t, err)
	assert.NotContains(t, err.Error(), dir)
}
