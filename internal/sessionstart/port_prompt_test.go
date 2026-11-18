package sessionstart

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/sessionhost"
)

// fakeHost is an in-memory v2 session host: it says HelloOK with features,
// answers List with sessions unless silent, and answers PromptStateReq with
// promptErr as an Error frame when set; anything else is read and never
// answered (a host stuck on another call, or one that drops the request).
type fakeHost struct {
	features  []string
	sessions  []sessionhost.SessionInfo
	silent    bool
	promptErr string
}

func (f fakeHost) dialer() func(context.Context) (*sessionhost.Client, error) {
	return func(ctx context.Context) (*sessionhost.Client, error) {
		client, host := net.Pipe()
		go f.serve(host)
		return sessionhost.NewClient(ctx, client)
	}
}

func (f fakeHost) serve(nc net.Conn) {
	defer func() { _ = nc.Close() }()
	reply := func(t sessionhost.FrameType, v any) bool {
		p, _ := json.Marshal(v)
		return sessionhost.WriteFrame(nc, t, p) == nil
	}
	if _, _, err := sessionhost.ReadFrame(nc); err != nil {
		return
	}
	if !reply(sessionhost.HelloOK, sessionhost.HelloMsg{Version: sessionhost.ProtocolVersion, Pid: 1, Features: f.features}) {
		return
	}
	for {
		t, _, err := sessionhost.ReadFrame(nc)
		if err != nil {
			return
		}
		switch {
		case f.silent:
		case t == sessionhost.List:
			if !reply(sessionhost.Listed, sessionhost.ListResp{Sessions: f.sessions}) {
				return
			}
		case t == sessionhost.PromptStateReq && f.promptErr != "":
			if !reply(sessionhost.Error, sessionhost.ErrorMsg{Message: f.promptErr}) {
				return
			}
		}
	}
}

// fakePort is a port whose control and prompt connections are fake hosts;
// its one session is row 1, launch 1, in the port's scope.
func fakePort(control, prompt fakeHost) *Port {
	d := Deps{Socket: "unused.sock", DBPath: "/tmp/acme/watchtower.db"}
	run := sessionhost.SessionInfo{Row: 1, Run: "r1", Launch: 1, Scope: d.scope()}
	control.sessions = []sessionhost.SessionInfo{run}
	prompt.sessions = []sessionhost.SessionInfo{run}
	p := newPort(d, nil)
	p.control.dial = control.dialer()
	p.prompt.dial = prompt.dialer()
	return p
}

// §7 "message flag" row 1 through the port: a control call stuck on its
// host never holds the read up, and a host that does not answer the read
// leaves it unknown after exactly PromptStateTimeout — for a second read
// waiting on the same connection too.
func TestPortPromptStateNeverWaitsPastItsBound(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := fakePort(fakeHost{silent: true}, fakeHost{features: []string{sessionhost.FeaturePromptState}})
		defer func() { _ = p.Close() }()
		controlDone := make(chan struct{})
		go func() {
			defer close(controlDone)
			_ = p.Interrupt(context.Background(), 1, 1)
		}()
		synctest.Wait() // the Interrupt holds the control connection

		start := time.Now()
		type read struct {
			known bool
			err   error
			after time.Duration
		}
		reads := make(chan read, 2)
		for range 2 {
			go func() {
				_, known, err := p.PromptState(context.Background(), 1, 1)
				reads <- read{known, err, time.Since(start)}
			}()
		}
		for range 2 {
			r := <-reads
			assert.Error(t, r.err)
			assert.False(t, r.known, "a timeout is unknown, never empty")
			assert.Equal(t, sessionhost.PromptStateTimeout, r.after)
		}
		select {
		case <-controlDone:
			t.Fatal("the stuck control call ended before the port closed")
		default:
		}
		_ = p.Close()
		<-controlDone
	})
}

