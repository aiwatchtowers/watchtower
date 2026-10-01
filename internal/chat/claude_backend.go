package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"watchtower/internal/claude"
)

// ClaudeOptions configures the warm Claude backend.
type ClaudeOptions struct {
	Binary          string // claude executable; "" = claude.FindBinary("")
	Model           string // --model; "" = the CLI default
	ResumeSessionID string // --resume on the first spawn; "" = fresh session
	SystemPrompt    string // written to a 0600 file, passed as --system-prompt-file
	MCPConfig       string // mcp-config JSON, written to a 0600 file; "" = none
	AllowedTools    string // --allowedTools
	DisallowedTools string // --disallowedTools
	// WorkDir is the child's working directory; "" = NeutralWorkDir(). It
	// must hold no CLAUDE.md: claude loads project instructions from its cwd
	// (and its parents) into the session. It must also be stable across
	// spawns — claude files sessions per cwd, so --resume only finds a
	// session started from the same directory.
	WorkDir string
	Env     []string // extra environment (tests)
	// Replay renders the history before turnID (BuildReplaySteps output) for a
	// fresh provider session that is not continuous with the branch.
	Replay func(turnID string) (string, error)
	// ProjectAttachments are the project's binary files. They are sent ahead
	// of the owner's own attachments on the first turn of every fresh
	// provider session — never on a --resume, whose history already holds
	// them (spec §6.1).
	ProjectAttachments []Attachment
	// Warn receives the name of a project file skipped at turn time
	// (default os.Stderr).
	Warn           io.Writer
	InterruptGrace time.Duration // default 5 s: kill if no result after an interrupt
	CloseGrace     time.Duration // default 2 s per step: stdin EOF → SIGTERM → SIGKILL
}

// claudeProc is one running `claude -p --input-format stream-json` child.
type claudeProc struct {
	cmd       *exec.Cmd
	pgid      int
	stdin     io.WriteCloser
	writeMu   sync.Mutex
	events    chan Event
	exited    chan struct{} // closed once cmd.Wait returns
	outDone   chan struct{} // closed when stdout reaches EOF
	errDone   chan struct{} // closed when stderr reaches EOF
	stop      chan struct{} // closed to release a reader blocked on events
	stopOnce  sync.Once
	stderr    *boundedBuffer
	resumed   bool
	gotResult atomic.Bool
	lostMsg   atomic.Value // string: the session_lost error the child reported on stdout
}

// rejectedResume returns the --resume rejection an exited child died of
// before any turn result, or "" when it died of anything else. Only called
// once the child has exited.
func (p *claudeProc) rejectedResume() string {
	if !p.resumed {
		return ""
	}
	waitClosed(p.outDone, 500*time.Millisecond)
	if m, _ := p.lostMsg.Load().(string); m != "" {
		return m
	}
	if p.gotResult.Load() {
		return ""
	}
	waitClosed(p.errDone, 500*time.Millisecond)
	msg := strings.TrimSpace(p.stderr.String())
	if code, _ := ClassifyClaudeError(msg); code == CodeSessionLost {
		return msg
	}
	return ""
}

// resumeRejectedError is ensureProcLocked's refusal to respawn a --resume the
// CLI already rejected: Turn treats it as outcomeLost and retries fresh, with
// the replayed history and the project files.
type resumeRejectedError struct{ msg string }

func (e *resumeRejectedError) Error() string { return e.msg }

func (p *claudeProc) write(b []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_, err := p.stdin.Write(b)
	return err
}

// closeStdin closes the child's stdin without taking writeMu: a write blocked
// on a child that stopped reading must not block Close. The pipe is
// pollable, so closing it fails the pending write instead of waiting on it.
func (p *claudeProc) closeStdin() {
	_ = p.stdin.Close()
}

type claudeBackend struct {
	opts       ClaudeOptions
	tr         *ClaudeTranslator
	promptFile string
	mcpFile    string
	curTurn    atomic.Value // string: the running turn id (read by the translator)
	active     atomic.Bool  // a Turn is in flight
	closeOnce  sync.Once

	mu        sync.Mutex
	proc      *claudeProc
	resume    string // session id the next spawn resumes ("" = fresh)
	cancelled bool   // Cancel arrived for the turn in flight (reset when Turn returns)
	closed    bool   // Close ran: nothing may spawn again
	inFlight  bool   // this turn's message reached the child (reset when Turn returns)

	// projectPending is true until a turn of the current fresh provider
	// session carrying the project files ends with turn_done. Touched only
	// by Start and the (single-flight) Turn goroutine.
	projectPending bool
}

