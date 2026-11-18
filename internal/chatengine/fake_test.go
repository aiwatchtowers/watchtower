package chatengine

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"sync"

	"watchtower/internal/chat"
)

// fakeOpts is how the in-process `ai session` twin behaves.
type fakeOpts struct {
	block        bool   // a turn streams one delta and waits for finish
	text         string // the delta's text ("" = "partial answer")
	junk         string // a non-event line written before session_ready
	ignoreCancel bool
	ignoreClose  bool
	ignoreTerm   bool
	noRead       bool // never reads stdin: a write to it blocks
}

// fakeStarter is the Start seam's in-process twin of `watchtower ai
// session`: its stdio are io.Pipes and its "process" a goroutine, so the
// tests run inside testing/synctest and wait on no wall clock.
type fakeStarter struct {
	opts fakeOpts
	fail error

	mu              sync.Mutex
	procs           []*fakeProc
	alive, maxAlive int
}

func (f *fakeStarter) start(argv []string) (Process, error) {
	if f.fail != nil {
		return nil, f.fail
	}
	p := &fakeProc{f: f, argv: argv, cmds: make(chan chat.Command, 64), sigs: make(chan string, 4),
		finishC: make(chan struct{}, 1), exited: make(chan struct{})}
	p.inR, p.inW = io.Pipe()
	p.outR, p.outW = io.Pipe()
	f.mu.Lock()
	f.procs = append(f.procs, p)
	n := len(f.procs)
	f.alive++
	f.maxAlive = max(f.maxAlive, f.alive)
	f.mu.Unlock()
	if !f.opts.noRead {
		go p.read()
	}
	go p.run(n)
	return p, nil
}

func (f *fakeStarter) all() []*fakeProc {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.procs)
}

func (f *fakeStarter) aliveNow() (alive, maxAlive int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.alive, f.maxAlive
}

type fakeProc struct {
	f          *fakeStarter
	argv       []string
	inR, outR  *io.PipeReader
	inW, outW  *io.PipeWriter
	cmds       chan chat.Command
	sigs       chan string
	finishC    chan struct{}
	exited     chan struct{}
	mu         sync.Mutex
	got        []string // command types and signals, in order
	turns      []chat.Command
	exitedOnce bool
}

func (p *fakeProc) Stdin() io.Writer        { return p.inW }
func (p *fakeProc) Stdout() io.ReadCloser   { return p.outR }
func (p *fakeProc) PGID() int               { return 0 }
func (p *fakeProc) Terminate() error        { p.signal("TERM"); return nil }
func (p *fakeProc) Kill() error             { p.signal("KILL"); return nil }
func (p *fakeProc) Exited() <-chan struct{} { return p.exited }

func (p *fakeProc) signal(name string) {
	p.mu.Lock()
	if p.exitedOnce {
		p.mu.Unlock()
		return
	}
	p.got = append(p.got, name)
	p.mu.Unlock()
	select {
	case p.sigs <- name:
	default:
	}
}

// finish ends the blocked turn with turn_done complete.
func (p *fakeProc) finish() { p.finishC <- struct{}{} }

func (p *fakeProc) log() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.got)
}

func (p *fakeProc) turnCommands() []chat.Command {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.turns)
}

func (p *fakeProc) isExited() bool {
	select {
	case <-p.exited:
		return true
	default:
		return false
	}
}

// read decodes stdin into the command buffer, never blocking the writer.
func (p *fakeProc) read() {
	sc := bufio.NewScanner(p.inR)
	sc.Buffer(make([]byte, 0, 64<<10), 8<<20)
	for sc.Scan() {
		var c chat.Command
		if json.Unmarshal(sc.Bytes(), &c) != nil {
			continue
		}
		p.mu.Lock()
		p.got = append(p.got, c.Type)
		if c.Type == chat.CommandTurn {
			p.turns = append(p.turns, c)
		}
		p.mu.Unlock()
		p.cmds <- c
	}
}

func (p *fakeProc) emit(ev chat.Event) {
	b, _ := json.Marshal(ev)
	_, _ = p.outW.Write(append(b, '\n'))
}

func (p *fakeProc) run(n int) {
	defer p.exit()
	o := p.f.opts
	if o.junk != "" {
		_, _ = p.outW.Write([]byte(o.junk + "\n"))
	}
	p.emit(chat.Event{Type: chat.EventSessionReady, SessionID: fmt.Sprintf("sid-%d", n), Provider: "claude",
		Model: fmt.Sprintf("model-%d", n)})
	text := o.text
	if text == "" {
		text = "partial answer"
	}
	turn := ""
	for {
		select {
		case c := <-p.cmds:
			switch c.Type {
			case chat.CommandTurn:
				turn = c.TurnID
				p.emit(chat.Event{Type: chat.EventTurnStart, TurnID: turn})
				p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: turn, Text: text})
				if !o.block {
					p.emit(chat.Event{Type: chat.EventTurnDone, TurnID: turn, Status: chat.StatusComplete})
					turn = ""
				}
			case chat.CommandCancel:
				if !o.ignoreCancel && turn != "" {
					p.emit(chat.Event{Type: chat.EventTurnDone, TurnID: turn, Status: chat.StatusInterrupted})
					turn = ""
				}
			case chat.CommandClose:
				if !o.ignoreClose {
					return
				}
			}
		case sig := <-p.sigs:
			if sig == "KILL" || !o.ignoreTerm {
				return
			}
		case <-p.finishC:
			if turn != "" {
				p.emit(chat.Event{Type: chat.EventTurnDone, TurnID: turn, Status: chat.StatusComplete})
				turn = ""
			}
		}
	}
}

func (p *fakeProc) exit() {
	_ = p.outW.Close()
	_ = p.inR.Close()
	p.mu.Lock()
	p.exitedOnce = true
	p.mu.Unlock()
	p.f.mu.Lock()
	p.f.alive--
	p.f.mu.Unlock()
	close(p.exited)
}
