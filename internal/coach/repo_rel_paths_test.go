package coach

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestRepoRelPath_SharedTable reads the table the Swift
// CoachProposal.repoRelativePath tests read too, so the two sides cannot
// drift: a null path is a refusal (ok false).
func TestRepoRelPath_SharedTable(t *testing.T) {
	raw, err := os.ReadFile("testdata/repo_rel_paths.json")
	require.NoError(t, err)
	var table struct {
		Cases []struct {
			Destination string  `json:"destination"`
			Skill       string  `json:"skill"`
			Path        *string `json:"path"`
		} `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &table))
	require.NotEmpty(t, table.Cases)
	for _, c := range table.Cases {
		got, ok := RepoRelPath(c.Destination, c.Skill)
		if c.Path == nil {
			require.Falsef(t, ok, "%s %q: want a refusal, got %q", c.Destination, c.Skill, got)
			continue
		}
		require.Truef(t, ok, "%s %q: refused", c.Destination, c.Skill)
		require.Equalf(t, *c.Path, got, "%s %q", c.Destination, c.Skill)
	}
}

// TestRepoLines_SharedFixture pins RepoDirtyLine and RepoNotGitLine to the
// fixture the Swift TuningChatTexts tests read, so the card's error lines
// cannot drift between the two sides.
func TestRepoLines_SharedFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/repo_lines.json")
	require.NoError(t, err)
	var lines struct {
		DirtyPath string `json:"dirty_path"`
		Dirty     string `json:"dirty"`
		NotGit    string `json:"not_git"`
	}
	require.NoError(t, json.Unmarshal(raw, &lines))
	require.Equal(t, lines.Dirty, fmt.Sprintf(RepoDirtyLine, lines.DirtyPath))
	require.Equal(t, lines.NotGit, RepoNotGitLine)
}
