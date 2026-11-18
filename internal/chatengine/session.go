package chatengine

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

	"watchtower/internal/aiconsent"
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

// stdinBacklog bounds the commands waiting for the stdin writer; a send past
// it fails as a gone pipe does (a session that reads none of a few commands
// is escalated anyway).
const stdinBacklog = 16

// errStdinBacklog is a send refused because the child reads no stdin.
var errStdinBacklog = errors.New("chatengine: the session reads no commands")

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
	r    *Engine
	conv int64
	cfg  sessionConfig
	kick chan struct{}

	// Guarded by r.mu.
	phase        phase
	turn         *heldTurn // nil = idle
	lastActivity time.Time
	leaf         *int64      // the last message this process answered (ChatContinuity)
	blocked      bool        // pending with no slot coming: "Waiting for a free slot"
	retire       bool        // close once idle; never reused
	warm         bool        // started ahead of a turn (Warm): launches only into a free slot
	closing      bool        // the runner closes: stop now, leave a cut turn's lease
	dropped      bool        // a pending session given up (cancelled, gone, failed spawn)
	cancelPoke   bool        // Cancel asked for an immediate lease read
	gone         bool        // Manage deleted the conversation: drop the turn now
	detaching    bool        // Detach: leave the process running, write no end
	shutdown     bool        // Shutdown: end the turn `partial`, then close
	readyLive    *chat.Event // the last session_ready, for the live routing overlay

	// Owned by loop.
	proc       Process
	stdin      chan []byte       // encoded command lines for writeStdin; closed by end
	stdinShut  bool              // the process's stdin was closed
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
	done       chan struct{} // closed when loop returned (nil for a test's bare session)
	adopted    bool          // reattached by Start: its turn (if any) is replayed, never reused
	adoptCheck bool          // until the replay's attached line: does the process hold our turn?
	shutDone   bool          // the Shutdown step ran
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
	if s.done != nil {
		defer close(s.done)
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	if s.adopted {
		s.wire(s.proc)
		s.r.mu.Lock()
		s.cur = s.turn // already sent by the engine before the restart
		s.r.mu.Unlock()
		s.adoptCheck = true
	}
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
			s.kill() // a group member holds stdout open
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
	ph, held, closing, retire, cancelPoke, gone := s.phase, s.turn, s.closing, s.retire, s.cancelPoke, s.gone
	detaching, shutdown := s.detaching, s.shutdown
	s.cancelPoke, s.gone = false, false
	s.r.mu.Unlock()

	if detaching {
		s.detach()
		return
	}
	if shutdown && !s.shutDone {
		s.shutDone = true
		s.endForShutdown(held)
		if s.proc != nil {
			s.beginShutdown(false)
		}
		return
	}
	if closing && s.proc == nil {
		return // finished() ends it; a held turn keeps its lease for the sweep
	}
	if gone && held != nil {
		s.lost()
		return
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
	argv := s.cfg.argv(s.conv, s.r.c.DBPath)
	if s.r.listening() {
		argv = append(argv, "--listen", s.r.sessionSocket(s.conv))
	}
	p, err := s.r.c.Start(argv)
	if err != nil {
		log.Printf("chatengine: conversation %d: starting the session failed (%s)", s.conv, errClass(err))
		// A stopping engine leaves the turn's lease to the next start's sweep.
		if held != nil && !errors.Is(err, ErrClosed) {
			s.r.finalizeUnsent(held.st, held.t, chatstore.StatusError,
				&chatstore.Failure{Code: chat.CodeProviderUnavailable, Message: "The chat session could not start."})
		}
		s.r.mu.Lock()
		s.dropped, s.turn = true, nil
		s.r.mu.Unlock()
		return false
	}
	s.wire(p)
	s.r.mu.Lock()
	s.phase = phaseLive
	s.r.mu.Unlock()
	return true
}

// wire starts talking to p: the stdin writer, the event reader and the
// group file; a session socket's process is attached first (it replays its
// current turn).
func (s *session) wire(p Process) {
	s.proc, s.exited = p, p.Exited()
	s.stdin = make(chan []byte, stdinBacklog)
	s.r.wg.Add(1)
	go s.writeStdin(p.Stdin(), s.stdin)
	s.events = readEvents(s.conv, p.Stdout())
	s.writePGID(p.PGID())
	if s.r.listening() {
		_ = s.send(chat.Command{Type: chat.CommandAttach})
	}
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
		log.Printf("chatengine: conversation %d: sending turn %s failed (%s)", s.conv, held.st.TurnID, errClass(err))
	}
}

// send queues one command line for the stdin writer; it never blocks the
// loop, so a child that stops reading stdin cannot stall the escalation.
func (s *session) send(c chat.Command) error {
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	select {
	case s.stdin <- append(b, '\n'):
		return nil
	default:
		return errStdinBacklog
	}
}

