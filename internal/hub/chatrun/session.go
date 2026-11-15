package chatrun

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/chatstore"
)

// Shutdown numbers (Swift ChatSessionClient): `close`, then one SIGTERM
// after closeGrace, then SIGKILL of the group after killAfter. drainGrace
// bounds how long stdout may stay open after the process exited (a child
// of the group holding it) before the group is killed.
const (
	closeGrace = 2 * time.Second
	killAfter  = 3 * time.Second
	drainGrace = time.Second
)

// Process is one running `ai session` child.
type Process interface {
	// Stdin takes the JSONL commands; Stdout yields the NDJSON events.
	Stdin() io.Writer
	Stdout() io.ReadCloser
	// PGID is the child's process group (0 = none, an in-process fake: no
	// group file is written).
	PGID() int
	// Terminate sends SIGTERM to the session process (once per lifetime);
	// Kill sends SIGKILL to its whole process group.
	Terminate() error
	Kill() error
	// Exited is closed once the process exited and was reaped.
	Exited() <-chan struct{}
}

// StartFunc spawns `<exe> argv...`.
type StartFunc func(argv []string) (Process, error)

type phase int

const (
	phasePending phase = iota // waiting for a slot: no process
	phaseLaunch               // granted a slot; the loop spawns it
	phaseLive                 // its process runs
)

// heldTurn is the turn a session holds: queued, sent or running.
type heldTurn struct {
	st chatstore.Started
	t  *chatstore.Turn
	at time.Time // when its start transaction committed (its first heartbeat)
}

// session is one conversation's `ai session` child and the goroutine that
// owns it: every Apply, Flush and Finalize of its turns runs on loop.
type session struct {
	r    *Runner
	conv int64
	cfg  sessionConfig
	kick chan struct{}

	// Guarded by r.mu.
	phase        phase
	turn         *heldTurn // nil = idle
	lastActivity time.Time
	leaf         *int64 // the last message this process answered (ChatContinuity)
	blocked      bool   // pending with no slot coming: "Waiting for a free slot"
	retire       bool   // close once idle; never reused
	closing      bool   // the runner closes: stop now, leave a cut turn's lease
	dropped      bool   // a pending session given up (cancelled, gone, failed spawn)
	cancelPoke   bool   // Cancel asked for an immediate lease read

	// Owned by loop.
	proc       Process
	events     <-chan chat.Event // nil once drained
	exited     <-chan struct{}   // nil once seen
	ready      *chat.Event       // the session's session_ready, re-applied to each turn
	cur        *heldTurn         // the turn sent to the process
	retry      func() error      // a failed final write, retried once on the next tick
	watchTurn  string            // the turn the lease fields below belong to
	heartbeat  time.Time         // the last lease heartbeat
	cancelSent bool
	cancelAt   *time.Timer // the 7 s Stop watchdog
	flushed    int         // the text length at the last tick's flush
	stage      int         // 0 running, 1 close sent, 2 SIGTERM sent, 3 SIGKILL sent
	stageAt    *time.Timer
	drainAt    *time.Timer
	pgidPath   string
}

func (s *session) poke() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

func timerC(t *time.Timer) <-chan time.Time {
	if t == nil {
		return nil
	}
	return t.C
}

func (s *session) loop() {
	defer s.r.wg.Done()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-s.kick:
			s.onKick()
		case ev, ok := <-s.events:
			if !ok {
				s.events = nil
			} else {
				s.onEvent(ev)
			}
		case <-s.exited:
			s.exited = nil
			if s.events != nil {
				s.drainAt = time.NewTimer(drainGrace)
			}
		case <-tick.C:
			s.onTick()
		case <-timerC(s.cancelAt):
			s.cancelAt = nil
			s.onCancelDeadline()
		case <-timerC(s.stageAt):
			s.stageAt = nil
			s.escalate()
		case <-timerC(s.drainAt):
			s.drainAt = nil
			_ = s.proc.Kill() // a group member holds stdout open
		}
		if s.finished() {
			s.end()
			return
		}
	}
}

// finished: a pending session given up, or the process exited and its
// events are drained.
func (s *session) finished() bool {
	if s.proc == nil {
		s.r.mu.Lock()
		defer s.r.mu.Unlock()
		return s.dropped || s.closing
	}
	return s.exited == nil && s.events == nil
}

