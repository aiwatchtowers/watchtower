package agentlog

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
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
	all, err := d.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	folders := make([]string, 0, len(all))
	for _, w := range all {
		folders = append(folders, w.FolderPath)
	}
	roots := WorktreeRoots(wb.FolderPath)
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
	sessions := map[string]bool{}
	present := map[string]bool{} // every listed file, read or not: a budget stop must not mark the rest missing
	for _, tf := range files {
		present[tf.Path] = true
	}
	owned := map[string]bool{} // session uuid → owned by this workbench
	for _, tf := range files {
		if ctx.Err() != nil || (!deadline.IsZero() && o.Now().After(deadline)) {
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
			return nil, err
		}
	}
	res.Sessions = len(sessions)
	known, err := d.AgentLogFilesUnder(dirs)
	if err != nil {
		return nil, err
	}
	for _, f := range known {
		if !present[f.Path] && f.MissingAt == "" {
			if err := d.MarkAgentLogFileMissing(f.Path, o.Now().UTC().Format(time.RFC3339)); err != nil {
				return nil, err
			}
			res.MissingFiles++
		}
	}
	if res.Repriced, err = d.RepriceAgentLogEvents(PriceVersion, Cost); err != nil {
		return nil, fmt.Errorf("repricing: %w", err)
	}
	return res, nil
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
	start, expect := int64(0), int64(-1)
	if stored != nil {
		expect = stored.ReadOffset
		if stored.MissingAt == "" && stored.Size == tf.Size && stored.MTime == tf.MTime && stored.ParserVersion == ParserVersion {
			res.FilesSkipped++
			return nil
		}
		if tf.Size >= stored.ReadOffset && stored.ParserVersion == ParserVersion {
			start = stored.ReadOffset
		}
	}
	fh, err := os.Open(tf.Path)
	if err != nil {
		return nil // vanished between listing and open: the missing sweep catches it
	}
	defer fh.Close()
	if _, err := fh.Seek(start, io.SeekStart); err != nil {
		return err
	}
	pr, err := ParseClaude(fh, start, ParseOptions{Path: tf.Path, Folder: wb.FolderPath, Subagent: tf.Subagent, AgentID: tf.AgentID})
	if err != nil {
		return err
	}
	b := db.AgentLogBatch{File: db.AgentLogFile{Path: tf.Path, Agent: "claude", Size: tf.Size, MTime: tf.MTime,
		ReadOffset: start + pr.Consumed, ParserVersion: ParserVersion}, ExpectOffset: expect,
		Events: pr.Events, ToolResults: pr.ToolResults}
	pid := wb.ID
	for _, s := range pr.Sessions {
		s.ProjectID, s.FolderPath = &pid, wb.FolderPath
		if tf.Subagent {
			s.SourcePath = filepath.Dir(filepath.Dir(tf.Path)) + ".jsonl"
		}
		b.Sessions = append(b.Sessions, *s)
	}
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
		raw, _, complete, _ := nextLine(br, maxLineBytes)
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