// writeStdin writes the queued command lines to the child, off the loop
// goroutine; after a failed write the rest are dropped. It returns once end
// closed lines (a blocked write is ended by closeStdin).
func (s *session) writeStdin(w io.Writer, lines <-chan []byte) {
	defer s.r.wg.Done()
	failed := false
	for line := range lines {
		if failed {
			continue
		}
		if _, err := w.Write(line); err != nil {
			failed = true
			log.Printf("chatengine: conversation %d: writing to the session failed (%s)", s.conv, errClass(err))
		}
	}
}

// kill sends SIGKILL to the group and closes its stdin, which ends a write
// blocked on a child that never read it.
func (s *session) kill() {
	_ = s.proc.Kill()
	s.closeStdin()
}

func (s *session) closeStdin() {
	if s.stdinShut {
		return
	}
	s.stdinShut = true
	if c, ok := s.proc.Stdin().(io.Closer); ok {
		_ = c.Close()
	}
}

func (s *session) onEvent(ev chat.Event) {
	if ev.Type == chat.EventAttached {
		s.onAttached(ev)
		return
	}
	if ev.Type == chat.EventSessionReady {
		e := ev
		s.ready = &e
		s.r.mu.Lock()
		s.readyLive = &e
		s.r.mu.Unlock()
	}
	if s.cur == nil {
		if ev.Type == chat.EventSessionReady {
			s.r.changed(s.conv) // the routing overlay moved
		}
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
		log.Printf("chatengine: conversation %d: writing turn %s failed (%s)", s.conv, cur.st.TurnID, errClass(err))
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
	log.Printf("chatengine: conversation %d: turn %s lost its conversation or lease; closing the session", s.conv, turnID)
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
			log.Printf("chatengine: conversation %d: the final write failed again (%s); the lease goes stale", s.conv, errClass(err))
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
				log.Printf("chatengine: conversation %d: flushing failed (%s)", s.conv, errClass(err))
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
		s.kill()
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
		held, closing, detaching := s.turn, s.closing, s.detaching
		s.dropped = true // no Run hands it a turn any more
		s.r.mu.Unlock()
		if detaching {
			// The process runs on; the next engine reattaches to it.
			s.cur = nil
			s.closeLines()
			s.r.ended(s)
			return
		}
		if s.cur == nil && held != nil {
			s.cur = held // assigned, never sent
		}
		if cur := s.cur; cur != nil {
			if done, _ := cur.t.Done(); !done {
				switch {
				case closing:
					if err := cur.t.Flush(); err != nil {
						log.Printf("chatengine: conversation %d: the last flush failed (%s)", s.conv, errClass(err))
					}
				case s.adoptCheck:
					// The replay never finished: its text may be shorter
					// than the row's, so the row keeps its own text.
					if err := s.r.loseLease(s.conv); err != nil {
						log.Printf("chatengine: conversation %d: ending a lost turn failed (%s)", s.conv, errClass(err))
					} else {
						s.r.turnEnded(s.conv, cur.st.TurnID, chatstore.StatusPartial)
					}
				default:
					s.retry = nil
					s.r.finalizeUnsent(cur.st, cur.t, chatstore.StatusPartial, lostFailure())
				}
			}
		}
		s.cur = nil
		s.closeLines()
		s.closeStdin()
		s.removePGID()
	}
	s.r.ended(s)
}

// detach (Engine.Detach, a daemon restart): the turn's text so far is
// flushed, the connection dropped and the process left running with its
// group file and the turn's lease; nothing ends the turn — the next engine
// reattaches and replays it (unified chat spec §7, D23). A pending session
// just ends (its lease is left for the next start's sweep).
func (s *session) detach() {
	if s.proc == nil || s.events == nil && s.exited == nil {
		return
	}
	if cur := s.cur; cur != nil {
		if done, _ := cur.t.Done(); !done {
			if err := cur.t.Flush(); err != nil {
				log.Printf("chatengine: conversation %d: the flush before detaching failed (%s)", s.conv, errClass(err))
			}
		}
	}
	s.stopStage()
	s.stopCancelWatch()
	if s.drainAt != nil {
		s.drainAt.Stop()
		s.drainAt = nil
	}
	s.closeLines()
	if d, ok := s.proc.(interface{ Detach() }); ok {
		d.Detach()
	} else {
		s.closeStdin()
	}
	if ch := s.events; ch != nil {
		go drainEvents(ch) // the reader may be mid-send
	}
	s.events, s.exited = nil, nil
}

// closeLines ends the stdin writer (once).
func (s *session) closeLines() {
	if s.stdin != nil {
		close(s.stdin)
		s.stdin = nil
	}
}

// drainEvents reads a detached connection's events until its reader ends.
func drainEvents(ch <-chan chat.Event) {
	for ev := range ch {
		_ = ev
	}
}