// A run that exits between the list and the read is ErrNotRunning, the same
// answer as a run the list did not show, not the host's error.
func TestPortPromptStateOfARunThatExitedIsNotRunning(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := fakePort(fakeHost{}, fakeHost{
			features:  []string{sessionhost.FeaturePromptState},
			promptErr: `prompt_state: session row 1 run "r1" is not running`,
		})
		defer func() { _ = p.Close() }()
		_, known, err := p.PromptState(context.Background(), 1, 1)
		require.ErrorIs(t, err, ErrNotRunning)
		var he *sessionhost.HostError
		assert.False(t, errors.As(err, &he), "the host's error does not leak")
		assert.False(t, known)

		_, known, err = p.PromptState(context.Background(), 1, 2)
		assert.ErrorIs(t, err, ErrNotRunning, "another launch")
		assert.False(t, known)
	})
}

// Any other refusal of the host stays its error, still unknown.
func TestPortPromptStateKeepsTheHostsOtherErrors(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := fakePort(fakeHost{}, fakeHost{
			features:  []string{sessionhost.FeaturePromptState},
			promptErr: "prompt_state: bad request: unexpected end of JSON input",
		})
		defer func() { _ = p.Close() }()
		_, known, err := p.PromptState(context.Background(), 1, 1)
		var he *sessionhost.HostError
		assert.True(t, errors.As(err, &he), "the host's own error: %v", err)
		assert.NotErrorIs(t, err, ErrNotRunning)
		assert.False(t, known)
	})
}

// slowDial is a slot dial whose first call answers at once and every later
// one only after slowDialTook (a host being started, a loaded machine).
const slowDialTook = 10 * time.Second

func slowDial(h fakeHost) (dial func(context.Context) (*sessionhost.Client, error), dials *int) {
	n := 0
	fast := h.dialer()
	return func(ctx context.Context) (*sessionhost.Client, error) {
		n++
		if n > 1 {
			time.Sleep(slowDialTook)
		}
		return fast(ctx)
	}, &n
}

// A caller whose client died (at its deadline) never waits in done for
// another caller's redial holding the slot: done returns at once, and the
// redial replaces the dead client itself.
func TestPortSlotDoneNeverWaitsForARedial(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		s := newSlot("unused.sock", nil, "", true)
		dial, dials := slowDial(fakeHost{features: []string{sessionhost.FeaturePromptState}})
		s.dial = dial
		defer s.close()
		dead, err := s.get(context.Background())
		require.NoError(t, err)
		_ = dead.Close() // as a read that ran out its deadline leaves it

		redialled := make(chan *sessionhost.Client, 1)
		go func() {
			c, err := s.get(context.Background())
			assert.NoError(t, err)
			redialled <- c
		}()
		synctest.Wait() // the redial holds the slot

		start := time.Now()
		s.done(dead, context.DeadlineExceeded)
		assert.Equal(t, time.Duration(0), time.Since(start), "done waited for the redial")

		fresh := <-redialled
		assert.NotSame(t, dead, fresh)
		assert.False(t, fresh.Dead())
		assert.Equal(t, 2, *dials)
		assert.Equal(t, slowDialTook, time.Since(start))
	})
}

// A read waiting for the slot behind another caller's slow dial leaves at
// its own deadline, unknown.
func TestPortPromptStateBehindASlowDialLeavesAtItsDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := fakePort(fakeHost{}, fakeHost{})
		dial, _ := slowDial(fakeHost{features: []string{sessionhost.FeaturePromptState}})
		first, err := dial(context.Background()) // spend the fast first dial: every dial now is slow
		require.NoError(t, err)
		_ = first.Close()
		p.prompt.dial = dial
		defer func() { _ = p.Close() }()
		dialled := make(chan struct{})
		go func() {
			defer close(dialled)
			_, _ = p.prompt.get(context.Background())
		}()
		synctest.Wait() // the slow dial holds the slot

		start := time.Now()
		_, known, err := p.PromptState(context.Background(), 1, 1)
		assert.ErrorIs(t, err, context.DeadlineExceeded)
		assert.False(t, known)
		assert.Equal(t, sessionhost.PromptStateTimeout, time.Since(start))
		<-dialled
	})
}

// A host without the feature is never asked: ErrFeatureMissing, unknown.
func TestPortPromptStateWithoutTheFeatureIsUnknown(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := fakePort(fakeHost{}, fakeHost{})
		defer func() { _ = p.Close() }()
		_, known, err := p.PromptState(context.Background(), 1, 1)
		assert.ErrorIs(t, err, sessionhost.ErrFeatureMissing)
		assert.False(t, known)
	})
}
