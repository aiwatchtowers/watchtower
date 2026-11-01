package adopt

import (
	"database/sql"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// copy copies the Swift sidecar (its WAL checkpointed into the file first),
// the CloudKit transport state and the slice assets into <hub dir>/adopt.tmp,
// starting over from an empty folder.
func (r *run) copy() error {
	if err := os.RemoveAll(r.tmpDir()); err != nil {
		return fmt.Errorf("adopt: clearing the copy: %w", err)
	}
	if err := os.MkdirAll(r.tmpDir(), 0o700); err != nil {
		return fmt.Errorf("adopt: creating the copy: %w", err)
	}
	if err := checkpoint(r.swiftFile()); err != nil {
		return err
	}
	if err := copyFile(r.swiftFile(), r.tmpFile()); err != nil {
		return err
	}
	transport := filepath.Join(r.mobile, transportFile)
	if exists(transport) {
		if err := checkpoint(transport); err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Join(r.tmpDir(), cloudKitDir), 0o700); err != nil {
			return fmt.Errorf("adopt: creating the copy: %w", err)
		}
		if err := copyFile(transport, filepath.Join(r.tmpDir(), cloudKitDir, transportFile)); err != nil {
			return err
		}
	}
	if fi, err := os.Lstat(filepath.Join(r.mobile, swiftAssetsDir)); err == nil && fi.IsDir() {
		if err := copyTree(filepath.Join(r.mobile, swiftAssetsDir), filepath.Join(r.tmpDir(), goAssetsDir)); err != nil {
			return err
		}
	}
	return nil
}

// verify checks the copy (CheckSwiftFile, integrity_check) and records the
// rename as the next step in it.
func (r *run) verify() error {
	if err := CheckSwiftFile(r.tmpFile()); err != nil {
		return err
	}
	db, err := rawOpen(r.tmpFile(), false)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	var res string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&res); err != nil || res != "ok" {
		return ErrSwiftCorrupt
	}
	return setRawMeta(db, map[string]string{MetaAdoptStep: string(StepRename)})
}

// rename moves the copy into the hub dir: the assets and the transport state
// first, hubstate.db last — its rename is the adoption's commit point —,
// then records migrate as the next step. A part already moved is skipped.
func (r *run) rename() error {
	assets := filepath.Join(r.tmpDir(), goAssetsDir)
	if exists(assets) {
		dst := filepath.Join(r.hub, goAssetsDir)
		if err := os.RemoveAll(dst); err != nil {
			return fmt.Errorf("adopt: replacing the assets: %w", err)
		}
		if err := os.Rename(assets, dst); err != nil {
			return fmt.Errorf("adopt: moving the assets: %w", err)
		}
	}
	if err := hook("rename:assets"); err != nil {
		return err
	}
	transport := filepath.Join(r.tmpDir(), cloudKitDir, transportFile)
	if exists(transport) {
		dir := filepath.Join(r.hub, cloudKitDir)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("adopt: creating the CloudKit dir: %w", err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("adopt: tightening the CloudKit dir: %w", err)
		}
		if err := os.Rename(transport, filepath.Join(dir, transportFile)); err != nil {
			return fmt.Errorf("adopt: moving the transport state: %w", err)
		}
	}
	if err := hook("rename:transport"); err != nil {
		return err
	}
	if exists(r.tmpFile()) && !exists(r.goFile()) {
		if err := os.Rename(r.tmpFile(), r.goFile()); err != nil {
			return fmt.Errorf("adopt: moving the hub state: %w", err)
		}
	}
	if err := hook("rename:state"); err != nil {
		return err
	}
	db, err := rawOpen(r.goFile(), false)
	if err != nil {
		return err
	}
	err = setRawMeta(db, map[string]string{MetaAdoptStep: string(StepMigrate)})
	_ = db.Close()
	if err != nil {
		return err
	}
	if err := os.RemoveAll(r.tmpDir()); err != nil {
		return fmt.Errorf("adopt: removing the copy: %w", err)
	}
	return nil
}

// movedNote is MOVED's exact content.
func movedNote(hubDir string) string { return "hub_impl=go\nmoved_to=" + hubDir + "\n" }

// swiftOriginals are the Swift hub's files removed once adopted.
var swiftOriginals = []string{
	"hubstate.db", "hubstate.db-wal", "hubstate.db-shm", "hubstate.db-journal",
	transportFile, transportFile + "-wal", transportFile + "-shm", transportFile + "-journal",
	swiftAssetsDir,
}