// endForShutdown (Engine.Shutdown): the running turn is cancelled and ends
// `partial` with its text now; a turn never sent ends `partial` too. The
// caller then closes the session (close, 2 s, SIGTERM, 3 s, SIGKILL).
func (s *session) endForShutdown(held *heldTurn) {
	if cur := s.cur; cur != nil {
		_ = s.send(chat.Command{Type: chat.CommandCancel})
		if err := cur.t.Finalize(chatstore.StatusPartial, nil); err != nil {
			if err = cur.t.Finalize(chatstore.StatusPartial, nil); err != nil {
				log.Printf("chatengine: conversation %d: finalizing at shutdown failed (%s)", s.conv, errClass(err))
			}
		}
		s.checkDone()
		return
	}
	if held == nil {
		return
	}
	s.r.mu.Lock()
	s.turn = nil
	if s.proc == nil {
		s.dropped = true
	}
	s.r.mu.Unlock()
	s.r.finalizeUnsent(held.st, held.t, chatstore.StatusPartial, nil)
	s.r.changed(s.conv)
}

// onAttached is the attached line that ends a reattached session's replay:
// the held turn's text is whole again, so its flushes resume. A held turn
// the process never got (the old engine went away while the session was
// still binding its socket) is sent now, rebuilt from its stored rows; one
// that cannot be rebuilt ends `partial` with session_lost.
func (s *session) onAttached(ev chat.Event) {
	if !s.adoptCheck {
		return
	}
	s.adoptCheck = false
	cur := s.cur
	if cur == nil {
		return
	}
	if err := cur.t.ReleaseFlushes(); err != nil {
		log.Printf("chatengine: conversation %d: flushing a reattached turn failed (%s)", s.conv, errClass(err))
	}
	if done, _ := cur.t.Done(); done || ev.TurnID == cur.st.TurnID {
		return // replayed to its end, or running on live
	}
	st, err := s.r.store.Resend(s.r.stopCtx, cur.st)
	if err == nil {
		cur.st = st
		err = s.send(chat.Command{Type: chat.CommandTurn, TurnID: st.TurnID, Text: st.SendText,
			Attachments: st.Attachments, Replay: st.Replay})
	}
	if err == nil {
		log.Printf("chatengine: conversation %d: turn %s sent to its reattached session", s.conv, st.TurnID)
		return
	}
	log.Printf("chatengine: conversation %d: resending turn %s failed (%s)", s.conv, cur.st.TurnID, errClass(err))
	s.cur = nil
	s.r.mu.Lock()
	s.turn = nil
	s.r.mu.Unlock()
	s.r.finalizeUnsent(cur.st, cur.t, chatstore.StatusPartial, lostFailure())
	s.r.changed(s.conv)
	s.beginShutdown(false)
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
					log.Printf("chatengine: conversation %d: %d unreadable event lines skipped", conv, bad)
				}
				return
			}
		}
	}()
	return ch
}

// pgidDir is where the children's process-group files live.
func (e *Engine) pgidDir() string {
	if e.c.Dir == "" {
		return ""
	}
	return filepath.Join(e.c.Dir, "sessions")
}

// writePGID records the child's group for a sweep after a kill -9 of the
// daemon: <dir>/<conversation>.pgid, 0600, ids only.
func (s *session) writePGID(pgid int) {
	s.pgidPath = s.r.writeGroupFile(s.conv, pgid)
}

// writeGroupFile writes conv's group file and returns its path ("" = not
// written).
func (e *Engine) writeGroupFile(conv int64, pgid int) string {
	dir := e.pgidDir()
	if dir == "" || pgid <= 0 {
		return ""
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Printf("chatengine: conversation %d: creating the group dir failed (%s)", conv, errClass(err))
		return ""
	}
	path := filepath.Join(dir, strconv.FormatInt(conv, 10)+".pgid")
	if err := os.WriteFile(path, []byte(strconv.Itoa(pgid)), 0o600); err != nil {
		log.Printf("chatengine: conversation %d: writing the group file failed (%s)", conv, errClass(err))
		return ""
	}
	return path
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

// startCmd starts a session child's command; tests capture the command
// without starting it.
var startCmd = (*exec.Cmd).Start

// execStart spawns exe in its own process group, with the daemon's working
// directory and environment less the background-AI origin (each spawn serves
// one owner turn: aiconsent.OwnerEnv, Decision 3 of #1886); stderr is
// discarded (FILES-01: it may carry content).
func execStart(exe string) StartFunc {
	return func(argv []string) (Process, error) {
		if exe == "" {
			return nil, errors.New("chatengine: no watchtower executable")
		}
		cmd := exec.Command(exe, argv...)
		cmd.Env = aiconsent.OwnerEnv(os.Environ())
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
		if err := startCmd(cmd); err != nil {
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
