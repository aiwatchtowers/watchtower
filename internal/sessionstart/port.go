package sessionstart

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionhost"
)

// ErrNotRunning means the session has no running launch of that run in this
// workspace's scope.
var ErrNotRunning = errors.New("the session is not running")

// Port is the hub's handlers.SessionPort over session-host. It holds two
// connections: one only for Deliver, which keeps its client for the pause
// plus up to sessionhost.CheckTimeout of re-check, and one for everything
// else (lists, launches, InputTo, stops), so a delivery never holds a list
// or an Interrupt up. A connection that failed is dropped and dialled again
// (the host started first when none answers) on the next call. Starts it
// begins return at once (instant start); Close ends them first.
type Port struct {
	d       Deps
	deliver slot
	control slot

	base   context.Context
	cancel context.CancelFunc
	starts sync.WaitGroup
}

// NewPort is the hub's session port (a handlers.SessionPort); client (may
// be nil: dialled on first use) is its delivery connection.
func NewPort(d Deps, client *sessionhost.Client) *Port { return newPort(d, client) }

var _ handlers.SessionPort = (*Port)(nil)

// OpenPort makes sure a host answers (starting one when none does) and
// returns the port on a fresh delivery connection; Close it with the hub.
func OpenPort(ctx context.Context, d Deps) (*Port, error) {
	c, err := dialHost(ctx, d.socket(), d.CLIPath)
	if err != nil {
		return nil, err
	}
	return newPort(d, c), nil
}

func newPort(d Deps, client *sessionhost.Client) *Port {
	base, cancel := context.WithCancel(context.Background())
	p := &Port{d: d, base: base, cancel: cancel}
	p.deliver = slot{socket: d.socket(), exe: d.CLIPath, c: client}
	p.control = slot{socket: d.socket(), exe: d.CLIPath}
	return p
}

// Warm reaches the host now (starting one when none answers) on the
// delivery connection, instead of at the first session action.
func (p *Port) Warm(ctx context.Context) error {
	_, err := p.deliver.get(ctx)
	return err
}

// Close cancels the starts in flight (a cut launch is recorded on its row),
// waits for them, then closes both connections; the hosted sessions keep
// running.
func (p *Port) Close() error {
	p.cancel()
	p.starts.Wait()
	p.deliver.close()
	p.control.close()
	return nil
}

// Live reads the session from the host's list, this workspace's scope only.
func (p *Port) Live(ctx context.Context, sessionID int64) (handlers.LiveRun, bool, error) {
	info, ok, err := p.find(ctx, sessionID)
	if err != nil || !ok {
		return handlers.LiveRun{}, false, err
	}
	l := handlers.LiveRun{SessionID: sessionID, Run: info.Launch, Agent: info.Agent, Exited: info.Exited}
	if info.StartedAtMs > 0 {
		l.StartedAt = time.UnixMilli(info.StartedAtMs)
	}
	return l, true, nil
}

// Deliver types one line through the host's typed-never-submitted delivery
// (PROJ-12): the caller's check runs once before the paste (its answer is
// the request's SubmitIf: no Return unless the hooks reported and no dialog
// shows) and again after the pause. A launch other than r.Run, or none, is
// no_session; a text that cleans to nothing comes back as the host's error.
func (p *Port) Deliver(ctx context.Context, r handlers.DeliverRequest) (handlers.DeliverResult, error) {
	info, ok, err := p.find(ctx, r.SessionID)
	if err != nil {
		return handlers.DeliverResult{}, err
	}
	if !ok || info.Exited || info.Launch != r.Run {
		return handlers.DeliverResult{Outcome: handlers.DeliverNoSession}, nil
	}
	check := func(ctx context.Context) sessionhost.DeliverCheckReplyMsg {
		if r.Check == nil {
			return sessionhost.DeliverCheckReplyMsg{Fresh: true, CanSubmit: true}
		}
		a := r.Check(ctx)
		return sessionhost.DeliverCheckReplyMsg{Fresh: a.Fresh, CanSubmit: a.CanSubmit, AnswersDialog: a.AnswersDialog}
	}
	pctx, cancel := context.WithTimeout(ctx, sessionhost.CheckTimeout)
	pre := check(pctx)
	cancel()
	c, err := p.deliver.get(ctx)
	if err != nil {
		return handlers.DeliverResult{}, err
	}
	out, err := c.Deliver(ctx, sessionhost.DeliverReq{
		Row: info.Row, Run: info.Run, Launch: info.Launch, Text: r.Text,
		KeepLineBreaks: r.KeepLineBreaks, KeepFormat: r.KeepFormat, SettleMs: int(r.Settle / time.Millisecond),
		SubmitIf: pre.Fresh && pre.CanSubmit, HoldIfPromptText: r.HoldIfPromptText,
	}, check)
	p.deliver.done(c, err)
	if err != nil {
		return handlers.DeliverResult{}, fmt.Errorf("delivering into session %d: %w", r.SessionID, err)
	}
	return handlers.DeliverResult{Outcome: out.Outcome, Reason: out.Reason}, nil
}