// errBackendClosed ends a turn that raced with Close: after Close no child
// may be spawned, or it would outlive the session unreaped.
var errBackendClosed = errors.New("the chat session is closed")

// NewClaudeBackend returns a backend that keeps one warm claude process for
// the conversation: turns go to its stdin as stream-json user messages, its
// stream-json stdout is translated to protocol v2.
func NewClaudeBackend(opts ClaudeOptions) Backend {
	if opts.Binary == "" {
		opts.Binary = claude.FindBinary("")
	}
	if opts.InterruptGrace <= 0 {
		opts.InterruptGrace = 5 * time.Second
	}
	if opts.CloseGrace <= 0 {
		opts.CloseGrace = 2 * time.Second
	}
	if opts.Warn == nil {
		opts.Warn = os.Stderr
	}
	if opts.WorkDir == "" {
		opts.WorkDir = NeutralWorkDir()
	}
	b := &claudeBackend{opts: opts, resume: opts.ResumeSessionID}
	b.curTurn.Store("")
	b.tr = NewClaudeTranslator(func() string { s, _ := b.curTurn.Load().(string); return s })
	return b
}

// claudeArgs builds the child's argv. It never carries content (CHAT-04): the
// system prompt and MCP config are file paths, the owner's text goes to stdin.
func claudeArgs(o ClaudeOptions, promptFile, mcpFile, resume string) []string {
	args := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--include-partial-messages", "--verbose",
		// Skip user-level settings: their plugins/hooks probe ~/Desktop and
		// ~/Documents at startup and trigger TCC prompts (see internal/ai).
		"--setting-sources", "project,local",
		// Only the servers in --mcp-config (watchtower + Quick Connections):
		// never the owner's claude.ai connectors or other auto-loaded servers.
		"--strict-mcp-config"}
	if o.Model != "" {
		args = append(args, "--model", o.Model)
	}
	if mcpFile != "" {
		args = append(args, "--mcp-config", mcpFile)
	}
	if o.AllowedTools != "" {
		args = append(args, "--allowedTools", o.AllowedTools)
	}
	if o.DisallowedTools != "" {
		args = append(args, "--disallowedTools", o.DisallowedTools)
	}
	if resume != "" {
		// A resumed session reuses the prompt recorded with it (spec §1.3).
		args = append(args, "--resume", resume)
	} else {
		args = append(args, "--system-prompt-file", promptFile)
	}
	return args
}

// Start writes the prompt/MCP files and spawns the warm process.
func (b *claudeBackend) Start(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var err error
	if b.promptFile, err = writePrivateTemp("wt-chat-prompt-*.txt", b.opts.SystemPrompt); err != nil {
		return "", fmt.Errorf("writing system prompt file: %w", err)
	}
	if b.opts.MCPConfig != "" {
		if b.mcpFile, err = writePrivateTemp("wt-chat-mcp-*.json", b.opts.MCPConfig); err != nil {
			return "", fmt.Errorf("writing mcp config file: %w", err)
		}
	}
	b.projectPending = initialProjectPending(b.opts)
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, err := b.spawnLocked(); err != nil {
		return "", err
	}
	return b.resume, nil
}

// initialProjectPending reports whether the first turn of a newly started
// child must carry the project files.
func initialProjectPending(opts ClaudeOptions) bool {
	return opts.ResumeSessionID == "" && len(opts.ProjectAttachments) > 0
}

// markFreshSession is called wherever the backend starts a child WITHOUT
// --resume after Start (the replay restart, the session_lost retry, a respawn
// of a child that died before reporting a session id).
func (b *claudeBackend) markFreshSession() {
	b.projectPending = len(b.opts.ProjectAttachments) > 0
}

// projectSent clears the pending flag once the turn that carried the
// project files ended with turn_done — with whatever files were still
// loadable, so a skipped file is never retried. A turn that failed keeps the
// flag: the provider may have rejected the whole request, files included.
func (b *claudeBackend) projectSent() { b.projectPending = false }

