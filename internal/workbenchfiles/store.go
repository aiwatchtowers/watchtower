// Package workbenchfiles stores the images attached to project board targets
// (board target #117) under <workspace>/project_files/<project_id>/ — outside
// the project folder, so nothing of it can ever be committed to the owner's
// repository. Directories are 0700 and files 0600; a file is named by its
// content's sha256, so one project stores each image once however many of
// its targets carry it. Deciding which files are still wanted is the
// database's job (db.WorkbenchImagePaths); this package only copies, sweeps and
// removes.
package workbenchfiles

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// MaxImageBytes caps one attached image — the chat attachments' image limit
// (chat.MaxImageBytes), so an image the owner can attach in the AI Chat can
// be attached to a target too.
const MaxImageBytes int64 = 5 << 20

// imageExtensions maps each accepted sniffed type to its stored extension.
var imageExtensions = map[string]string{
	"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp",
}

// RejectError is a refused source file: the model-facing reason, never an
// internal failure.
type RejectError struct {
	Path   string
	Reason string
}

func (e *RejectError) Error() string { return fmt.Sprintf("image %q: %s", e.Path, e.Reason) }

// Image is one stored copy.
type Image struct {
	FileName string // the source's base name, for display
	MIME     string
	Size     int64
	SHA256   string
	Path     string // absolute path of the stored copy
	// Created is true when this Ingest wrote the copy, false when it reused
	// one already there — which another row may name, so a caller undoing a
	// failed write discards only the copies it created.
	Created bool
}

// Store roots every project's image directory.
type Store struct{ root string }

// New returns the store under workspaceDir/project_files.
func New(workspaceDir string) Store {
	return Store{root: filepath.Join(workspaceDir, "project_files")}
}

// Dir is project projectID's image directory.
func (s Store) Dir(projectID int64) string {
	return filepath.Join(s.root, strconv.FormatInt(projectID, 10))
}

// Ingest validates the image at src and copies it into project projectID's
// directory, reusing a copy of the same content already there. src must be
// an absolute path to a regular file (a symlink is refused) holding a PNG,
// JPEG, GIF or WebP of at most MaxImageBytes — decided by content, never by
// extension. Every check runs against the one opened descriptor, and the
// read stops one byte past the cap, so a file swapped or grown after the
// open cannot slip past them.
func (s Store) Ingest(projectID int64, src string) (Image, error) {
	data, mime, err := readImage(src)
	if err != nil {
		return Image{}, err
	}
	ext := imageExtensions[mime]
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	dir, err := s.ensureDir(projectID)
	if err != nil {
		return Image{}, err
	}
	dst := filepath.Join(dir, sha+ext)
	created, err := writeOnce(dst, data)
	if err != nil {
		return Image{}, err
	}
	return Image{FileName: filepath.Base(src), MIME: mime, Size: int64(len(data)), SHA256: sha, Path: dst, Created: created}, nil
}

// Check runs Ingest's checks on src without storing anything, so a caller
// can refuse a bad file before it writes a row.
func Check(src string) error {
	_, _, err := readImage(src)
	return err
}

// readImage reads src and returns its bytes and sniffed type, or a
// RejectError.
func readImage(src string) ([]byte, string, error) {
	data, err := readRegular(src)
	if err != nil {
		return nil, "", err
	}
	mime := http.DetectContentType(data)
	if _, ok := imageExtensions[mime]; !ok {
		return nil, "", &RejectError{Path: src, Reason: "not a PNG, JPEG, GIF or WebP image"}
	}
	return data, mime, nil
}

func readRegular(src string) ([]byte, error) {
	if !filepath.IsAbs(src) {
		return nil, &RejectError{Path: src, Reason: "path must be absolute"}
	}
	// O_NONBLOCK: opening a FIFO for reading would otherwise wait for a
	// writer forever; it changes nothing for a regular file.
	f, err := os.OpenFile(src, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	switch {
	case errors.Is(err, syscall.ELOOP):
		return nil, &RejectError{Path: src, Reason: "is a symlink; give the file itself"}
	case errors.Is(err, os.ErrNotExist):
		return nil, &RejectError{Path: src, Reason: "no such file"}
	case errors.Is(err, os.ErrPermission):
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("cannot be read (%v); macOS may be blocking access "+
			"to its folder — ask the owner to copy the file somewhere else", errors.Unwrap(err))}
	case err != nil:
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("cannot be read (%v)", errors.Unwrap(err))}
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("cannot be inspected (%v)", err)}
	}
	if !info.Mode().IsRegular() {
		return nil, &RejectError{Path: src, Reason: "is not a regular file"}
	}
	if info.Size() > MaxImageBytes {
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("is larger than %d MB", MaxImageBytes>>20)}
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxImageBytes+1))
	if err != nil {
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("cannot be read (%v)", err)}
	}
	if int64(len(data)) > MaxImageBytes {
		return nil, &RejectError{Path: src, Reason: fmt.Sprintf("is larger than %d MB", MaxImageBytes>>20)}
	}
	if len(data) == 0 {
		return nil, &RejectError{Path: src, Reason: "is empty"}
	}
	return data, nil
}

// ensureDir creates the root and the project's directory 0700, tightening a
// directory that already exists with looser permissions.
func (s Store) ensureDir(projectID int64) (string, error) {
	dir := s.Dir(projectID)
	for _, d := range []string{s.root, dir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return "", fmt.Errorf("creating %s: %w", d, err)
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return "", fmt.Errorf("securing %s: %w", d, err)
		}
	}
	return dir, nil
}

// writeOnce writes data to dst through a temp file and a rename, unless dst
// already holds a regular file of that size — the name is the content's
// hash, so such a file is the same image. created reports whether it wrote.
func writeOnce(dst string, data []byte) (created bool, err error) {
	if info, err := os.Lstat(dst); err == nil && info.Mode().IsRegular() && info.Size() == int64(len(data)) {
		return false, nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".incoming-*") // 0600
	if err != nil {
		return false, fmt.Errorf("storing image: %w", err)
	}
	name := tmp.Name()
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(name, dst)
	}
	if werr != nil {
		_ = os.Remove(name) // best effort: the write's own error is what failed
		return false, fmt.Errorf("storing image: %w", werr)
	}
	return true, nil
}

// Discard removes each of paths that keep does not name — the stored copies
// no row points at any more after a detach, a target delete or a failed
// write. A path outside the store, or already gone, is left alone.
func (s Store) Discard(paths []string, keep map[string]bool) error {
	var errs []error
	for _, p := range paths {
		if keep[p] || !s.contains(p) {
			continue
		}
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// contains reports whether p is a file directly inside a project directory
// of this store — the only shape Ingest ever produces.
func (s Store) contains(p string) bool {
	rel, err := filepath.Rel(s.root, filepath.Clean(p))
	if err != nil || !filepath.IsAbs(p) {
		return false
	}
	dir, file := filepath.Split(rel)
	dir = filepath.Clean(dir)
	_, perr := strconv.ParseInt(dir, 10, 64)
	return perr == nil && file != "" && !strings.Contains(dir, string(filepath.Separator))
}

// RemoveWorkbench deletes project projectID's whole directory; a missing one
// is a no-op.
func (s Store) RemoveWorkbench(projectID int64) error {
	if err := os.RemoveAll(s.Dir(projectID)); err != nil {
		return fmt.Errorf("removing %s: %w", s.Dir(projectID), err)
	}
	return nil
}
