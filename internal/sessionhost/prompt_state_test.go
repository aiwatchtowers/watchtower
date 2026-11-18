package sessionhost

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"slices"
	"testing"
	"testing/synctest"
	"time"
)

// fakeV2Host serves like an adopted v2 host: HelloOK version 2 with
// features, then it reads every later frame and answers none (an older host
// skips a frame it does not know). frames receives the number it read once
// the client hung up.
func fakeV2Host(nc net.Conn, features []string) (frames <-chan int) {
	ch := make(chan int, 1)
	go func() {
		defer func() { _ = nc.Close() }()
		if _, _, err := ReadFrame(nc); err != nil {
			ch <- -1
			return
		}
		if err := WriteFrame(nc, HelloOK, encode(HelloMsg{Version: ProtocolVersion, Pid: 1, Features: features})); err != nil {
			ch <- -1
			return
		}
		n := 0
		for {
			if _, _, err := ReadFrame(nc); err != nil {
				ch <- n
				return
			}
			n++
		}
	}()
	return ch
}

// A host that answers PromptState says so in HelloOK's features; a v2 hello
// without them (an adopted older host) still decodes, with no features.
func TestPromptStateAdvertisedInHello(t *testing.T) {
	cl, err := Dial(ctxT(t), startServer(t, Options{}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cl.Close() })
	if !slices.Contains(cl.Features(), FeaturePromptState) {
		t.Fatalf("features = %v, want %q", cl.Features(), FeaturePromptState)
	}

	var h HelloMsg
	if err := json.Unmarshal([]byte(`{"version":2,"pid":7}`), &h); err != nil {
		t.Fatal(err)
	}
	if h.Version != 2 || h.Pid != 7 || h.Features != nil {
		t.Fatalf("featureless v2 hello = %+v", h)
	}
	if p := encode(HelloMsg{Version: 2}); string(p) != `{"version":2}` {
		t.Fatalf("a hello without features encodes as %s", p)
	}
}

// PromptState reads the prompt state and writes nothing: an empty prompt is
// false, the owner's draft true, and the PTY gets no byte either time.
func TestPromptStateReadsWithoutWriting(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	req := PromptStateMsg{Row: st.info.Row, Run: st.info.Run, Launch: st.info.Launch}

	got, err := cl.PromptState(ctxT(t), req)
	if err != nil || got != (PromptStateReplyMsg{HoldsText: false, Known: true}) {
		t.Fatalf("empty prompt = %+v, %v", got, err)
	}
	wantBytes(t, st.written(), nil, "after the empty read")

	st.desktop.typeChunks([]byte("a"), []byte("b"))
	wantBytes(t, st.written(), []byte("ab"), "the draft")
	got, err = cl.PromptState(ctxT(t), req)
	if err != nil || got != (PromptStateReplyMsg{HoldsText: true, Known: true}) {
		t.Fatalf("draft = %+v, %v", got, err)
	}
	wantBytes(t, st.written(), nil, "after the draft read")

	// Another launch is refused by the host, never answered for this one.
	stale := req
	stale.Launch++
	got, err = cl.PromptState(ctxT(t), stale)
	var he *HostError
	if !errors.As(err, &he) || got.Known {
		t.Fatalf("another launch = %+v, %v; want a host error, unknown", got, err)
	}
	if cl.Dead() {
		t.Fatal("a host error closed the connection")
	}
}

// §7 "message flag" row 1: a host that never answers leaves the prompt
// unknown once the caller's deadline passes (never "empty"), and the
// connection, out of step, is closed.
func TestPromptStateTimeoutIsUnknown(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		clientEnd, hostEnd := net.Pipe()
		frames := fakeV2Host(hostEnd, []string{FeaturePromptState})
		cl, err := NewClient(t.Context(), clientEnd)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(t.Context(), PromptStateTimeout)
		defer cancel()
		start := time.Now()

		got, err := cl.PromptState(ctx, PromptStateMsg{Row: 1, Run: "r1", Launch: 1})

		if err == nil || got.Known || got.HoldsText {
			t.Fatalf("silent host = %+v, %v; want an error, unknown", got, err)
		}
		if waited := time.Since(start); waited != PromptStateTimeout {
			t.Fatalf("gave up after %v, want %v", waited, PromptStateTimeout)
		}
		if !cl.Dead() {
			t.Fatal("the client kept a connection out of step")
		}
		if n := <-frames; n != 1 {
			t.Fatalf("host read %d frames after hello, want the one request", n)
		}
	})
}

// §7 "message flag" row 2: a v2 host whose HelloOK names no prompt_state is
// never sent the request (it would skip it and never answer): the call is
// ErrFeatureMissing, no byte follows the hello, the host is no v1 host and
// the connection stays usable.
func TestPromptStateNeverSentWithoutTheFeature(t *testing.T) {
	path := socketPath(t)
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	accepted := make(chan (<-chan int), 1)
	go func() {
		nc, err := l.Accept()
		if err != nil {
			close(accepted)
			return
		}
		accepted <- fakeV2Host(nc, nil)
	}()

	cl, err := Dial(ctxT(t), path)
	if err != nil {
		t.Fatalf("Dial featureless v2 host = %v (ErrHostV1: %v)", err, errors.Is(err, ErrHostV1))
	}
	got, err := cl.PromptState(ctxT(t), PromptStateMsg{Row: 1, Run: "r1", Launch: 1})
	if !errors.Is(err, ErrFeatureMissing) || got.Known {
		t.Fatalf("featureless host = %+v, %v; want ErrFeatureMissing, unknown", got, err)
	}
	if cl.Dead() {
		t.Fatal("a missing feature closed the connection")
	}
	_ = cl.Close()
	frames, ok := <-accepted
	if !ok {
		t.Fatal("the fake host accepted nothing")
	}
	if n := <-frames; n != 0 {
		t.Fatalf("host read %d frames after hello, want none", n)
	}
}

// A call waiting for the client while another holds it (a host stuck on
// that call) gives up with its own ctx: PromptState is unknown after exactly
// its deadline and sends nothing.
func TestPromptStateWaitingBehindABusyCallEndsAtItsDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		clientEnd, hostEnd := net.Pipe()
		frames := fakeV2Host(hostEnd, []string{FeaturePromptState})
		cl, err := NewClient(t.Context(), clientEnd)
		if err != nil {
			t.Fatal(err)
		}
		listed := make(chan error, 1)
		go func() {
			_, err := cl.List(context.Background())
			listed <- err
		}()
		synctest.Wait() // the List holds the client

		ctx, cancel := context.WithTimeout(t.Context(), PromptStateTimeout)
		defer cancel()
		start := time.Now()
		got, err := cl.PromptState(ctx, PromptStateMsg{Row: 1, Run: "r1", Launch: 1})

		if !errors.Is(err, context.DeadlineExceeded) || got.Known {
			t.Fatalf("behind a busy call = %+v, %v; want the deadline, unknown", got, err)
		}
		if waited := time.Since(start); waited != PromptStateTimeout {
			t.Fatalf("gave up after %v, want %v", waited, PromptStateTimeout)
		}
		_ = cl.Close()
		if err := <-listed; err == nil {
			t.Fatal("the stuck List succeeded")
		}
		if n := <-frames; n != 1 {
			t.Fatalf("host read %d frames after hello, want only the List", n)
		}
	})
}