// projectBlocks is the project files' content blocks for this turn: nil
// unless it opens a fresh provider session. Each file is read now; one that
// is gone or no longer valid (removed on the project page after the session
// started), or that no longer fits in budget — what the per-message encoded
// cap leaves after the owner's own files — is skipped and named on Warn: a
// project file never fails the turn, unlike the owner's own attachments.
func (b *claudeBackend) projectBlocks(budget int64) []json.RawMessage {
	if !b.projectPending {
		return nil
	}
	out := make([]json.RawMessage, 0, len(b.opts.ProjectAttachments))
	for _, a := range b.opts.ProjectAttachments {
		l, err := loadAttachment(a, false)
		if err == nil && l.encodedSize() > budget {
			err = fmt.Errorf("over the %d MB one message carries", MaxTurnAttachmentEncodedBytes>>20)
		}
		var blk json.RawMessage
		if err == nil {
			blk, err = l.block()
		}
		if err != nil {
			fmt.Fprintf(b.warn(), "chat project file %q skipped: %v\n", a.Name, err)
			continue
		}
		budget -= l.encodedSize()
		out = append(out, blk)
	}
	return out
}

func (b *claudeBackend) warn() io.Writer {
	if b.opts.Warn == nil {
		return io.Discard
	}
	return b.opts.Warn
}

func (b *claudeBackend) spawnLocked() (*claudeProc, error) {
	cmd := exec.Command(b.opts.Binary, claudeArgs(b.opts, b.promptFile, b.mcpFile, b.resume)...)
	// A TCC-neutral, empty cwd: never inherit one inside ~/Documents or
	// ~/Desktop, and never one holding a project CLAUDE.md (see WorkDir).
	cmd.Dir = b.workDir()
	cmd.Env = append(append(os.Environ(), "PATH="+claude.RichPATH()), b.opts.Env...)
	// Own process group, so Close can reap the MCP servers claude spawns.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("claude stdin: %w", err)
	}
	// os.Pipe (not StdoutPipe): Wait must not depend on stdout EOF, which a
	// grandchild holding the pipe would delay.
	outR, outW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("claude stdout: %w", err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		return nil, fmt.Errorf("claude stderr: %w", err)
	}
	cmd.Stdout, cmd.Stderr = outW, errW
	if err := cmd.Start(); err != nil {
		outR.Close()
		outW.Close()
		errR.Close()
		errW.Close()
		return nil, fmt.Errorf("starting claude: %w", err)
	}
	outW.Close()
	errW.Close()

	p := &claudeProc{
		cmd: cmd, pgid: cmd.Process.Pid, stdin: stdin,
		events: make(chan Event, 256), exited: make(chan struct{}), outDone: make(chan struct{}),
		errDone: make(chan struct{}), stop: make(chan struct{}),
		stderr: &boundedBuffer{limit: 64 << 10}, resumed: b.resume != "",
	}
	go func() {
		_ = cmd.Wait()
		close(p.exited)
	}()
	go func() {
		_, _ = io.Copy(p.stderr, errR)
		errR.Close()
		close(p.errDone)
	}()
	go b.read(p, outR)
	b.proc = p
	return p, nil
}

// read translates the child's stdout into events on p.events.
func (b *claudeBackend) read(p *claudeProc, r *os.File) {
	defer close(p.outDone)
	defer r.Close()
	sc := bufio.NewScanner(r)
	// Tool results arrive as one line each; allow multi-megabyte lines.
	sc.Buffer(make([]byte, 0, 64<<10), 64<<20)
	for sc.Scan() {
		evs, sid, err := b.tr.feed(sc.Bytes())
		if err != nil {
			continue // non-JSON noise on stdout is not a protocol event
		}
		if sid != "" {
			b.noteSessionID(p, sid)
		}
		for _, e := range evs {
			if isTerminal(e) {
				p.gotResult.Store(true)
			}
			if e.Type == EventError && e.Code == CodeSessionLost {
				p.lostMsg.Store(e.Message)
			}
			select {
			case p.events <- e:
			case <-p.stop:
				return
			}
		}
	}
}

// noteSessionID makes the session id the live child reports (its init line
// already carries it) the one the next spawn resumes. Without it a fresh
// child killed mid-turn (a cancel past InterruptGrace) left resume empty, and
// the next turn — sent without replay, as the app counts the stopped turn as
// seen — opened a blank session with no history. A replaced child's late
// lines are ignored: restartFresh has already cleared resume for the new one.
func (b *claudeBackend) noteSessionID(p *claudeProc, sid string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.proc == p {
		b.resume = sid
	}
}

type outcomeKind int

const (
	outcomeDone outcomeKind = iota
	outcomeExited
	outcomeLost
	outcomeContext
)

type outcome struct {
	kind   outcomeKind
	msg    string
	failed bool // outcomeDone whose terminal event was an error
}

