package watchmanact

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeGhRun runs testdata/gh in mode for every "gh" the check runs.
func fakeGhRun(t *testing.T, mode string) func(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	t.Helper()
	gh, err := filepath.Abs(filepath.Join("testdata", "gh"))
	require.NoError(t, err)
	return func(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
		require.Equal(t, "gh", name)
		cmd := exec.CommandContext(ctx, gh, args...) // #nosec G204 -- the test's fake gh
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "FAKE_GH_MODE="+mode)
		return cmd.Output()
	}
}

func TestCheckProtection_FakeGh(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	cases := []struct {
		mode string
		want Protection
	}{
		{"protected", Protection{DefaultBranch: "main", OwnerReviewRequired: true}},
		{"noreview", Protection{DefaultBranch: "main", Warning: "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here"}},
		{"unprotected", Protection{DefaultBranch: "main", Warning: "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here"}},
		{"missing", Protection{Warning: "Could not read main's protection on GitHub — treat it as unprotected"}},
		{"broken", Protection{DefaultBranch: "main", Warning: "Could not read main's protection on GitHub — treat it as unprotected"}},
	}
	for _, c := range cases {
		t.Run(c.mode, func(t *testing.T) {
			assert.Equal(t, c.want, CheckProtection(ctx, fakeGhRun(t, c.mode), dir))
		})
	}
	t.Run("gh not installed", func(t *testing.T) {
		run := func(context.Context, string, string, ...string) ([]byte, error) { return nil, exec.ErrNotFound }
		assert.Equal(t, Protection{Warning: ProtectionWarningUnreadable}, CheckProtection(ctx, run, dir))
	})
}
