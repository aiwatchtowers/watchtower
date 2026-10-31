package hub

import (
	"path/filepath"

	"watchtower/internal/config"
)

// liveDirName is the live hub's folder under the data root. It starts with a
// dot, so it can never be a workspace (config.ValidWorkspaceRe).
const liveDirName = ".hub"

// DefaultDir is the live hub's dir, <config.DataRoot()>/.hub. Nothing is
// created here; an unknown home folder is an error, never a relative path.
func DefaultDir() (string, error) {
	root, err := config.DataRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, liveDirName), nil
}
