package adopt

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/sqlcipher"
)

// copy snapshots the Swift sidecar and the CloudKit transport state with the
// SQLite backup API (a consistent copy of the committed state, WAL included)
// and copies the slice assets into <hub dir>/adopt.tmp, starting over from
// an empty folder. Each Swift file is first proven idle (swiftIdle): the
// Swift hub must not be running.
func (r *run) copy() error {
	if err := os.RemoveAll(r.tmpDir()); err != nil {
		return fmt.Errorf("adopt: clearing the copy: %w", err)
	}
	if err := os.MkdirAll(r.tmpDir(), 0o700); err != nil {
		return fmt.Errorf("adopt: creating the copy: %w", err)
	}
	if err := snapshot(r.ctx, r.swiftFile(), r.tmpFile()); err != nil {
		return err
	}
	transport := filepath.Join(r.mobile, transportFile)
	if exists(transport) {
		if err := os.MkdirAll(filepath.Join(r.tmpDir(), cloudKitDir), 0o700); err != nil {
			return fmt.Errorf("adopt: creating the copy: %w", err)
		}
		if err := snapshot(r.ctx, transport, filepath.Join(r.tmpDir(), cloudKitDir, transportFile)); err != nil {
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

// swiftBusyTimeout is how long the copy waits for the Swift file's lock.
var swiftBusyTimeout = "1000"

// snapshot copies the SQLite file src to dst (which must not exist) through
// the backup API, after proving src idle: an exclusive lock taken and
// released, and a full WAL checkpoint (busy 0, every frame checkpointed).
// The -wal/-shm the open leaves beside src are removed.
func snapshot(ctx context.Context, src, dst string) error {
	if err := backupFile(ctx, src, dst); err != nil {
		return err
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if err := os.Remove(src + suffix); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("adopt: removing a Swift file's log: %w", err)
		}
	}
	return syncFile(dst)
}

func backupFile(ctx context.Context, src, dst string) error {
	sdb, err := rawOpen(src, openRW)
	if err != nil {
		return err
	}
	defer func() { _ = sdb.Close() }()
	sconn, err := sdb.Conn(ctx)
	if err != nil {
		return fmt.Errorf("adopt: opening a Swift file: %w", err)
	}
	defer func() { _ = sconn.Close() }()
	if err := swiftIdle(ctx, sconn); err != nil {
		return err
	}
	ddb, err := rawOpen(dst, openCreate)
	if err != nil {
		return err
	}
	defer func() { _ = ddb.Close() }()
	dconn, err := ddb.Conn(ctx)
	if err != nil {
		return fmt.Errorf("adopt: creating the copy: %w", err)
	}
	defer func() { _ = dconn.Close() }()
	return dconn.Raw(func(d any) error {
		return sconn.Raw(func(s any) error {
			dc, ok1 := d.(*sqlcipher.SQLiteConn)
			sc, ok2 := s.(*sqlcipher.SQLiteConn)
			if !ok1 || !ok2 {
				return errors.New("adopt: not a SQLite connection")
			}
			b, err := dc.Backup("main", sc, "main")
			if err != nil {
				return fmt.Errorf("adopt: copying a Swift file: %w", err)
			}
			for {
				done, err := b.Step(-1)
				if err != nil {
					_ = b.Finish()
					return fmt.Errorf("%w: %w", ErrSwiftBusy, err)
				}
				if done {
					break
				}
			}
			if err := b.Finish(); err != nil {
				return fmt.Errorf("adopt: copying a Swift file: %w", err)
			}
			return nil
		})
	})
}

// swiftIdle proves no other connection uses the Swift file: an exclusive
// lock taken and released (a writer, or in DELETE mode a reader, blocks
// it), then wal_checkpoint(TRUNCATE) must report busy 0 and every frame
// checkpointed (a WAL reader blocks that). Either failing is ErrSwiftBusy.
func swiftIdle(ctx context.Context, c *sql.Conn) error {
	if _, err := c.ExecContext(ctx, `BEGIN EXCLUSIVE`); err != nil {
		return fmt.Errorf("%w: %w", ErrSwiftBusy, err)
	}
	if _, err := c.ExecContext(ctx, `COMMIT`); err != nil {
		return fmt.Errorf("%w: %w", ErrSwiftBusy, err)
	}
	var busy, logFrames, done int
	if err := c.QueryRowContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busy, &logFrames, &done); err != nil {
		return fmt.Errorf("%w: %w", ErrSwiftBusy, err)
	}
	if busy != 0 || logFrames != done {
		return ErrSwiftBusy
	}
	return nil
}

// verify makes the copy one the migrations take, before the commit point:
// the folded-in columns an older Swift build lacks are added
// (repairSwiftCopy) and checked, hub_meta.hub_id must be a UUID, the copy
// must pass integrity_check, it is vacuumed (no freed page keeps old text),
// and a dry run of the migrations over a scratch copy must leave every
// column a fresh Go sidecar has. Then the rename is recorded as next.
func (r *run) verify() error {
	db, err := rawOpen(r.tmpFile(), openRW)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	var res string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&res); err != nil || res != "ok" {
		return ErrSwiftCorrupt
	}
	if err := repairSwiftCopy(db); err != nil {
		return err
	}
	if err := checkFolded(db); err != nil {
		return err
	}
	if err := checkHubID(db); err != nil {
		return err
	}
	if _, err := db.Exec(`VACUUM`); err != nil {
		return fmt.Errorf("adopt: vacuuming the copy: %w", err)
	}
	if err := dryRunMigrations(r.tmpFile(), filepath.Join(r.tmpDir(), "scratch")); err != nil {
		return err
	}
	if err := setRawMeta(db, map[string]string{MetaAdoptStep: string(StepRename)}); err != nil {
		return err
	}
	if err := db.Close(); err != nil {
		return fmt.Errorf("adopt: closing the copy: %w", err)
	}
	return syncFile(r.tmpFile())
}