// moved writes MOVED first (so an older app never starts the Swift hub over
// what is left), then removes the originals, then records done as next.
func (r *run) moved() error {
	if err := os.MkdirAll(r.mobile, 0o700); err != nil {
		return fmt.Errorf("adopt: the MobileHub dir: %w", err)
	}
	tmp := filepath.Join(r.mobile, "."+MovedName+".tmp")
	if err := os.WriteFile(tmp, []byte(movedNote(r.hub)), 0o600); err != nil {
		return fmt.Errorf("adopt: writing the moved note: %w", err)
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return fmt.Errorf("adopt: writing the moved note: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(r.mobile, MovedName)); err != nil {
		return fmt.Errorf("adopt: writing the moved note: %w", err)
	}
	if err := hook("moved:note"); err != nil {
		return err
	}
	for _, name := range swiftOriginals {
		if err := os.RemoveAll(filepath.Join(r.mobile, name)); err != nil {
			return fmt.Errorf("adopt: removing the Swift hub's files: %w", err)
		}
	}
	st, err := r.store()
	if err != nil {
		return err
	}
	return st.SetMeta(MetaAdoptStep, string(StepDone))
}

// checkpoint copies a SQLite file's WAL into it: one read-write open,
// wal_checkpoint(TRUNCATE), close.
func checkpoint(path string) error {
	db, err := rawOpen(path, false)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	if _, err := db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		return fmt.Errorf("adopt: checkpointing: %w", err)
	}
	return nil
}

// rawOpen opens a SQLite file outside state.Store (the Swift file, the
// copy): no migration, no pragma beyond a busy timeout; readOnly opens it
// mode=ro. The file must exist.
func rawOpen(path string, readOnly bool) (*sql.DB, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("adopt: opening a hub file: %w", err)
	}
	q := url.Values{}
	q.Set("_busy_timeout", "2000")
	if readOnly {
		q.Set("mode", "ro")
	}
	db, err := sql.Open("sqlite3", "file:"+(&url.URL{Path: path}).EscapedPath()+"?"+q.Encode())
	if err != nil {
		return nil, fmt.Errorf("adopt: opening a hub file: %w", err)
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

// readMeta reads hub_meta keys from a file read-only; a missing key reads "".
func readMeta(path string, keys ...string) (map[string]string, error) {
	db, err := rawOpen(path, true)
	if err != nil {
		return nil, err
	}
	defer func() { _ = db.Close() }()
	out := map[string]string{}
	for _, k := range keys {
		var v string
		err := db.QueryRow(`SELECT value FROM hub_meta WHERE key = ?`, k).Scan(&v)
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return nil, fmt.Errorf("adopt: reading hub_meta: %w", err)
		default:
			out[k] = v
		}
	}
	return out, nil
}

func writeRawMeta(path string, kv map[string]string) error {
	db, err := rawOpen(path, false)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS hub_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`); err != nil {
		return fmt.Errorf("adopt: writing hub_meta: %w", err)
	}
	return setRawMeta(db, kv)
}

func setRawMeta(db *sql.DB, kv map[string]string) error {
	for k, v := range kv {
		if _, err := db.Exec(`INSERT INTO hub_meta (key, value) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`, k, v); err != nil {
			return fmt.Errorf("adopt: writing hub_meta: %w", err)
		}
	}
	return nil
}

// copyFile copies a regular file (never a symlink) to dst, 0600, synced.
func copyFile(src, dst string) error {
	fi, err := os.Lstat(src)
	if err != nil {
		return fmt.Errorf("adopt: reading a hub file: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("adopt: a hub file is not a regular file")
	}
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("adopt: reading a hub file: %w", err)
	}
	defer func() { _ = in.Close() }()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("adopt: writing a copy: %w", err)
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return fmt.Errorf("adopt: writing a copy: %w", err)
	}
	if err := out.Sync(); err != nil {
		_ = out.Close()
		return fmt.Errorf("adopt: writing a copy: %w", err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("adopt: writing a copy: %w", err)
	}
	return nil
}

// copyTree copies the regular files and folders under src to dst (0700
// folders, 0600 files); symlinks and special files are skipped.
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("adopt: reading the slice assets: %w", err)
		}
		rel, err := filepath.Rel(src, path)
		if err != nil || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("adopt: reading the slice assets")
		}
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			if err := os.MkdirAll(target, 0o700); err != nil {
				return fmt.Errorf("adopt: copying the slice assets: %w", err)
			}
			return nil
		case d.Type().IsRegular():
			return copyFile(path, target)
		}
		return nil
	})
}
