package authoring

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// ImportLegacyDraftCache moves the draft caches an older version kept in
// <workspace>/automation-drafts/<conversation id>.jsonl into
// automation_draft_cache, oldest line first, then removes each imported
// file and, once it is empty, the directory (#604 G2). A file that does not
// parse is kept and logged by name only (its lines hold recipe text). It
// returns how many files were imported; a missing directory is no work.
func ImportLegacyDraftCache(d *db.DB, workspaceDir string) (int, error) {
	dir := filepath.Join(workspaceDir, DraftCacheDir)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("listing %s: %w", DraftCacheDir, err)
	}
	imported := 0
	var errs []error
	for _, e := range entries {
		name := e.Name()
		id, ok := legacyDraftCacheID(e)
		if !ok {
			continue
		}
		lines, err := readLegacyDraftCache(filepath.Join(dir, name))
		if err != nil {
			log.Printf("automation drafts: keeping %s: %v", name, err)
			continue
		}
		if err := importDraftLines(d, id, lines); err != nil {
			errs = append(errs, fmt.Errorf("importing %s: %w", name, err))
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil {
			errs = append(errs, err)
			continue
		}
		imported++
	}
	if rest, err := os.ReadDir(dir); err == nil && len(rest) == 0 {
		_ = os.Remove(dir) // an empty leftover; a failure leaves it for the next start
	}
	return imported, errors.Join(errs...)
}

// legacyDraftCacheID is the conversation id a cache file is named after.
func legacyDraftCacheID(e fs.DirEntry) (int64, bool) {
	stem, ok := strings.CutSuffix(e.Name(), ".jsonl")
	if !ok || !e.Type().IsRegular() {
		return 0, false
	}
	id, err := strconv.ParseInt(stem, 10, 64)
	return id, err == nil && id > 0
}

// readLegacyDraftCache returns the file's entries in order, each checked to
// decode as a DraftCacheEntry.
func readLegacyDraftCache(path string) ([]DraftCacheEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []DraftCacheEntry
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 0, 64*1024), len(data)+1)
	for n := 1; sc.Scan(); n++ {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var entry DraftCacheEntry
		if err := json.Unmarshal(line, &entry); err != nil {
			return nil, fmt.Errorf("line %d does not parse", n)
		}
		out = append(out, entry)
	}
	return out, sc.Err()
}

// importDraftLines appends entries to conversation id's cache, oldest first.
func importDraftLines(d *db.DB, id int64, entries []DraftCacheEntry) error {
	for _, e := range entries {
		line, err := json.Marshal(e)
		if err != nil {
			return err
		}
		at, err := time.Parse(time.RFC3339, e.At)
		if err != nil {
			at = time.Now()
		}
		if err := d.AppendDraftCache(id, string(line), at, draftCacheKeep); err != nil {
			return err
		}
	}
	return nil
}
