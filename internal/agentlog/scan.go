package agentlog

import (
	"bufio"
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"watchtower/internal/agentfiles"
	"watchtower/internal/agentkind"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
)

// Options configures one Scan.
type Options struct {
	ClaudeDir string // ~/.claude; tests pass a temp dir
	CodexHome string // $CODEX_HOME or ~/.codex (DefaultCodexHome); tests pass a temp dir
	// Sessions is the session adapter of an agent kind (sessionagent.For;
	// tests pass a fake): codex rollouts are found and opened only through
	// its Transcript (spec 2026-11-05 §3.5).
	Sessions func(sessionagent.Kind) (sessionagent.Adapter, bool)
	Budget   time.Duration // 0 = unbounded
	Now      func() time.Time
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
	// CodexRolloutsMissing counts the workbench's codex rows whose rollout
	// was not found; CodexOutsideWorkbench the rollouts found but not read
	// because their own session_meta cwd is not the workbench's (AGENTLOG-04).
	CodexRolloutsMissing  int `json:"codex_rollouts_missing"`
	CodexOutsideWorkbench int `json:"codex_outside_workbench"`
}

// fail records one file's read or store failure.
func (res *Result) fail(err error) {
	res.FailedFiles++
	if res.FirstFailure == nil {
		res.FirstFailure = err
	}
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
// It ends by recording the workbench's import progress (agent_log_import),
// also after a budget stop; a failure there returns the result together with
// the error, so the caller still reports the failed files.
// It only reads main (watchtower.db: workbenches, the worktree ledger,
// terminal sessions) and writes al (agentlog.db). Until agentlogdb.MoveFromMain
// completed it refuses with agentlogdb.ErrNotMoved and writes nothing.
func Scan(ctx context.Context, main *db.DB, al *agentlogdb.DB, id int64, o Options) (*Result, error) {
	moved, err := al.Moved()
	if err != nil {
		return nil, err
	}
	if !moved {
		return nil, agentlogdb.ErrNotMoved
	}
	if o.ClaudeDir == "" {
		o.ClaudeDir = DefaultClaudeDir()
	}
	if o.CodexHome == "" {
		o.CodexHome = DefaultCodexHome()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Sessions == nil {
		o.Sessions = sessionagent.For
	}
	wb, err := main.GetWorkbench(id)
	if err != nil {
		return nil, err
	}
	all, err := main.ListWorkbenches()
	if err != nil {
		return nil, err
	}
	folders := make([]string, 0, len(all))
	live := make([]int64, 0, len(all))
	for _, w := range all {
		folders = append(folders, w.FolderPath)
		live = append(live, w.ID)
	}
	res := &Result{UnknownRecords: map[string]int{}}
	if res.Adopted, err = al.AdoptAgentLogSessions(id, wb.FolderPath, live); err != nil {
		return nil, fmt.Errorf("adopting sessions: %w", err)
	}
	ledger, err := main.WorkbenchSessionWorktrees(ctx, id)
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
	codexFiles, transcripts, codexMissing, err := workbenchCodexFiles(main, id, o)
	if err != nil {
		return nil, err
	}
	res.CodexRolloutsMissing = codexMissing
	files = append(files, codexFiles...)
	deadline := time.Time{}
	if o.Budget > 0 {
		deadline = o.Now().Add(o.Budget)
	}
	present := map[string]bool{} // every listed file, read or not: a budget stop must not mark the rest missing
	for _, tf := range files {
		present[tf.Path] = true
	}
	st := store{main: main, al: al, transcripts: transcripts}
	sessions, err := scanOwnedFiles(ctx, st, files, wb, folders, roots, deadline, o.Now, res)
	if err != nil {
		return nil, err
	}
	res.Sessions = len(sessions)
	if err := markMissingFiles(al, dirs, present, o.Now(), res); err != nil {
		return nil, err
	}
	if res.Repriced, err = al.RepriceAgentLogEvents(PriceVersion, Cost); err != nil {
		return nil, fmt.Errorf("repricing: %w", err)
	}
	if err := recordImportProgress(al, id, res, o.Now()); err != nil {
		return res, fmt.Errorf("recording import progress for workbench %d: %w", id, err)
	}
	return res, nil
}

// workbenchCodexFiles lists the rollouts of the workbench's codex rows,
// each found by the codex session adapter's Transcript under AGENTLOG-04 as
// amended in ask #507 (rows of other workbenches and rollouts with no row
// are never listed, so never opened), with the Transcript that opens it by
// path, and counts the rows whose rollout was not found. They come after the
// Claude transcripts. A vanished rollout has no path to list, so it is never
// marked missing; its rows stay (AGENTLOG-03).
func workbenchCodexFiles(main *db.DB, id int64, o Options) ([]TranscriptFile, map[string]sessionagent.Transcript, int, error) {
	rows, err := main.WorkbenchCodexSessions(id)
	if err != nil || len(rows) == 0 {
		return nil, nil, 0, err
	}
	codex, ok := o.Sessions(agentkind.Codex)
	if !ok {
		return nil, nil, 0, errors.New("no codex session adapter")
	}
	var files []TranscriptFile
	var missing int
	transcripts := map[string]sessionagent.Transcript{}
	for _, row := range rows {
		tr := codex.Transcript(sessionagent.Row{SessionID: row.SessionID, TranscriptPath: row.TranscriptPath, Home: o.CodexHome})
		path, ok := tr.ImportFile()
		if !ok {
			missing++
			continue
		}
		if f, ok := agentfiles.StatTranscript(path); ok {
			f.SessionUUID, f.Agent = row.SessionID, AgentCodex
			files = append(files, f)
			transcripts[path] = tr
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files, transcripts, missing, nil
}

// recordImportProgress upserts the workbench's agent_log_import row (spec
// D6): complete once a scan got through its whole listing, failed files
// included (they are retried every scan, never awaited).
func recordImportProgress(al *agentlogdb.DB, id int64, res *Result, now time.Time) error {
	n, err := al.StoredTranscripts(id)
	if err != nil {
		return err
	}
	return al.SetImportProgress(id, !res.Incomplete, n, now)
}

// store is the scan's two handles: main is only read, al is written.
type store struct {
	main *db.DB
	al   *agentlogdb.DB
	// transcripts opens each listed codex rollout by its path: the session
	// adapter's Transcript that found it.
	transcripts map[string]sessionagent.Transcript
}

// scanOwnedFiles scans every listed transcript this workbench owns until the
// deadline or ctx ends (then res.Incomplete) and returns the owned session
// uuids.
func scanOwnedFiles(ctx context.Context, st store, files []TranscriptFile, wb *db.Workbench, folders, roots []string,
	deadline time.Time, now func() time.Time, res *Result) (map[string]bool, error) {
	owned := map[string]bool{} // session uuid → owned by this workbench
	sessions := map[string]bool{}
	stop := func() bool { return ctx.Err() != nil || (!deadline.IsZero() && now().After(deadline)) }
	for _, tf := range files {
		if res.Incomplete || stop() {
			res.Incomplete = true
			break
		}
		mine, err := ownsSession(st, tf, owned, folders, wb.FolderPath, roots)
		if errors.Is(err, errRolloutUnreadable) {
			res.fail(err) // not cached: the next scan asks again
			continue
		}
		if err != nil {
			return nil, err
		}
		if !mine {
			if tf.Agent == AgentCodex {
				res.CodexOutsideWorkbench++
			}
			continue
		}
		sessions[tf.SessionUUID] = true
		if err := scanFile(st, tf, wb, stop, res); err != nil {
			res.fail(err)
		}
	}
	return sessions, nil
}

// markMissingFiles marks known ledger files under dirs that no longer exist
// on disk (not in present) as missing.
func markMissingFiles(d *agentlogdb.DB, dirs []string, present map[string]bool, now time.Time, res *Result) error {
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
	seen := map[string]bool{strings.ToLower(agentfiles.Resolved(folder)): true}
	var out []string
	add := func(r string) {
		if k := strings.ToLower(agentfiles.Resolved(r)); r != "" && !seen[k] {
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
func ownsSession(st store, tf TranscriptFile, owned map[string]bool, folders []string, folder string, roots []string) (bool, error) {
	if v, ok := owned[tf.SessionUUID]; ok {
		return v, nil
	}
	stored, ok, err := st.al.AgentLogSessionFolder(tf.SessionUUID)
	if err != nil {
		return false, err
	}
	if ok {
		owned[tf.SessionUUID] = equalFold(stored, folder)
		return owned[tf.SessionUUID], nil
	}
	var home string
	if tf.Agent == AgentCodex {
		if home, err = codexCWD(st.transcripts[tf.Path], tf.Path, tf.SessionUUID); err != nil {
			return false, err
		}
	} else {
		home = firstCWD(tf.Path)
	}
	if r, err := filepath.EvalSymlinks(home); err == nil {
		home = r
	}
	owned[tf.SessionUUID] = home != "" && OwnerFolder(home, folders, folder, roots) != ""
	return owned[tf.SessionUUID], nil
}

// batchRows bounds one write transaction: a transcript is stored in slices of
// at most this many events plus tool results, each committed with its own
// offset compare-and-set, so the session hooks (0.5–1 s lock budgets) never
// wait behind a whole transcript.
var batchRows = 1000

// scanFile reads tf from its stored offset in slices of batchRows, commits
// each slice, and stops between slices when stop says the scan is out of
// time (res.Incomplete; the next scan resumes from the last committed slice).
func scanFile(st store, tf TranscriptFile, wb *db.Workbench, stop func() bool, res *Result) error {
	if tf.Agent == AgentCodex {
		return scanCodexFile(st, tf, wb, stop, res)
	}
	stored, err := st.al.GetAgentLogFile(tf.Path)
	if err != nil {
		return err
	}
	start, expect, unchanged := resumePoint(stored, tf)
	if unchanged {
		res.FilesSkipped++
		if tf.Subagent && tf.AgentID != "" { // the meta file can change without the transcript
			_, err := st.al.UpsertAgentSubagent(subagentRow(tf))
			return err
		}
		return nil
	}
	fh, err := os.Open(tf.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil // vanished between listing and open: the missing sweep catches it
	}
	if err != nil {
		return err
	}
	defer fh.Close()
	o := ParseOptions{Path: tf.Path, Folder: wb.FolderPath, Subagent: tf.Subagent, AgentID: tf.AgentID, MaxRows: batchRows,
		LaneBaseline: func(sid string) (bool, map[string]int64, error) { return st.al.AgentLaneBaseline(sid, tf.AgentID) }}
	if prefix := start; prefix > 0 {
		o.PriorSkills = func() ([]string, error) { return listedSkills(io.NewSectionReader(fh, 0, prefix), prefix) }
	}
	for first := true; ; first = false {
		if _, err := fh.Seek(start, io.SeekStart); err != nil {
			return err
		}
		pr, err := ParseClaude(fh, start, o)
		if err != nil {
			return err
		}
		o.KnownSkills = pr.Skills // the next slice starts where this one ended
		if pr.PriorLoaded {
			o.PriorSkills = nil // already in Skills; otherwise a later slice may still need them
		}
		next, applied, err := storeSlice(st, tf, wb, pr, start, expect)
		if err != nil {
			return err
		}
		if first {
			res.FilesScanned++
		}
		res.addSlice(pr, applied)
		if !applied || !pr.More {
			return nil // done, or another writer moved the offset and reads the rest
		}
		start, expect = next, next
		if stop() {
			res.Incomplete = true
			return nil
		}
	}
}

// storeSlice writes one parsed slice of tf with the offset compare-and-set
// and returns the new offset and whether the slice was applied. The
// sessions' terminal session ids are read from watchtower.db first, outside
// agentlog.db's write transaction.
func storeSlice(st store, tf TranscriptFile, wb *db.Workbench, pr *ParseResult, start, expect int64) (int64, bool, error) {
	f := agentlogdb.AgentLogFile{Path: tf.Path, Agent: cmp.Or(tf.Agent, AgentClaude), Size: tf.Size, MTime: tf.MTime,
		ReadOffset: start + pr.Consumed, ParserVersion: ParserVersion}
	if pr.More {
		// Not the whole file yet: no mtime, so a stop here never reads as "unchanged".
		f.Size, f.MTime = f.ReadOffset, ""
	}
	sessions := ownedSessions(pr.Sessions, tf, wb)
	if err := resolveTerminalSessions(st.main, tf.Agent, sessions); err != nil {
		return 0, false, fmt.Errorf("storing %s: %w", tf.Path, err)
	}
	b := agentlogdb.AgentLogBatch{File: f, ExpectOffset: expect, Events: pr.Events,
		ToolResults: pr.ToolResults, ContextParts: pr.ContextParts, SkillListing: pr.SkillListing, Sessions: sessions}
	if tf.Subagent && tf.AgentID != "" && hasSession(sessions, tf.SessionUUID) { // the row references its session
		b.Subagents = []agentlogdb.AgentSubagent{subagentRow(tf)}
	}
	applied, err := st.al.ApplyAgentLogBatch(b)
	if err != nil {
		return 0, false, fmt.Errorf("storing %s: %w", tf.Path, err)
	}
	return f.ReadOffset, applied, nil
}

func subagentRow(tf TranscriptFile) agentlogdb.AgentSubagent {
	return agentlogdb.AgentSubagent{SessionUUID: tf.SessionUUID, AgentID: tf.AgentID,
		AgentType: tf.AgentType, Depth: tf.Depth, Finished: tf.Finished}
}

func hasSession(sessions []agentlogdb.AgentLogSession, uuid string) bool {
	for _, s := range sessions {
		if s.SessionUUID == uuid {
			return true
		}
	}
	return false
}

// resolveTerminalSessions sets each session's TerminalSessionID to the
// terminal session of the transcript's agent (Claude, or codex for a rollout)
// that recorded it in watchtower.db, if any.
func resolveTerminalSessions(main *db.DB, agent string, sessions []agentlogdb.AgentLogSession) error {
	if len(sessions) == 0 {
		return nil
	}
	uuids := make([]string, len(sessions))
	for i, s := range sessions {
		uuids[i] = s.SessionUUID
	}
	lookup := main.ClaudeTerminalSessionIDs
	if agent == AgentCodex {
		lookup = main.CodexTerminalSessionIDs
	}
	ids, err := lookup(uuids)
	if err != nil {
		return err
	}
	for i := range sessions {
		if id, ok := ids[sessions[i].SessionUUID]; ok {
			sessions[i].TerminalSessionID = &id
		}
	}
	return nil
}

// addSlice counts one stored slice's records into the scan result.
func (res *Result) addSlice(pr *ParseResult, applied bool) {
	for k, v := range pr.Unknown {
		res.UnknownRecords[k] += v
	}
	res.LongLines += pr.LongLines
	if applied {
		res.EventsWritten += len(pr.Events)
	}
}

// resumePoint decides where to read a transcript from: the stored offset
// when the file only grew under the same parser, else 0; expect is the
// offset the ledger must still hold (-1 for a new file) and unchanged says
// the file needs no read at all.
func resumePoint(stored *agentlogdb.AgentLogFile, tf TranscriptFile) (start, expect int64, unchanged bool) {
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
func ownedSessions(parsed map[string]*agentlogdb.AgentLogSession, tf TranscriptFile, wb *db.Workbench) []agentlogdb.AgentLogSession {
	pid := wb.ID
	var out []agentlogdb.AgentLogSession
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
	for range 200 {
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

// scanCodexFile is scanFile for a codex rollout, opened with rollout.Open (a
// zstd file is decompressed in memory only; nothing is written beside it,
// AGENTLOG-05). Offsets are in the rollout's text, which compression keeps
// byte for byte: a plain file seeks to its stored offset, a compressed one
// decodes and drops the text before it, and both reread from 0 when the text
// turns out shorter than the offset (idempotent keys). The slices share one
// buffered reader, so each starts where the previous one stopped.
func scanCodexFile(st store, tf TranscriptFile, wb *db.Workbench, stop func() bool, res *Result) error {
	stored, err := st.al.GetAgentLogFile(tf.Path)
	if err != nil {
		return err
	}
	start, expect, unchanged := resumePoint(stored, tf)
	if unchanged {
		res.FilesSkipped++
		return nil
	}
	if stored != nil && stored.ParserVersion == ParserVersion && start < stored.ReadOffset {
		start = stored.ReadOffset // resumePoint compares the compressed size with a text offset
	}
	tr := st.transcripts[tf.Path]
	rc, err := openCodexAt(tr, tf.Path, start)
	if errors.Is(err, fs.ErrNotExist) {
		return nil // vanished between listing and open
	}
	if errors.Is(err, errShorterText) {
		start = 0
		rc, err = openCodexAt(tr, tf.Path, 0)
	}
	if err != nil {
		return fmt.Errorf("opening %s: %w", tf.Path, err)
	}
	defer rc.Close()
	o := ParseOptions{Path: tf.Path, Folder: wb.FolderPath, SessionUUID: tf.SessionUUID, MaxRows: batchRows}
	if start > 0 {
		if o.CodexModel, o.CodexCWD, err = st.al.CodexResumeState(tf.SessionUUID); err != nil {
			return err
		}
	}
	br := bufio.NewReaderSize(rc, 64<<10)
	for first := true; ; first = false {
		pr, err := ParseCodex(br, start, o)
		if err != nil {
			return err
		}
		if s := pr.Sessions[tf.SessionUUID]; s != nil {
			o.CodexModel = cmp.Or(s.Model, o.CodexModel)
			o.CodexCWD = cmp.Or(s.HomeCWD, o.CodexCWD)
		}
		next, applied, err := storeSlice(st, tf, wb, pr, start, expect)
		if err != nil {
			return err
		}
		if first {
			res.FilesScanned++
		}
		res.addSlice(pr, applied)
		if !applied || !pr.More {
			return nil
		}
		start, expect = next, next
		if stop() {
			res.Incomplete = true
			return nil
		}
	}
}

// errShorterText: the rollout's text ends before the stored offset.
var errShorterText = errors.New("rollout text shorter than the stored offset")

// openCodexAt opens the rollout at path through tr (the Transcript that
// found it) positioned at text offset start.
func openCodexAt(tr sessionagent.Transcript, path string, start int64) (io.ReadCloser, error) {
	if tr == nil {
		return nil, fmt.Errorf("no transcript for %s", path)
	}
	rc, compressed, err := tr.Open(path)
	if err != nil || start == 0 {
		return rc, err
	}
	if f, ok := rc.(io.Seeker); ok && !compressed {
		end, err := f.Seek(0, io.SeekEnd)
		if err == nil && end < start {
			err = errShorterText
		}
		if err == nil {
			_, err = f.Seek(start, io.SeekStart)
		}
		if err != nil {
			_ = rc.Close()
			return nil, err
		}
		return rc, nil
	}
	n, err := io.CopyN(io.Discard, rc, start)
	if err != nil {
		_ = rc.Close()
		if errors.Is(err, io.EOF) && n < start {
			return nil, errShorterText
		}
		return nil, err
	}
	return rc, nil
}

// errRolloutUnreadable: a codex rollout's session_meta could not be read, so
// its ownership is unknown; the file counts as failed and is asked again.
var errRolloutUnreadable = errors.New("codex rollout unreadable")

// codexCWD is the cwd of session id's own session_meta among the first 200
// lines of the rollout at path, or "" when there is none (a fork replays its
// parent's session_meta after its own; only the session's own counts). An
// open or read failure is errRolloutUnreadable.
func codexCWD(tr sessionagent.Transcript, path, id string) (string, error) {
	if tr == nil {
		return "", fmt.Errorf("%w: %s: no transcript", errRolloutUnreadable, path)
	}
	rc, _, err := tr.Open(path)
	if err != nil {
		return "", fmt.Errorf("%w: %s: %w", errRolloutUnreadable, path, err)
	}
	defer rc.Close()
	br := bufio.NewReaderSize(rc, 64<<10)
	for range 200 {
		raw, _, complete, err := NextLine(br, maxLineBytes)
		if !complete {
			if err != nil && !errors.Is(err, io.EOF) {
				return "", fmt.Errorf("%w: %s: %w", errRolloutUnreadable, path, err)
			}
			return "", nil
		}
		if raw == nil {
			continue
		}
		var l codexRolloutLine
		if json.Unmarshal(raw, &l) != nil || l.Type != "session_meta" {
			continue
		}
		var pl codexPayload
		if json.Unmarshal(l.Payload, &pl) == nil && pl.ID == id && pl.CWD != "" {
			return pl.CWD, nil
		}
	}
	return "", nil
}
