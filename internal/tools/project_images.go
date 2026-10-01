package tools

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
)

// maxImagesPerCall caps the image paths one target item or update names;
// db.MaxTargetImages caps what a target carries in all.
const maxImagesPerCall = 10

// validateImagePaths refuses, before any row is written, more than
// maxImagesPerCall paths or a path that is not a small PNG/JPEG/GIF/WebP
// file (projectfiles.Check, read-only). Ingest checks the file again when it
// copies it in.
func validateImagePaths(field string, paths []string) error {
	if len(paths) > maxImagesPerCall {
		return &ValidationError{Msg: fmt.Sprintf("%s holds at most %d paths", field, maxImagesPerCall)}
	}
	for _, p := range paths {
		if err := projectfiles.Check(strings.TrimSpace(p)); err != nil {
			return &ValidationError{Msg: err.Error()}
		}
	}
	return nil
}

// ingestedImages is what one call copied into the project's directory, by
// the argument path it came from.
type ingestedImages struct {
	store  projectfiles.Store
	byPath map[string]projectfiles.Image
}

// ingestImages copies every path into project projectID's directory before
// any row is written, so a refused file fails the whole call with nothing
// on the board. A copy already there (same content) is reused.
func ingestImages(d *db.DB, store projectfiles.Store, projectID int64, paths []string) (*ingestedImages, error) {
	in := &ingestedImages{store: store, byPath: map[string]projectfiles.Image{}}
	for _, p := range paths {
		p = strings.TrimSpace(p)
		if _, ok := in.byPath[p]; ok {
			continue
		}
		img, err := store.Ingest(projectID, p)
		if err != nil {
			var rej *projectfiles.RejectError
			if errors.As(err, &rej) {
				err = &ValidationError{Msg: rej.Error()}
			}
			return nil, in.undo(d, projectID, err)
		}
		in.byPath[p] = img
	}
	return in, nil
}

// attach writes the rows attaching paths (already ingested) to target
// targetID inside tx.
func (in *ingestedImages) attach(tx *sql.Tx, projectID, targetID int64, paths []string) error {
	for _, p := range paths {
		img := in.byPath[strings.TrimSpace(p)]
		_, err := db.AddProjectTargetImageTx(tx, db.ProjectTargetImage{
			ProjectID: projectID, TargetID: targetID, FileName: img.FileName,
			MIME: img.MIME, Size: img.Size, SHA256: img.SHA256, Path: img.Path,
		})
		if errors.Is(err, db.ErrTooManyImages) {
			return &ValidationError{Msg: err.Error(), Err: err}
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// undo removes, after the write failed with writeErr, the copies this call
// created that no row names — never a copy it merely reused, which another
// session may be attaching right now. It returns the error to report:
// writeErr, its message extended (and its kind kept) when the cleanup failed
// too, so a leftover copy is never silent.
func (in *ingestedImages) undo(d *db.DB, projectID int64, writeErr error) error {
	var created []string
	for _, img := range in.byPath {
		if img.Created {
			created = append(created, img.Path)
		}
	}
	cerr := discardUnreferenced(d, in.store, projectID, created)
	if cerr == nil {
		return writeErr
	}
	note := "; also, copied image files could not all be removed: " + cerr.Error()
	var verr *ValidationError
	if errors.As(writeErr, &verr) {
		return &ValidationError{Msg: verr.Msg + note, Err: verr.Err}
	}
	return fmt.Errorf("%w%s", writeErr, note)
}

// discardUnreferenced removes those of paths that no row of the project
// names — the copies of detached images, or of a failed write.
func discardUnreferenced(d *db.DB, store projectfiles.Store, projectID int64, paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	keep, err := d.ProjectImagePaths(projectID)
	if err != nil {
		return err
	}
	return store.Discard(paths, keep)
}
