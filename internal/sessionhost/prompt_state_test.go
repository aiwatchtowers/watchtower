package sessionhost

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"slices"
	"strings"
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

// TestDraftFixture pins the draft model to testdata/draft_cases.json, which
// Swift's DraftModel reads too (DraftModelFixtureTests): one key table on
// both sides of the delivery.
func TestDraftFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/draft_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Checked string `json:"claude_code_checked"`
		Cases   []struct {
			Name    string   `json:"name"`
			Profile string   `json:"profile"`
			Keys    []string `json:"keys"`
			Dialog  bool     `json:"dialog"`
			App     *struct {
				After int    `json:"after"`
				Line  string `json:"line"`
				Pause bool   `json:"pause"`
			} `json:"app"`
			Expect struct {
				Count int  `json:"count"`
				Exact bool `json:"exact"`
				Holds bool `json:"holds"`
			} `json:"expect"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &fx); err != nil {
		t.Fatal(err)
	}
	if fx.Checked == "" || len(fx.Cases) == 0 {
		t.Fatal("no claude_code_checked or no cases")
	}
	for _, c := range fx.Cases {
		prof := ProfileFor(c.Profile)
		p := promptState{dialog: c.Dialog}
		for i := 0; i <= len(c.Keys); i++ {
			if c.App != nil && c.App.After == i {
				p.pasteLine(PastePayload(c.App.Line), c.App.Pause)
			}
			if i < len(c.Keys) {
				p.ownerInput([]byte(c.Keys[i]), prof)
			}
		}
		d := p.draft
		if d.count != c.Expect.Count || d.inexact == c.Expect.Exact || d.holdsText() != c.Expect.Holds {
			t.Errorf("%s: {count %d, exact %v, holds %v}, want %+v", c.Name, d.count, !d.inexact, d.holdsText(), c.Expect)
		}
	}
}

// §6.2: a line held over the owner's draft (hold_if_prompt_text — a phone
// line, an agent message) goes on its next try once the owner erased the
// draft with Backspace; it was held, nothing written, while the text was
// there. The tries are the holders' own (the hub's state lane, the
// daemon's message deliverer); the host answers each from the draft model.
func TestPromptState_ReleaseRetriesHeld(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	held := st.req("x")
	held.HoldIfPromptText = true

	st.desktop.typeChunks([]byte("a"), []byte("b"))
	wantOutcome(t, st.deliver(cl, held, noCheck(t)), OutcomeHeld, HeldPromptHasText)
	st.desktop.typeChunks([]byte{0x7F})
	wantOutcome(t, st.deliver(cl, held, noCheck(t)), OutcomeHeld, HeldPromptHasText)
	st.desktop.typeChunks([]byte{0x7F})
	wantOutcome(t, st.deliver(cl, held, nil), OutcomeSubmitted, "")
	wantBytes(t, st.written(), cat([]byte("ab\x7f\x7f"), paste("x"), []byte{0x0D}), "the erased draft, then the line")

	// After a cursor key the erase is not trusted: still held.
	st.desktop.typeChunks([]byte("c"), []byte("\x1b[D"), []byte{0x7F})
	wantOutcome(t, st.deliver(cl, held, noCheck(t)), OutcomeHeld, HeldPromptHasText)
}

// Spec "Restart": a new run of the row starts with an empty, exact prompt,
// whatever the run before held.
func TestPromptState_NewRunEmpty(t *testing.T) {
	path, srv := startHost(t, Options{})
	a := dial(t, path)
	a.launchAgent(1, "claude", `exec cat`)
	a.typeChunks([]byte("half"), []byte("\x1b[D"))
	if !hostSession(t, srv, 1).promptHoldsText() {
		t.Fatal("no draft in the first run")
	}

	b := dial(t, path)
	b.send(Launch, LaunchReq{
		Row: 1, Run: "r2", Executable: "/bin/sh", Args: []string{"-c", `exec cat`},
		Cwd: os.TempDir(), Cols: 80, Rows: 24, Agent: "claude",
	})
	var info SessionInfo
	if err := json.Unmarshal(b.expect(Launched), &info); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reap(t, info.Pid) })
	next := srv.lookup(1, "r2")
	if next == nil {
		t.Fatal("no second run")
	}
	next.mu.Lock()
	got := next.prompt
	next.mu.Unlock()
	if got.draft.count != 0 || got.draft.inexact || got.draft.run != nil || got.holdsText() {
		t.Fatalf("a new run's prompt = %+v", got)
	}
}

// Review round 1: once the owner's own Return sent the pasted line during its
// pause, their next keys are a draft of their own, kept exact: typed and
// erased, it holds nothing (the line in its pause still holds until the pause
// ends).
func TestPromptState_OwnerReturnInPauseKeepsTheNextDraftExact(t *testing.T) {
	prof := ProfileFor("claude")
	var p promptState
	p.beginPause()
	p.ownerInput([]byte("x"), prof)
	if !p.draft.inexact {
		t.Fatal("a key into the waiting line kept the draft exact")
	}

	p = promptState{}
	p.beginPause()
	p.ownerInput([]byte{0x0D}, prof)
	p.ownerInput([]byte("n"), prof)
	p.ownerInput([]byte{0x7F}, prof)
	if p.draft.holdsText() {
		t.Fatalf("an erased draft after the owner's Return in the pause = %+v", p.draft)
	}
	if !p.endPause() || p.holdsText() {
		t.Fatal("the owner's Return in the pause no longer sends the line, or the prompt still holds")
	}
}

// Review round 3: a long single-line paste is read in linear time — the
// run grows by appending, never by copying itself — so the allocations of
// a paste twice as long stay within a few of the shorter one's (counted,
// never timed).
func TestDraftLongPasteIsLinear(t *testing.T) {
	allocs := func(n int) float64 {
		chunk := []byte(strings.Repeat("x", n))
		return testing.AllocsPerRun(3, func() {
			var d draftModel
			prof := ProfileFor("claude")
			d.feed([]byte(escPasteStart), prof, false)
			d.feed(chunk, prof, false)
			d.feed([]byte(escPasteEnd), prof, false)
			if d.count != n || d.inexact {
				t.Fatalf("paste of %d = %+v", n, d.count)
			}
		})
	}
	short, long := allocs(100<<10), allocs(200<<10)
	if long > short+4 {
		t.Fatalf("allocations: %v for 100 KiB, %v for 200 KiB — not linear", short, long)
	}
}

// Review round 4: a line the delivery left typed beside the owner's draft
// moves the cursor past the owner's run. The owner had `a\`, the delivery
// pasted `\x`; a Backspace leaves `a\\` in the prompt, so the owner's Return
// is a line break and a phone line is still held.
func TestPromptState_LineLeftTypedRestartsTheRun(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	held := st.req("y")
	held.HoldIfPromptText = true

	st.desktop.typeChunks([]byte("a"), []byte(`\`))
	beside := st.req(`\x`)
	wantOutcome(t, st.deliver(cl, beside, noCheck(t)), OutcomeTyped, TypedBesideText)
	st.desktop.typeChunks([]byte{0x7F}, []byte{0x0D})
	wantOutcome(t, st.deliver(cl, held, noCheck(t)), OutcomeHeld, HeldPromptHasText)
}

// Review rounds 4–5: a line ending in `\` never waits for a Return of its
// own (Claude Code reads one there as a line break): it is left typed and
// holds, and the owner's Return after it is a line break too. In a line's
// pause, a Backspace reaches the line, so what precedes the cursor is unknown
// and the next Return is no submit. The delivery's own Return after any
// other line empties the prompt.
func TestPromptState_LineInPauseSetsTheBackslash(t *testing.T) {
	prof := ProfileFor("claude")
	var p promptState
	if p.pasteLine(PastePayload(`x\`), true) {
		t.Fatal("a line ending in `\\` waits for a Return of its own")
	}
	if !p.holdsText() || !p.draft.holdsText() {
		t.Fatalf("a line ending in `\\` left typed holds nothing: %+v", p)
	}
	p.ownerInput([]byte{0x0D}, prof)
	if !p.draft.holdsText() {
		t.Fatalf("the owner's Return after a pasted `\\` read as a submit: %+v", p)
	}

	p = promptState{}
	if !p.pasteLine(PastePayload(`\x`), true) {
		t.Fatal("no pause for `\\x` into an empty prompt")
	}
	p.ownerInput([]byte{0x7F, 0x0D}, prof)
	if p.ownerReturnInPause || !p.draft.holdsText() {
		t.Fatalf("Backspace then Return into a pasted `\\x` read as a submit: %+v", p)
	}

	p = promptState{}
	if !p.pasteLine(PastePayload(`x`), true) {
		t.Fatal("no pause for `x` into an empty prompt")
	}
	p.endPause()
	p.appSubmitted()
	if p.holdsText() || p.draft.backslash || p.draft.appLine {
		t.Fatalf("after the delivery's Return = %+v", p.draft)
	}
}

// Review round 5: a line ending in `\` asked to submit is left typed through
// Deliver — no Return of ours, `ends_in_backslash` — and the next phone line
// is held over it.
func TestDeliverLeavesALineEndingInBackslashTyped(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	wantOutcome(t, st.deliver(cl, st.req(`x\`), noCheck(t)), OutcomeTyped, TypedEndsInBackslash)
	wantBytes(t, st.written(), paste(`x\`), "the line, no Return")
	held := st.req("y")
	held.HoldIfPromptText = true
	wantOutcome(t, st.deliver(cl, held, noCheck(t)), OutcomeHeld, HeldPromptHasText)
}

// Review round 5: a permission dialog may have taken a line pasted without
// hold_if_prompt_text, so the owner's `\` before it stays possible: their
// Return is no submit.
func TestPromptState_PasteKeepsTheOwnersBackslash(t *testing.T) {
	prof := ProfileFor("claude")
	var p promptState
	p.ownerInput([]byte(`a\`), prof)
	p.pasteLine(PastePayload("x"), false)
	p.ownerInput([]byte{0x0D}, prof)
	if !p.draft.holdsText() {
		t.Fatalf("the owner's Return after their `\\` and a paste read as a submit: %+v", p.draft)
	}
}

// Review round 4: only a profile with ExactDraft reads the run (its
// Backspace), so Codex and an unidentified agent keep none; a submit and an
// inexact turn drop a long run's buffer.
func TestDraftRunIsKeptOnlyWhereRead(t *testing.T) {
	long := []byte(strings.Repeat("x", 4096))
	for _, agent := range []string{"codex", ""} {
		var d draftModel
		d.feed(long, ProfileFor(agent), false)
		if d.run != nil {
			t.Errorf("%q: run of %d kept", agent, len(d.run))
		}
	}

	prof := ProfileFor("claude")
	var d draftModel
	d.feed(long, prof, false)
	if len(d.run) != len(long) {
		t.Fatalf("claude: run %d, want %d", len(d.run), len(long))
	}
	d.feed([]byte{0x0D}, prof, false)
	if d.run != nil {
		t.Fatalf("after a submit the run keeps a buffer of %d", cap(d.run))
	}
	d.feed(long, prof, false)
	d.feed([]byte{'\t'}, prof, false)
	if d.run != nil {
		t.Fatalf("after an inexact key the run keeps a buffer of %d", cap(d.run))
	}
}
