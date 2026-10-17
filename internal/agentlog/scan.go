package agentlog

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Options configures one Scan.
type Options struct {
	ClaudeDir string        // ~/.claude; tests pass a temp dir
	Budget    time.Duration // 0 = unbounded
	Now       func() time.Time
}

// Result reports what one Scan did.
type Result struct {
	FilesScanned   int            `json:"files_scanned"`
	FilesSkipped   int            `json:"files_skipped"`
	EventsWritten  int            `json:"events_written"`
	Sessions       int            `json:"sessions"`
	UnknownRecords map[string]int `json:"unknown_records"`
	LongLines      int            `json:"long_lines"`
	MissingFiles   int            `json:"missing_files"`
	Repriced       int            `json:"repriced"`
	Adopted        int64          `json:"adopted"`
	Incomplete     bool           `json:"incomplete"`
	FailedFiles    int            `json:"failed_files"` // files whose read or store failed; retried next scan
	FirstFailure   error          `json:"-"`            // the first of those failures, for the daemon log
}

// DefaultClaudeDir is ~/.claude. Like cmd's defaultTerminalClaudeDir it never
// reads CLAUDE_CONFIG_DIR (dual path, v1 limit).
func DefaultClaudeDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude")
}

// Scan brings workbench id's analytics up to date: adopt orphaned sessions,
// read each candidate transcript from its stored offset, mark vanished files,
// reprice old rows. Safe to run concurrently with itself (CAS + idempotent keys).
// One file that fails to read or store is counted in FailedFiles and the scan
// goes on; Scan returns an error only for setup and bookkeeping failures.
func Scan(ctx context.Context, d *db.DB, id int64, o Options) (*Result, error) {
	if o.ClaudeDir == "" {
		o.ClaudeDir = DefaultClaudeDir()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	wb, err := d.GetWorkbench(id)
	if err != nil {
		return nil, err
	}
	res := &Result{UnknownRecords: map[string]int{}}
	if res.Adopted, err = d.AdoptAgentLogSessions(id, wb.FolderPath); err != nil {
		return nil, fmt.Errorf("adopting sessions: %w", err)
	}
	folders, err := allWorkbenchFolders(d)
	if err != nil {
		return nil, err
	}
	ledger, err := d.WorkbenchSessionWorktrees(ctx, id)
	if err != nil {
		return nil, err
	}
	roots := worktreeRoots(wb.FolderPath, WorktreeRoots(ctx, wb.FolderPath), ledger)
	dirs, err := CandidateDirs(filepath.Join(o.ClaudeDir, "projects"), append([]string{wb.FolderPath}, roots...))
	if err != nil {
		return nil, fmt.Errorf("listing transcript directories: %w", err)
	}
	files, err := ListTranscripts(dirs)
	if err != nil {
		return nil, err
	}
	deadline := time.Time{}
	if o.Budget > 0 {
		deadline = o.Now().Add(o.Budget)
	}
	present := map[string]bool{} // every listed file, read or not: a budget stop must not mark the rest missing
	for _, tf := range files {
		present[tf.Path] = true
	}
	sessions, err := scanOwnedFiles(ctx, d, files, wb, folders, roots, deadline, o.Now, res)
	if err != nil {
		return nil, err
	}
	res.Sessions = len(sessions)
	if err := markMissingFiles(d, dirs, present, o.Now(), res); err != nil {
		return nil, err
	}
	if res.Repriced, err = d.RepriceAgentLogEvents(PriceVersion, Cost); err != nil {
		return nil, fmt.Errorf("repricing: %w", err)
	}
	return res, nil
}

// scanOwnedFiles scans every listed transcript this workbench owns until the
// deadline or ctx ends (then res.Incomplete) and returns the owned session
// uuids.
func scanOwnedFiles(ctx context.Context, d *db.DB, files []TranscriptFile, wb *db.Workbench, folders, roots []string,
	deadline time.Time, now func() time.Time, res *Result) (map[string]bool, error) {
	owned := map[string]bool{} // session uuid → owned by this workbench
	sessions := map[string]bool{}
	for _, tf := range files {
		if ctx.Err() != nil || (!deadline.IsZero() && now().After(deadline)) {
			res.Incomplete = true
			break
		}
		mine, err := ownsSession(d, tf, owned, folders, wb.FolderPath, roots)
		if err != nil {
			return nil, err
		}
		if !mine {
			continue
		}
		sessions[tf.SessionUUID] = true
		if err := scanFile(d, tf, wb, res); err != nil {
			res.FailedFiles++
			if res.FirstFailure == nil {
				res.FirstFailure = err
			}
		}
	}
	return sessions, nil
}

// allWorkbenchFolders lists every workbench's folder path.
func allWorkbenchFolders(d *db.DB) ([]string, error) {
	all, err := d.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	folders := make([]string, 0, len(all))
	for _, w := range all {
		folders = append(folders, w.FolderPath)
	}
	return folders, nil
}

// markMissingFiles marks known ledger files under dirs that no longer exist
// on disk (not in present) as missing.
func markMissingFiles(d *db.DB, dirs []string, present map[string]bool, now time.Time, res *Result) error {
	known, err := d.AgentLogFilesUnder(dirs)
	if err != nil {
		return err
	}
	for _, f := range known {
		if !present[f.Path] && f.MissingAt == "" {
			if err := d.MarkAgentLogFileMissing(f.Path, now.UTC().Format(time.RFC3339)); err != nil {
				return err
			}
			res.MissingFiles++
		}
	}
	return nil
}

// worktreeRoots merges git's live worktrees with the roots the workbench's
// sessions recorded in terminal_session_worktrees (a removed worktree leaves
// git's list but keeps its transcripts), without the folder or duplicates.
func worktreeRoots(folder string, git []string, ledger map[string][]int64) []string {
	seen := map[string]bool{strings.ToLower(resolved(folder)): true}
	var out []string
	add := func(r string) {
		if k := strings.ToLower(resolved(r)); r != "" && !seen[k] {
			seen[k] = true
			out = append(out, r)
		}
	}
	for _, r := range git {
		add(r)
	}
	ledgerRoots := make([]string, 0, len(ledger))
	for r := range ledger {
		ledgerRoots = append(ledgerRoots, r)
	}
	sort.Strings(ledgerRoots)
	for _, r := range ledgerRoots {
		add(r)
	}
	return out
}

// ownsSession decides once per session: a stored session keeps the folder it
// was matched to; a new one is matched by the home cwd of its main file.
func ownsSession(d *db.DB, tf TranscriptFile, owned map[string]bool, folders []string, folder string, roots []string) (bool, error) {
	if v, ok := owned[tf.SessionUUID]; ok {
		return v, nil
	}
	stored, ok, err := d.AgentLogSessionFolder(tf.SessionUUID)
	if err != nil {
		return false, err
	}
	if ok {
		owned[tf.SessionUUID] = equalFold(stored, folder)
		return owned[tf.SessionUUID], nil
	}
	home := firstCWD(tf.Path)
	if r, err := filepath.EvalSymlinks(home); err == nil {
		home = r
	}
	owned[tf.SessionUUID] = home != "" && OwnerFolder(home, folders, folder, roots) != ""
	return owned[tf.SessionUUID], nil
}

func scanFile(d *db.DB, tf TranscriptFile, wb *db.Workbench, res *Result) error {
	stored, err := d.GetAgentLogFile(tf.Path)
	if err != nil {
		return err
	}
	start, expect, unchanged := resumePoint(stored, tf)
	if unchanged {
		res.FilesSkipped++
		return nil
	}
	fh, err := os.Open(tf.Path)
	if err != nil {
		return nil // vanished between listing and open: the missing sweep catches it
	}
	defer fh.Close()
	var known []string
	if start > 0 {
		if known, err = listedSkills(fh, start); err != nil {
			return fmt.Errorf("reading %s: %w", tf.Path, err)
		}
	}
	if _, err := fh.Seek(start, io.SeekStart); err != nil {
		return err
	}
	pr, err := ParseClaude(fh, start, ParseOptions{Path: tf.Path, Folder: wb.FolderPath, Subagent: tf.Subagent,
		AgentID: tf.AgentID, KnownSkills: known})
	if err != nil {
		return err
	}
	b := db.AgentLogBatch{File: db.AgentLogFile{Path: tf.Path, Agent: "claude", Size: tf.Size, MTime: tf.MTime,
		ReadOffset: start + pr.Consumed, ParserVersion: ParserVersion}, ExpectOffset: expect,
		Events: pr.Events, ToolResults: pr.ToolResults}
	b.Sessions = ownedSessions(pr.Sessions, tf, wb)
	applied, err := d.ApplyAgentLogBatch(b)
	if err != nil {
		return fmt.Errorf("storing %s: %w", tf.Path, err)
	}
	res.FilesScanned++
	if applied {
		res.EventsWritten += len(pr.Events)
	}
	for k, v := range pr.Unknown {
		res.UnknownRecords[k] += v
	}
	res.LongLines += pr.LongLines
	return nil
}

// resumePoint decides where to read a transcript from: the stored offset
// when the file only grew under the same parser, else 0; expect is the
// offset the ledger must still hold (-1 for a new file) and unchanged says
// the file needs no read at all.
func resumePoint(stored *db.AgentLogFile, tf TranscriptFile) (start, expect int64, unchanged bool) {
	if stored == nil {
		return 0, -1, false
	}
	if stored.MissingAt == "" && stored.Size == tf.Size && stored.MTime == tf.MTime && stored.ParserVersion == ParserVersion {
		return 0, stored.ReadOffset, true
	}
	if tf.Size >= stored.ReadOffset && stored.ParserVersion == ParserVersion {
		start = stored.ReadOffset
	}
	return start, stored.ReadOffset, false
}

// ownedSessions stamps the parsed sessions with the workbench's project id
// and folder (and a subagent's parent transcript path).
func ownedSessions(parsed map[string]*db.AgentLogSession, tf TranscriptFile, wb *db.Workbench) []db.AgentLogSession {
	pid := wb.ID
	var out []db.AgentLogSession
	for _, s := range parsed {
		s.ProjectID, s.FolderPath = &pid, wb.FolderPath
		if tf.Subagent {
			s.SourcePath = filepath.Dir(filepath.Dir(tf.Path)) + ".jsonl"
		}
		out = append(out, *s)
	}
	return out
}

// listedSkills returns the names of every skill_listing attachment in the
// first limit bytes of r: the listing usually sits before an incremental
// read's offset, and slash-skill detection needs it.
func listedSkills(r io.Reader, limit int64) ([]string, error) {
	br := bufio.NewReaderSize(io.LimitReader(r, limit), 64<<10)
	seen := map[string]bool{}
	var out []string
	for {
		raw, _, complete, err := NextLine(br, maxLineBytes)
		if !complete {
			if err != nil && !errors.Is(err, io.EOF) {
				return nil, err
			}
			return out, nil
		}
		if raw == nil || !bytes.Contains(raw, []byte("skill_listing")) {
			continue
		}
		var rec struct {
			Type       string `json:"type"`
			Attachment struct {
				Type  string   `json:"type"`
				Names []string `json:"names"`
			} `json:"attachment"`
		}
		if json.Unmarshal(raw, &rec) != nil || rec.Type != "attachment" || rec.Attachment.Type != "skill_listing" {
			continue
		}
		for _, n := range rec.Attachment.Names {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
	}
}

// firstCWD returns the first non-empty cwd among the first 200 lines of the
// transcript at path, or "".
func firstCWD(path string) string {
	fh, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer fh.Close()
	br := bufio.NewReaderSize(fh, 64<<10)
	for i := 0; i < 200; i++ {
		raw, _, complete, _ := NextLine(br, maxLineBytes)
		if !complete {
			return ""
		}
		if raw == nil {
			continue
		}
		var rec struct {
			CWD string `json:"cwd"`
		}
		if json.Unmarshal(raw, &rec) == nil && rec.CWD != "" {
			return rec.CWD
		}
	}
	return ""
}

func equalFold(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}
