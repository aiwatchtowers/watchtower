package hub

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// Go twins of MobileHubServiceTests' staged-asset tests: the owner's off and
// an iCloud account change remove the staged files and the slice_assets
// descriptors (each holding its file's K_asset); a plain stop keeps them.

// adoptedAsset is a file an adoption copied from the Swift hub's SliceAssets.
const adoptedAsset = "meeting_transcript-1/segments.json"

// seedStagedAssets stages an adopted file, a transcript file and the
// adopted file's descriptor row.
func seedStagedAssets(t *testing.T, dir string) {
	t.Helper()
	for _, rel := range []string{adoptedAsset, filepath.Join(transcriptAssetDir, "1-abcdef.asset")} {
		p := filepath.Join(dir, assetDirName, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("sealed"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT INTO slice_assets (file_path, descriptor) VALUES (?, x'd0d1')`, adoptedAsset)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

// stagedLeft reports whether the adopted file and its descriptor are still there.
func stagedLeft(t *testing.T, dir string) (file, row bool) {
	t.Helper()
	_, err := os.Stat(filepath.Join(dir, assetDirName, adoptedAsset))
	file = err == nil
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	var n int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM slice_assets`).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return file, n > 0
}

func assetDirEmpty(t *testing.T, dir string) bool {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(dir, assetDirName))
	return err == nil && len(entries) == 0
}

// twin of MobileHubServiceTests.testDisableRemovesTheStagedAssetsAndStopStopsOnly
// and the off half of testAccountResetAndDisableStillRemoveStagedFilesAndDescriptors
func TestOwnerOffRemovesTheStagedAssetsAndTheirDescriptors(t *testing.T) {
	r, _ := ownerOffRig(t)
	seedStagedAssets(t, r.dir)
	disableHub(t, r.dir)
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, "the staged assets gone", func() bool {
		file, row := stagedLeft(t, r.dir)
		return !file && !row && assetDirEmpty(t, r.dir)
	})
}

// twin of the plain-stop half of MobileHubServiceTests.testDisableRemovesTheStagedAssetsAndStopStopsOnly
func TestAPlainStopKeepsTheStagedAssets(t *testing.T) {
	r, _ := ownerOffRig(t)
	seedStagedAssets(t, r.dir)
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if file, row := stagedLeft(t, r.dir); !file || !row {
		t.Fatalf("a plain stop removed the staged assets: file %v, row %v", file, row)
	}
}

// twin of MobileHubServiceTests.testAccountResetRemovesTheStagedAssets and
// the account half of testAccountResetAndDisableStillRemoveStagedFilesAndDescriptors
func TestAnICloudAccountChangeRemovesTheStagedAssets(t *testing.T) {
	h := startCloudKitHub(t, nil, nil)
	seedStagedAssets(t, h.dir)
	h.ck.inject(transport.Event{AccountChanged: true})
	eventually(t, "the staged assets gone", func() bool {
		file, row := stagedLeft(t, h.dir)
		return !file && !row && assetDirEmpty(t, h.dir)
	})
	if s := h.rec.last(); s.State != StateRunning {
		t.Fatalf("the hub stopped: %+v", s)
	}
}

// A symlinked asset dir is refused: its target's files stay, the
// descriptors still go.
func TestRemoveStagedAssetsRefusesASymlinkedAssetDir(t *testing.T) {
	dir := shortDir(t)
	target := t.TempDir()
	keep := filepath.Join(target, "keep.txt")
	if err := os.WriteFile(keep, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	seedStagedAssets(t, dir)
	if err := os.RemoveAll(filepath.Join(dir, assetDirName)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, assetDirName)); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := removeStagedAssets(dir, st); !errors.Is(err, errAssetDirNotADir) {
		t.Fatalf("removeStagedAssets = %v, want errAssetDirNotADir", err)
	}
	_ = st.Close()
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("the link's target was emptied: %v", err)
	}
	if _, row := stagedLeft(t, dir); row {
		t.Fatal("the descriptors stayed")
	}
}