// rename moves the copy into the hub dir: the assets and the transport state
// first, hubstate.db last — its rename is the adoption's commit point —,
// each rename made durable (the dir synced) before the next, then records
// migrate as the next step. A part already moved is skipped.
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
		if err := syncDir(r.hub); err != nil {
			return err
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
		if err := syncDir(dir); err != nil {
			return err
		}
		if err := syncDir(r.hub); err != nil {
			return err
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
	// The commit point is durable before anything records it.
	if err := syncDir(r.hub); err != nil {
		return err
	}
	if err := hook("rename:state"); err != nil {
		return err
	}
	db, err := rawOpen(r.goFile(), openRW)
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

// moved makes MOVED durable first (written, synced, renamed into place, the
// dir synced), so an older app never starts the Swift hub over what is
// left; only then are the originals removed, and done recorded as next.
func (r *run) moved() error {
	if err := os.MkdirAll(r.mobile, 0o700); err != nil {
		return fmt.Errorf("adopt: the MobileHub dir: %w", err)
	}
	tmp := filepath.Join(r.mobile, "."+MovedName+".tmp")
	if err := writeSynced(tmp, []byte(movedNote(r.hub))); err != nil {
		return fmt.Errorf("adopt: writing the moved note: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(r.mobile, MovedName)); err != nil {
		return fmt.Errorf("adopt: writing the moved note: %w", err)
	}
	if err := syncDir(r.mobile); err != nil {
		return err
	}
	if err := hook("moved:note"); err != nil {
		return err
	}
	for _, name := range swiftOriginals {
		if err := os.RemoveAll(filepath.Join(r.mobile, name)); err != nil {
			return fmt.Errorf("adopt: removing the Swift hub's files: %w", err)
		}
	}
	if err := syncDir(r.mobile); err != nil {
		return err
	}
	st, err := r.store()
	if err != nil {
		return err
	}
	return st.SetMeta(MetaAdoptStep, string(StepDone))
}

// How rawOpen opens a file.
const (
	openRW      = iota // read-write, the file must exist
	openRO             // read-only (mode=ro), the file must exist
	openSwiftRO        // a Swift file read-only, without needing its -shm
	openCreate         // read-write, created when missing
)

// rawOpen opens a SQLite file outside state.Store (the Swift files, the
// copy, the Go file before or beside the Store): no migration, no pragma
// beyond a busy timeout. openSwiftRO reads a file whose -wal is absent or
// empty as immutable (no -shm is read or created: the Swift hub, which
// alone writes it, is stopped), else mode=ro.
func rawOpen(path string, mode int) (*sql.DB, error) {
	if mode != openCreate {
		if _, err := os.Stat(path); err != nil {
			return nil, fmt.Errorf("adopt: opening a hub file: %w", err)
		}
	}
	q := url.Values{}
	q.Set("_busy_timeout", swiftBusyTimeout)
	switch mode {
	case openRO:
		q.Set("mode", "ro")
	case openSwiftRO:
		q.Set("mode", "ro")
		if fi, err := os.Stat(path + "-wal"); err != nil || fi.Size() == 0 {
			q.Set("immutable", "1")
		}
	}
	db, err := sql.Open("sqlite3", "file:"+(&url.URL{Path: path}).EscapedPath()+"?"+q.Encode())
	if err != nil {
		return nil, fmt.Errorf("adopt: opening a hub file: %w", err)
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

// readMeta reads hub_meta keys from a file read-only (swift: openSwiftRO);
// a missing key reads "".
func readMeta(path string, swift bool, keys ...string) (map[string]string, error) {
	mode := openRO
	if swift {
		mode = openSwiftRO
	}
	db, err := rawOpen(path, mode)
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
	db, err := rawOpen(path, openRW)
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

// writeSynced writes data to a new file (0600) and syncs it.
func writeSynced(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// syncFile fsyncs a file and tightens it to 0600.
func syncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("adopt: syncing a file: %w", err)
	}
	defer func() { _ = f.Close() }()
	if err := f.Chmod(0o600); err != nil {
		return fmt.Errorf("adopt: syncing a file: %w", err)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("adopt: syncing a file: %w", err)
	}
	return nil
}

// syncDir fsyncs a directory, so a rename in it is durable.
func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("adopt: syncing a dir: %w", err)
	}
	defer func() { _ = f.Close() }()
	if err := f.Sync(); err != nil {
		return fmt.Errorf("adopt: syncing a dir: %w", err)
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
