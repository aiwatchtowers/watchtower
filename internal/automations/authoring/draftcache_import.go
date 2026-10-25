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
// automation_draft_cache, oldest line first, each file in one transaction
// (db.ImportDraftCache), then removes the file and, once it is empty, the
// directory (#604 G2). A conversation that already has cache rows keeps
// them (a re-run after a failed removal never duplicates or reorders); the
// file of a conversation that no longer exists is removed with nothing to
// import. A file that does not parse is deleted (it is only a cache, and no
// recipe text stays outside the database), logged by name only; a file that
// cannot be read stays for the next start. It returns how many files were
// imported; a missing directory is no work.
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
		path := filepath.Join(dir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			errs = append(errs, fmt.Errorf("reading %s: %w", name, err))
			continue
		}
		lines, err := parseLegacyDraftCache(data)
		if err != nil {
			log.Printf("automation drafts: %s does not parse (%v), deleted", name, err)
			if rerr := os.Remove(path); rerr != nil {
				errs = append(errs, rerr)
			}
			continue
		}
		wrote, err := importDraftLines(d, id, lines)
		if err != nil && !errors.Is(err, db.ErrDraftCacheNoConversation) {
			errs = append(errs, fmt.Errorf("importing %s: %w", name, err))
			continue
		}
		if err := os.Remove(path); err != nil {
			errs = append(errs, err)
			continue
		}
		if wrote {
			imported++
		}
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

// parseLegacyDraftCache returns the file's entries in order, each checked to
// decode as a DraftCacheEntry.
func parseLegacyDraftCache(data []byte) ([]DraftCacheEntry, error) {
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

// importDraftLines writes entries as conversation id's cache, oldest first,
// in one transaction; false when the conversation already had rows.
func importDraftLines(d *db.DB, id int64, entries []DraftCacheEntry) (bool, error) {
	rows := make([]db.DraftCacheImport, 0, len(entries))
	for _, e := range entries {
		line, err := json.Marshal(e)
		if err != nil {
			return false, err
		}
		at, err := time.Parse(time.RFC3339, e.At)
		if err != nil {
			at = time.Now()
		}
		rows = append(rows, db.DraftCacheImport{EntryJSON: string(line), At: at})
	}
	return d.ImportDraftCache(id, rows, draftCacheKeep)
}
