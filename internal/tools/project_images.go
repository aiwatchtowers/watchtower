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
			// A copy this call made goes unless a row names it; the refusal
			// is what the model needs to see, a cleanup failure is not.
			_ = in.discardUnreferenced(d, projectID)
			var rej *projectfiles.RejectError
			if errors.As(err, &rej) {
				return nil, &ValidationError{Msg: rej.Error()}
			}
			return nil, err
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

// discardUnreferenced removes the copies this call made (plus extra paths,
// e.g. images it detached) that no row of the project names — after a
// failed write, or after a detach. A cleanup failure is returned for the
// caller to report, never to undo a committed write.
func (in *ingestedImages) discardUnreferenced(d *db.DB, projectID int64, extra ...string) error {
	paths := append([]string{}, extra...)
	for _, img := range in.byPath {
		paths = append(paths, img.Path)
	}
	if len(paths) == 0 {
		return nil
	}
	keep, err := d.ProjectImagePaths(projectID)
	if err != nil {
		return err
	}
	return in.store.Discard(paths, keep)
}
