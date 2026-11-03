package hub

import (
	"errors"
	"log"
	"os"
	"path/filepath"

	"watchtower/internal/hub/state"
)

// Staged assets (the Swift SliceAssetStore.removeAll): the sealed files in
// the hub's asset dir — the meeting transcripts' segments, and what an
// adoption copied from the Swift hub — and the slice_assets descriptors an
// adopted sidecar holds, each with its file's K_asset. The owner's off and
// an iCloud account change remove both, so no key outlives its link; a plain
// stop keeps them (the next start's transcript read sweeps its own files).

// errAssetDirNotADir: <dir>/assets is a symlink or not a directory; nothing
// under it is deleted, so a link can never empty its target.
var errAssetDirNotADir = errors.New("hub: the asset dir is not a plain directory")

// removeStagedAssets empties <dir>/assets (the directory stays: the
// transports confine uploads to it) and deletes every slice_assets row.
func removeStagedAssets(dir string, st *state.Store) error {
	root := filepath.Join(dir, assetDirName)
	var entries []os.DirEntry
	fi, err := os.Lstat(root)
	switch {
	case errors.Is(err, os.ErrNotExist):
		err = nil
	case err != nil:
	case !fi.IsDir(): // a symlink (Lstat does not follow it) or a file
		err = errAssetDirNotADir
	default:
		entries, err = os.ReadDir(root)
	}
	for _, e := range entries {
		err = errors.Join(err, os.RemoveAll(filepath.Join(root, e.Name())))
	}
	return errors.Join(err, st.DeleteSliceAssets())
}

// forgetStagedAssets is an iCloud account change's half (the Swift hub's
// account reset): with the publisher held, so no cycle is reading or
// uploading a staged file, the files and descriptors go and the transcript
// source forgets what it staged; the resumed full diff stages anew.
func (h *hubRuntime) forgetStagedAssets() {
	if h.pub != nil {
		h.pub.PauseFor(pauseStagedAssets)
		defer h.pub.ResumeFor(pauseStagedAssets)
	}
	if err := removeStagedAssets(h.sup.o.Dir, h.st); err != nil {
		log.Printf("hub: removing the staged assets after an iCloud account change failed (%s)", errClass(err))
	}
	if h.wiring != nil && h.wiring.set.Staged != nil {
		h.wiring.set.Staged.ForgetStaged()
	}
}

// pauseStagedAssets is the publisher hold forgetStagedAssets takes.
const pauseStagedAssets = "staged_assets"