// Turn sends one owner message to the warm process and relays its events.
func (b *claudeBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	// A cancel may land before this turn reaches the child; it stays recorded
	// until the turn returns, so it is never lost nor carried to the next turn.
	defer func() {
		b.mu.Lock()
		b.cancelled, b.inFlight = false, false
		b.mu.Unlock()
	}()
	b.curTurn.Store(c.TurnID)
	b.tr.clearInterrupted()
	b.active.Store(true)
	defer b.active.Store(false)

	fresh := c.Replay
	if fresh {
		b.restartFresh()
	}
	for attempt := 0; ; attempt++ {
		out, err := b.attemptTurn(ctx, c, fresh, emit)
		if err != nil {
			return err
		}
		switch out.kind {
		case outcomeDone:
			return nil
		case outcomeContext:
			return ctx.Err()
		case outcomeLost:
			if attempt == 0 {
				fresh = true
				b.restartFresh()
				continue
			}
			emit(errorEvent(c.TurnID, CodeSessionLost, out.msg, false))
			return nil
		default:
			emit(b.exitedTerminal(c.TurnID, out.msg))
			return nil
		}
	}
}

// attemptTurn sends one try of the turn (fresh = prefixed with the replayed
// history) and relays its events until an outcome. A child whose --resume was
// already rejected before this turn is outcomeLost without a respawn.
func (b *claudeBackend) attemptTurn(ctx context.Context, c Command, fresh bool, emit func(Event)) (outcome, error) {
	text := c.Text
	if fresh {
		prefix, err := b.replayText(c.TurnID)
		if err != nil {
			return outcome{}, fmt.Errorf("building the replay: %w", err)
		}
		text = prefix + c.Text
	}
	// A rejected attachment (*AttachmentError) returns here, before
	// anything reaches the child's stdin (CHAT-04): the session maps it
	// to attachment_unsupported via fallbackTerminal. Project files are
	// lenient (projectBlocks) and only get what the owner's files leave
	// of the per-message cap; only the owner's own fail the turn.
	own, ownSize, err := buildContentBlocks(c.Attachments)
	if err != nil {
		return outcome{}, err
	}
	withProject := b.projectPending
	files := append(b.projectBlocks(MaxTurnAttachmentEncodedBytes-ownSize), own...)
	line, err := claudeUserLine(files, text)
	if err != nil {
		return outcome{}, err
	}
	p, sent, err := b.send(ctx, line)
	var rejected *resumeRejectedError
	if errors.As(err, &rejected) {
		return outcome{kind: outcomeLost, msg: rejected.msg}, nil
	}
	if err != nil {
		return outcome{}, err
	}
	if !sent { // cancelled before the message reached the child
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusInterrupted, SessionID: b.sessionToResume()})
		return outcome{kind: outcomeDone}, nil
	}
	out := b.await(ctx, p, emit)
	if withProject && out.kind == outcomeDone && !out.failed {
		b.projectSent()
	}
	return out, nil
}

// exitedTerminal is the terminal event of a turn whose child exited without a
// result: interrupted when the owner cancelled (the child was killed after
// the grace), otherwise the classified exit message.
func (b *claudeBackend) exitedTerminal(turnID, msg string) Event {
	b.mu.Lock()
	cancelled, sid := b.cancelled, b.resume
	b.mu.Unlock()
	if cancelled {
		return Event{Type: EventTurnDone, TurnID: turnID, Status: StatusInterrupted, SessionID: sid}
	}
	code, retry := ClassifyClaudeError(msg)
	return errorEvent(turnID, code, msg, retry)
}

// await relays events until the turn's terminal event, the child's exit, or
// ctx cancellation. A --resume rejection (as an error result, or as an exit
// before any result) is reported as outcomeLost instead of being emitted.
func (b *claudeBackend) await(ctx context.Context, p *claudeProc, emit func(Event)) outcome {
	handle := func(e Event) (outcome, bool) {
		if e.Type == EventError && e.Code == CodeSessionLost && p.resumed {
			return outcome{kind: outcomeLost, msg: e.Message}, true
		}
		emit(e)
		if isTerminal(e) {
			return outcome{kind: outcomeDone, failed: e.Type == EventError}, true
		}
		return outcome{}, false
	}
	for {
		select {
		case e := <-p.events:
			if o, done := handle(e); done {
				return o
			}
		case <-p.exited:
			return exitOutcome(p, handle)
		case <-ctx.Done():
			return outcome{kind: outcomeContext}
		}
	}
}