// Interrupt writes one Esc to the session's run through InputTo: it never
// attaches and never counts as the owner's typing (PROJ-21).
func (p *Port) Interrupt(ctx context.Context, sessionID int64, run uint64) error {
	info, ok, err := p.find(ctx, sessionID)
	if err != nil {
		return err
	}
	if !ok || info.Exited || info.Launch != run {
		return ErrNotRunning
	}
	c, err := p.control.get(ctx)
	if err != nil {
		return err
	}
	err = c.InputTo(ctx, sessionhost.InputToReq{Row: info.Row, Run: info.Run, Launch: info.Launch, Data: []byte{0x1b}})
	p.control.done(c, err)
	if err != nil {
		return fmt.Errorf("interrupting session %d: %w", sessionID, err)
	}
	return nil
}

// Start starts a session (Start) and answers once its row is written; the
// placement and launch go on until Close.
func (p *Port) Start(ctx context.Context, r handlers.StartRequest) (handlers.StartResult, error) {
	d := p.d
	d.host = p.control.lease
	d.Go = p.goStart
	return Start(ctx, d, r)
}

func (p *Port) goStart(fn func(context.Context)) {
	p.starts.Add(1)
	go func() {
		defer p.starts.Done()
		ctx, cancel := context.WithTimeout(p.base, startBudget)
		defer cancel()
		fn(ctx)
	}()
}

// Stop is a host Stop request (Stop).
func (p *Port) Stop(ctx context.Context, sessionID int64) error {
	c, err := p.control.get(ctx)
	if err != nil {
		return err
	}
	err = stopOn(ctx, c, p.d.scope(), sessionID)
	p.control.done(c, err)
	return err
}

// find is the session's run in this scope on the control connection.
func (p *Port) find(ctx context.Context, sessionID int64) (sessionhost.SessionInfo, bool, error) {
	c, err := p.control.get(ctx)
	if err != nil {
		return sessionhost.SessionInfo{}, false, err
	}
	list, err := c.List(ctx)
	p.control.done(c, err)
	if err != nil {
		return sessionhost.SessionInfo{}, false, fmt.Errorf("listing the session host: %w", err)
	}
	info, ok := findRun(list, p.d.scope(), sessionID)
	return info, ok, nil
}

// slot is one lazily dialled host connection.
type slot struct {
	socket, exe string

	mu     sync.Mutex
	c      *sessionhost.Client
	closed bool
}

// errPortClosed answers a call after Close.
var errPortClosed = errors.New("the session port is closed")

func (s *slot) get(ctx context.Context) (*sessionhost.Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, errPortClosed
	}
	if s.c != nil {
		return s.c, nil
	}
	c, err := dialHost(ctx, s.socket, s.exe)
	if err != nil {
		return nil, err
	}
	s.c = c
	return c, nil
}

// done drops c after a failure that left its stream out of step (anything
// but the host's own Error answer): the next call dials again.
func (s *slot) done(c *sessionhost.Client, err error) {
	var he *sessionhost.HostError
	if err == nil || errors.As(err, &he) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.c == c {
		_ = s.c.Close()
		s.c = nil
	}
}

func (s *slot) lease(ctx context.Context) (*sessionhost.Client, func(error), error) {
	c, err := s.get(ctx)
	if err != nil {
		return nil, nil, err
	}
	return c, func(err error) { s.done(c, err) }, nil
}

func (s *slot) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.c != nil {
		_ = s.c.Close()
		s.c = nil
	}
}