func (s *session) onKick() {
	s.r.mu.Lock()
	ph, held, closing, retire, cancelPoke := s.phase, s.turn, s.closing, s.retire, s.cancelPoke
	s.cancelPoke = false
	s.r.mu.Unlock()

	if closing && s.proc == nil {
		return // finished() ends it; a held turn keeps its lease for the sweep
	}
	if ph == phaseLaunch && s.proc == nil && !s.spawn(held) {
		return
	}
	if s.proc != nil && held != nil && s.cur == nil && s.stage == 0 {
		s.startTurn(held)
	}
	if cancelPoke {
		s.watchLease(s.r.c.Clock(), false)
	}
	if s.proc != nil && (closing || (retire && s.cur == nil)) {
		s.beginShutdown(false)
	}
}

// spawn starts the process; a failure ends the held turn as an error, as
// the Mac's failTurn does.
func (s *session) spawn(held *heldTurn) bool {
	p, err := s.r.c.Start(s.cfg.argv(s.conv, s.r.c.DBPath))
	if err != nil {
		log.Printf("chatrun: conversation %d: starting the session failed (%s)", s.conv, errClass(err))
		if held != nil {
			s.r.finalizeUnsent(held.st, held.t, chatstore.StatusError,
				&chatstore.Failure{Code: chat.CodeProviderUnavailable, Message: "The chat session could not start."})
		}
		s.r.mu.Lock()
		s.dropped, s.turn = true, nil
		s.r.mu.Unlock()
		return false
	}
	s.proc, s.exited = p, p.Exited()
	s.events = readEvents(s.conv, p.Stdout())
	s.writePGID(p.PGID())
	s.r.mu.Lock()
	s.phase = phaseLive
	s.r.mu.Unlock()
	return true
}

// startTurn sends held to the process. A warm session's session_ready is
// applied first, so the reply row records its provider and model.
func (s *session) startTurn(held *heldTurn) {
	s.cur, s.flushed, s.retry = held, 0, nil
	if s.ready != nil {
		s.apply(*s.ready)
		if s.cur == nil {
			return
		}
	}
	err := s.send(chat.Command{Type: chat.CommandTurn, TurnID: held.st.TurnID, Text: held.st.SendText,
		Attachments: held.st.Attachments, Replay: held.st.Replay})
	if err != nil {
		// The pipe is gone: the process is exiting; end finalizes the turn.
		log.Printf("chatrun: conversation %d: sending turn %s failed (%s)", s.conv, held.st.TurnID, errClass(err))
	}
}

func (s *session) send(c chat.Command) error {
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	_, err = s.proc.Stdin().Write(append(b, '\n'))
	return err
}

func (s *session) onEvent(ev chat.Event) {
	if ev.Type == chat.EventSessionReady {
		e := ev
		s.ready = &e
	}
	if s.cur == nil {
		return
	}
	s.apply(ev)
	s.r.changed(s.conv)
}

// apply folds ev into the running turn and handles its outcome.
func (s *session) apply(ev chat.Event) {
	cur := s.cur
	err := cur.t.Apply(ev)
	switch {
	case errors.Is(err, chatstore.ErrConversationGone):
		s.lost()
		return
	case err != nil:
		log.Printf("chatrun: conversation %d: writing turn %s failed (%s)", s.conv, cur.st.TurnID, errClass(err))
		if terminalFor(ev, cur.st.TurnID) {
			if done, _ := cur.t.Done(); !done {
				s.retry = func() error { return cur.t.Apply(ev) }
			}
		}
	}
	s.checkDone()
}

// terminalFor: ev ends turnID (its turn_done, or an error of it or of the
// whole session).
func terminalFor(ev chat.Event, turnID string) bool {
	switch ev.Type {
	case chat.EventTurnDone:
		return ev.TurnID == turnID
	case chat.EventError:
		return ev.TurnID == "" || ev.TurnID == turnID
	}
	return false
}

// checkDone hands a finalized turn back: the session is idle again.
func (s *session) checkDone() {
	cur := s.cur
	if cur == nil || s.retry != nil {
		return
	}
	done, status := cur.t.Done()
	if !done {
		return
	}
	s.cur = nil
	s.stopCancelWatch()
	now := s.r.c.Clock()
	s.r.mu.Lock()
	if s.turn == cur {
		s.turn = nil
	}
	if status == chatstore.StatusError {
		s.leaf = nil // it may or may not have reached the provider: replay next time
	} else {
		id := cur.st.AssistantMessageID
		s.leaf = &id
	}
	s.lastActivity = now
	retire := s.retire || s.closing
	s.r.admit()
	s.r.mu.Unlock()
	s.r.turnEnded(s.conv, cur.st.TurnID, status)
	s.r.changed(s.conv)
	if retire && s.proc != nil {
		s.beginShutdown(false)
	}
}

