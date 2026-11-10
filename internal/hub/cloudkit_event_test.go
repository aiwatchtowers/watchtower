package hub

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// gatedFake is the memfake with its events under the test's control: while
// gated, the fake's own events are dropped and only injected ones reach the
// runtime.
type gatedFake struct {
	*memfake.Fake
	out chan transport.Event

	mu    sync.Mutex
	gated bool
}

func (g *gatedFake) Events() <-chan transport.Event { return g.out }

func (g *gatedFake) gate() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.gated = true
}

func (g *gatedFake) forward(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-g.Fake.Events():
			g.mu.Lock()
			gated := g.gated
			g.mu.Unlock()
			if !gated {
				select {
				case g.out <- ev:
				case <-ctx.Done():
					return
				}
			}
		}
	}
}

// TestSharedMailboxEventRunsAPass: the CloudKit client names its one
// RelayZone's events transport.SharedMailboxZone(relay id); today's runtime
// reads that as a mailbox event and runs a pass at once — with the pass and
// link timers out of the way and the transport's own events held back.
func TestSharedMailboxEventRunsAPass(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	g := &gatedFake{out: make(chan transport.Event, 64)}
	var passes atomic.Int64
	e := runEndToEnd(t, "", func(o *Options) {
		o.passEvery, o.linkEvery = time.Hour, time.Hour
		o.onPass = func() { passes.Add(1) }
		orig := o.newTransport
		o.newTransport = func(ctx2 context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error) {
			tr, err := orig(ctx2, id, st, zones)
			if err != nil {
				return nil, err
			}
			if g.Fake == nil {
				g.Fake = tr.(*memfake.Fake)
				go g.forward(ctx)
			}
			return g, nil
		}
	})
	status, err := ReadStatus(e.dir)
	if err != nil {
		t.Fatal(err)
	}
	g.gate()
	// The startup's events, already forwarded, are consumed (each may run a
	// pass) before the count is taken.
	eventually(t, 10*time.Second, "the startup events consumed", func() bool { return len(g.out) == 0 })
	settled := passes.Load()
	for {
		time.Sleep(100 * time.Millisecond)
		if n := passes.Load(); n == settled {
			break
		} else {
			settled = n
		}
	}
	seq, err := e.phone.Act("probe")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.phone.Sync(); err != nil {
		t.Fatal(err)
	}
	if n := passes.Load(); n != settled || e.phone.Echoes[seq].Status != "" {
		t.Fatalf("a pass ran without an event (%d passes, echo %q): the test proves nothing", n-settled, e.phone.Echoes[seq].Status)
	}
	g.out <- transport.Event{Zone: transport.SharedMailboxZone(status.RelayDeviceID)}
	eventually(t, 10*time.Second, "the echo after the shared mailbox event", func() bool {
		if _, err := e.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return e.phone.Echoes[seq].Status != ""
	})
	if passes.Load() == settled {
		t.Fatal("the echo came without a pass")
	}
}
