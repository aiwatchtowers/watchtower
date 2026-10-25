package policy

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestPolicy01_KeysNeverCollideWithAppDefaults pins that no policy key is a
// key the Desktop writes into its own UserDefaults (same domain): a value the
// app stores could otherwise be mistaken for a policy key by a reader, and a
// forced key would outvote an app setting by accident.
func TestPolicy01_KeysNeverCollideWithAppDefaults(t *testing.T) {
	keyShape := regexp.MustCompile(`^[A-Z][A-Za-z]+$`)
	all := append(append([]string{}, Keys...), ReservedKeys...)
	for _, k := range all {
		require.Regexp(t, keyShape, k)
	}

	root := filepath.Join("..", "..", "WatchtowerDesktop", "Sources")
	files := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".swift") || d.Name() == "ManagedPolicy.swift" {
			return nil
		}
		// #nosec G122 -- path comes from WalkDir over the repo's own source tree in a test.
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		files++
		for _, k := range all {
			if strings.Contains(string(b), `"`+k+`"`) {
				t.Errorf("%s uses the policy key %q as a string literal", path, k)
			}
		}
		return nil
	})
	require.NoError(t, err)
	require.Positive(t, files, "no Swift sources found under %s", root)
}