// lost: the conversation is gone or its lease taken over (spec §4.4) —
// nothing more is written for the turn; the session is cancelled and
// closed.
func (s *session) lost() {
	s.r.mu.Lock()
	held := s.turn
	s.turn, s.retire = nil, true
	if s.proc == nil {
		s.dropped = true
	}
	s.r.mu.Unlock()
	turnID := ""
	if held != nil {
		turnID = held.st.TurnID
	}
	log.Printf("chatrun: conversation %d: turn %s lost its conversation or lease; closing the session", s.conv, turnID)
	s.cur, s.retry = nil, nil
	s.stopCancelWatch()
	if s.proc != nil {
		_ = s.send(chat.Command{Type: chat.CommandCancel})
		s.beginShutdown(false)
	}
	s.r.changed(s.conv)
}

func (s *session) onTick() {
	now := s.r.c.Clock()
	if s.retry != nil {
		retry := s.retry
		s.retry = nil
		if err := retry(); err != nil && !errors.Is(err, chatstore.ErrConversationGone) {
			log.Printf("chatrun: conversation %d: the final write failed again (%s); the lease goes stale", s.conv, errClass(err))
			s.giveUp()
			return
		} else if err != nil {
			s.lost()
			return
		}
		s.checkDone()
	}
	if s.cur != nil {
		if n := len(s.cur.t.Text()); n != s.flushed {
			s.flushed = n
			if err := s.cur.t.Flush(); errors.Is(err, chatstore.ErrConversationGone) {
				s.lost()
				return
			} else if err != nil {
				log.Printf("chatrun: conversation %d: flushing failed (%s)", s.conv, errClass(err))
			}
		}
	}
	s.watchLease(now, true)
	s.r.mu.Lock()
	idle := s.phase == phaseLive && s.turn == nil && !s.retire && !s.closing &&
		now.Sub(s.lastActivity) >= IdleTTL
	if idle {
		s.retire = true
		s.r.admit()
	}
	s.r.mu.Unlock()
	if idle {
		s.beginShutdown(false)
	}
}

// giveUp drops a turn whose final write failed twice: no more heartbeats,
// so its lease goes stale and the row stays `partial`; the session is not
// reused.
func (s *session) giveUp() {
	s.r.mu.Lock()
	s.turn, s.retire = nil, true
	if s.proc == nil {
		s.dropped = true
	}
	s.r.mu.Unlock()
	s.cur = nil
	s.stopCancelWatch()
	if s.proc != nil {
		s.beginShutdown(false)
	}
	s.r.changed(s.conv)
}

// beginShutdown starts the close sequence once: `close`, SIGTERM after
// closeGrace, SIGKILL after killAfter. terminate skips the polite close (a
// session that ignored `cancel`).
func (s *session) beginShutdown(terminate bool) {
	if s.proc == nil || s.exited == nil {
		return // already exited
	}
	switch {
	case s.stage == 0 && !terminate:
		s.stage = 1
		_ = s.send(chat.Command{Type: chat.CommandClose})
		s.stageAt = time.NewTimer(closeGrace)
	case s.stage <= 1 && terminate:
		s.stopStage()
		s.escalateTo(2)
	}
}

func (s *session) escalate() { s.escalateTo(s.stage + 1) }

func (s *session) escalateTo(stage int) {
	if s.exited == nil {
		return // already gone
	}
	switch stage {
	case 2:
		s.stage = 2
		_ = s.proc.Terminate()
		s.stageAt = time.NewTimer(killAfter)
	case 3:
		s.stage = 3
		_ = s.proc.Kill()
	}
}

func (s *session) stopStage() {
	if s.stageAt != nil {
		s.stageAt.Stop()
		s.stageAt = nil
	}
}