// exitOutcome judges a child that exited mid-turn: it first delivers what the
// child printed before it died, then reads stderr — a --resume rejected
// before any result is outcomeLost.
func exitOutcome(p *claudeProc, handle func(Event) (outcome, bool)) outcome {
	waitClosed(p.outDone, 500*time.Millisecond)
	if o, done := drainPending(p.events, handle); done {
		return o
	}
	waitClosed(p.errDone, 500*time.Millisecond)
	msg := strings.TrimSpace(p.stderr.String())
	if msg == "" {
		msg = "claude exited: " + p.cmd.ProcessState.String()
	}
	if p.resumed && !p.gotResult.Load() {
		if code, _ := ClassifyClaudeError(msg); code == CodeSessionLost {
			return outcome{kind: outcomeLost, msg: msg}
		}
	}
	return outcome{kind: outcomeExited, msg: msg}
}

// send writes the user message to the live child (spawning one if needed).
// It returns sent=false when a cancel landed first.
//
// The cancel/closed checks, the spawn and taking the child's write lock
// happen under b.mu, shared with Cancel and Close: a cancel either finds the
// message in flight (its interrupt then queues behind the message on
// writeMu) or stops it being sent, and no child is spawned after Close. The
// write itself runs outside b.mu — it can block on a child that stopped
// reading, and Cancel and Close must still get through to kill it.
func (b *claudeBackend) send(ctx context.Context, line []byte) (*claudeProc, bool, error) {
	p, err := b.claimForSend(ctx)
	if p == nil || err != nil {
		return nil, false, err
	}
	_, werr := p.stdin.Write(line)
	p.writeMu.Unlock()
	if werr != nil {
		b.mu.Lock()
		closed := b.closed
		b.mu.Unlock()
		if closed {
			return nil, false, fmt.Errorf("%w: %v", errBackendClosed, werr)
		}
		// Otherwise a dead child surfaces as an exit in await, with its stderr.
	}
	return p, true, nil
}

// claimForSend returns the live child with its writeMu held, or nil when the
// turn was cancelled (nil error) or may not run (closed, ctx done).
func (b *claudeBackend) claimForSend(ctx context.Context) (*claudeProc, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancelled {
		return nil, nil
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	p, err := b.ensureProcLocked()
	if err != nil {
		return nil, err
	}
	drain(p.events)
	p.writeMu.Lock()
	b.inFlight = true
	return p, nil
}

func (b *claudeBackend) sessionToResume() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.resume
}

// ensureProcLocked returns the live child, respawning (with --resume of the
// last session, if any) when it has exited. Never spawns after Close.
//
// A child that exited because the CLI rejected its --resume (the warm child
// started at session open usually dies of it before the owner's first turn)
// is not respawned with the same doomed --resume: a *resumeRejectedError lets
// Turn go straight to its fresh retry.
func (b *claudeBackend) ensureProcLocked() (*claudeProc, error) {
	if b.closed {
		return nil, errBackendClosed
	}
	if b.proc != nil {
		select {
		case <-b.proc.exited:
			sweep(b.proc)
			if msg := b.proc.rejectedResume(); msg != "" {
				return nil, &resumeRejectedError{msg: msg}
			}
		default:
			return b.proc, nil
		}
	}
	if b.resume == "" {
		// A fresh session (the child died before reporting a session id):
		// its history holds no project files. This turn's line is already
		// built, so the flag reaches the next turn at the latest.
		b.markFreshSession()
	}
	return b.spawnLocked()
}

// restartFresh replaces the child with a fresh session (no --resume); the
// next turn carries the replayed history.
func (b *claudeBackend) restartFresh() {
	b.mu.Lock()
	p := b.proc
	b.proc = nil
	b.resume = ""
	b.mu.Unlock()
	b.markFreshSession()
	if p != nil {
		b.stopProc(p)
	}
}

func (b *claudeBackend) replayText(turnID string) (string, error) {
	if b.opts.Replay == nil {
		return "", nil
	}
	return b.opts.Replay(turnID)
}

