package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// runAutomationsWithStdin is runAutomations with stdin set to in.
func runAutomationsWithStdin(t *testing.T, in string, args ...string) (string, error) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(in))
	defer rootCmd.SetIn(nil)
	return runAutomations(t, args...)
}

// TestAutomationsValidate_Stdin (#604 S6): `validate -` reads the recipe from
// stdin with --slug in place of the file name; its JSON equals the file run's.
func TestAutomationsValidate_Stdin(t *testing.T) {
	newAutoCLI(t)
	text := autoCLIRecipeText(`return 1`)
	src := writeRecipe(t, t.TempDir(), "draft", text)
	fromFile := runAutomationsJSON(t, "validate", src)

	out, err := runAutomationsWithStdin(t, text, "validate", "-", "--slug", "draft", "--json")
	require.NoError(t, err, out)
	var fromStdin map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &fromStdin))
	assert.Equal(t, fromFile, fromStdin)
}

func TestAutomationsValidate_StdinNeedsSlug(t *testing.T) {
	newAutoCLI(t)
	_, err := runAutomationsWithStdin(t, autoCLIRecipeText(`return 1`), "validate", "-", "--json")
	require.ErrorContains(t, err, "--slug is required")
}

// TestAutomationsSave_StdinFile: `save --file - --path P` writes stdin's text
// to P, as --file does with a file; without --path it is refused.
func TestAutomationsSave_StdinFile(t *testing.T) {
	c := newAutoCLI(t)
	text := autoCLIRecipeText(`return 1`)
	target := filepath.Join(c.personal, "piped.md")
	out, err := runAutomationsWithStdin(t, text, "save", "--file", "-", "--path", target, "--json")
	require.NoError(t, err, out)
	data, err := os.ReadFile(target)
	require.NoError(t, err)
	assert.Equal(t, text, string(data))
	a, err := c.d.GetAutomationBySlug("personal", 0, "piped")
	require.NoError(t, err)
	assert.NotZero(t, a.ID)

	_, err = runAutomationsWithStdin(t, text, "save", "--file", "-", "--json")
	require.ErrorContains(t, err, "--path is required")
}