// end runs once the process is gone (or a pending session given up): a turn
// cut by the death keeps its text as `partial` with session_lost — or, when
// the runner closes, only its text, its lease left for the next start's
// sweep.
func (s *session) end() {
	s.stopStage()
	s.stopCancelWatch()
	if s.drainAt != nil {
		s.drainAt.Stop()
	}
	if s.proc != nil {
		s.r.mu.Lock()
		held, closing := s.turn, s.closing
		s.dropped = true // no Run hands it a turn any more
		s.r.mu.Unlock()
		if s.cur == nil && held != nil {
			s.cur = held // assigned, never sent
		}
		if cur := s.cur; cur != nil {
			if done, _ := cur.t.Done(); !done {
				if closing {
					if err := cur.t.Flush(); err != nil {
						log.Printf("chatrun: conversation %d: the last flush failed (%s)", s.conv, errClass(err))
					}
				} else {
					s.retry = nil
					s.r.finalizeUnsent(cur.st, cur.t, chatstore.StatusPartial, lostFailure())
				}
			}
		}
		s.cur = nil
		s.removePGID()
	}
	s.r.ended(s)
}

// readEvents decodes the session's NDJSON stdout; a line that is not an
// event is skipped (counted, never logged).
func readEvents(conv int64, out io.ReadCloser) <-chan chat.Event {
	ch := make(chan chat.Event)
	go func() {
		defer close(ch)
		defer func() { _ = out.Close() }()
		br := bufio.NewReader(out)
		bad := 0
		for {
			line, err := br.ReadBytes('\n')
			if line = bytes.TrimSpace(line); len(line) > 0 {
				var ev chat.Event
				if json.Unmarshal(line, &ev) == nil && ev.Type != "" {
					ch <- ev
				} else {
					bad++
				}
			}
			if err != nil {
				if bad > 0 {
					log.Printf("chatrun: conversation %d: %d unreadable event lines skipped", conv, bad)
				}
				return
			}
		}
	}()
	return ch
}

// pgidDir is where the children's process-group files live.
func (r *Runner) pgidDir() string {
	if r.c.Dir == "" {
		return ""
	}
	return filepath.Join(r.c.Dir, "chatrun")
}

// writePGID records the child's group for a sweep after a kill -9 of the
// daemon: <dir>/<conversation>.pgid, 0600, ids only.
func (s *session) writePGID(pgid int) {
	dir := s.r.pgidDir()
	if dir == "" || pgid <= 0 {
		return
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("chatrun: conversation %d: creating the group dir failed (%s)", s.conv, errClass(err))
		return
	}
	path := filepath.Join(dir, strconv.FormatInt(s.conv, 10)+".pgid")
	if err := os.WriteFile(path, []byte(strconv.Itoa(pgid)), 0o600); err != nil {
		log.Printf("chatrun: conversation %d: writing the group file failed (%s)", s.conv, errClass(err))
		return
	}
	s.pgidPath = path
}

// removePGID removes the group file once the child is reaped — only when it
// still names this child's group.
func (s *session) removePGID() {
	if s.pgidPath == "" {
		return
	}
	if b, err := os.ReadFile(s.pgidPath); err == nil && string(b) == strconv.Itoa(s.proc.PGID()) {
		_ = os.Remove(s.pgidPath)
	}
	s.pgidPath = ""
}

// execProcess is a real child in its own process group.
type execProcess struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *os.File
	exited chan struct{}
}

// execStart spawns exe in its own process group, with the daemon's working
// directory and environment; stderr is discarded (FILES-01: it may carry
// content).
func execStart(exe string) StartFunc {
	return func(argv []string) (Process, error) {
		if exe == "" {
			return nil, errors.New("chatrun: no watchtower executable")
		}
		cmd := exec.Command(exe, argv...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		pr, pw, err := os.Pipe()
		if err != nil {
			return nil, err
		}
		cmd.Stdout = pw
		stdin, err := cmd.StdinPipe()
		if err != nil {
			_, _ = pr.Close(), pw.Close()
			return nil, err
		}
		if err := cmd.Start(); err != nil {
			_, _ = pr.Close(), pw.Close()
			return nil, err
		}
		_ = pw.Close()
		p := &execProcess{cmd: cmd, stdin: stdin, stdout: pr, exited: make(chan struct{})}
		go func() {
			_ = cmd.Wait()
			close(p.exited)
		}()
		return p, nil
	}
}

func (p *execProcess) Stdin() io.Writer        { return p.stdin }
func (p *execProcess) Stdout() io.ReadCloser   { return p.stdout }
func (p *execProcess) PGID() int               { return p.cmd.Process.Pid }
func (p *execProcess) Terminate() error        { return p.cmd.Process.Signal(syscall.SIGTERM) }
func (p *execProcess) Kill() error             { return syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL) }
func (p *execProcess) Exited() <-chan struct{} { return p.exited }