// Cancel sends the interrupt control request; if the turn has not ended
// within InterruptGrace the child is killed and the next turn resumes.
//
// The session calls Cancel only while a turn is in flight, possibly before
// Turn has reached the child: the recorded flag then stops the message from
// being sent at all (see send).
func (b *claudeBackend) Cancel() error {
	b.mu.Lock()
	b.cancelled = true
	p, inFlight := b.proc, b.inFlight
	b.mu.Unlock()
	if p == nil || !inFlight {
		return nil // nothing reached the child yet: send will not send it
	}
	turn, _ := b.curTurn.Load().(string)
	b.tr.MarkInterrupted()
	req, err := json.Marshal(map[string]any{
		"type": "control_request", "request_id": "interrupt-" + turn,
		"request": map[string]string{"subtype": "interrupt"},
	})
	if err != nil {
		return err
	}
	// The interrupt queues behind the message on writeMu, which may be stuck
	// on a child that stopped reading, so it is written asynchronously; the
	// grace timer below kills such a child, which also fails the writes.
	go func() {
		if werr := p.write(append(req, '\n')); werr != nil {
			// stdin is gone: the child cannot be interrupted, only killed;
			// the turn then ends as interrupted through the exit path.
			killGroup(p)
		}
	}()
	time.AfterFunc(b.opts.InterruptGrace, func() {
		if t, _ := b.curTurn.Load().(string); t != turn || !b.active.Load() {
			return
		}
		select {
		case <-p.exited:
		default:
			killGroup(p)
		}
	})
	return nil
}

// neutralWorkDirName is the stable, empty directory under the system temp dir
// every chat child runs in (NeutralWorkDir).
const neutralWorkDirName = "watchtower-chat-cwd"

// NeutralWorkDir is the default ClaudeOptions.WorkDir: a dedicated directory
// under the per-user system temp dir, whose parents hold no CLAUDE.md, at
// the same path on every spawn so --resume keeps working.
func NeutralWorkDir() string {
	return filepath.Join(os.TempDir(), neutralWorkDirName)
}

// workDir (re)creates the child's working directory — macOS sweeps unused
// temp entries — and falls back to the temp dir itself if it cannot.
func (b *claudeBackend) workDir() string {
	if err := os.MkdirAll(b.opts.WorkDir, 0o700); err != nil {
		fmt.Fprintf(b.warn(), "chat work dir %s unavailable, using the temp dir: %v\n", b.opts.WorkDir, err)
		return os.TempDir()
	}
	return b.opts.WorkDir
}

// Close ends the child (stdin EOF → SIGTERM → SIGKILL, CloseGrace apart),
// sweeps its process group and removes the temp files. Idempotent.
func (b *claudeBackend) Close() error {
	b.closeOnce.Do(func() {
		b.mu.Lock()
		b.closed = true
		p := b.proc
		b.proc = nil
		b.mu.Unlock()
		if p != nil {
			b.stopProc(p)
		}
		for _, f := range []string{b.promptFile, b.mcpFile} {
			if f != "" {
				_ = os.Remove(f)
			}
		}
	})
	return nil
}

func (b *claudeBackend) stopProc(p *claudeProc) {
	p.stopOnce.Do(func() { close(p.stop) })
	p.closeStdin()
	if !waitClosed(p.exited, b.opts.CloseGrace) {
		_ = syscall.Kill(-p.pgid, syscall.SIGTERM)
		if !waitClosed(p.exited, b.opts.CloseGrace) {
			killGroup(p)
			<-p.exited
		}
	}
	sweep(p)
}

// killGroup SIGKILLs the child and everything in its process group.
func killGroup(p *claudeProc) { _ = syscall.Kill(-p.pgid, syscall.SIGKILL) }

// sweep terminates what is left of the child's process group (the MCP
// servers claude spawned) once claude itself is gone.
func sweep(p *claudeProc) { _ = syscall.Kill(-p.pgid, syscall.SIGTERM) }

func waitClosed(ch <-chan struct{}, d time.Duration) bool {
	select {
	case <-ch:
		return true
	case <-time.After(d):
		return false
	}
}

func drain(ch chan Event) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

// drainPending feeds every buffered event to handle until one ends the turn
// (done=true) or the buffer is empty (done=false).
func drainPending(ch chan Event, handle func(Event) (outcome, bool)) (outcome, bool) {
	for {
		select {
		case e := <-ch:
			if o, done := handle(e); done {
				return o, true
			}
		default:
			return outcome{}, false
		}
	}
}

// writePrivateTemp writes content to a new 0600 temp file.
func writePrivateTemp(pattern, content string) (string, error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

// boundedBuffer keeps the first limit bytes written to it (stderr capture).
type boundedBuffer struct {
	mu    sync.Mutex
	buf   []byte
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := b.limit - len(b.buf); room > 0 {
		if len(p) > room {
			b.buf = append(b.buf, p[:room]...)
		} else {
			b.buf = append(b.buf, p...)
		}
	}
	return len(p), nil
}

func (b *boundedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}
