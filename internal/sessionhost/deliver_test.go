package sessionhost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Go twins of the PROJ-12 delivery guards (WatchtowerDesktop
// TerminalCenterTests / TerminalCenterSubmitTests), run against a real
// Server and real PTYs: the stub agent puts its terminal in raw mode, turns
// bracketed paste on and echoes every byte it is given, so the session's
// output ring is exactly what reached the PTY. The owner's typing comes as
// Input frames from an attached "Desktop" client; the hub delivers through a
// non-attaching Client.

const rawEchoAgent = `stty raw -echo; printf '\033[?2004h'; exec cat`

// testSettle is the pause the tests deliver with (fast, still a real sleep).
const testSettle = 60

// stubSession is one hosted stub agent with its attached Desktop pane.
type stubSession struct {
	t       *testing.T
	srv     *Server
	path    string
	desktop *client
	info    SessionInfo
	sess    *session
	from    int // ring offset up to which bytes were read
	marks   int
}

func newStub(t *testing.T, opts Options, agent, script string) *stubSession {
	t.Helper()
	path, srv := startHost(t, opts)
	return launchStub(t, srv, path, 1, agent, script)
}

func launchStub(t *testing.T, srv *Server, path string, row int64, agent, script string) *stubSession {
	t.Helper()
	d := dial(t, path)
	info := d.launchAgent(row, agent, script)
	sess := srv.lookup(row, "r1")
	if sess == nil {
		t.Fatal("no session")
	}
	st := &stubSession{t: t, srv: srv, path: path, desktop: d, info: info, sess: sess}
	if strings.Contains(script, "2004h") {
		st.waitRing("\x1b[?2004h")
		st.from = len("\x1b[?2004h")
	} else {
		st.waitRing("ready")
		st.from = len("ready")
	}
	return st
}

func (st *stubSession) ring() []byte {
	st.sess.mu.Lock()
	defer st.sess.mu.Unlock()
	return st.sess.ring.Snapshot()
}

func (st *stubSession) waitRing(want string) []byte {
	st.t.Helper()
	deadline := time.Now().Add(ioTimeout)
	for {
		r := st.ring()
		if bytes.Contains(r, []byte(want)) {
			return r
		}
		if time.Now().After(deadline) {
			st.t.Fatalf("ring never held %q: %q", want, r)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// written returns the bytes the PTY was given since the last call: a marker
// written straight to the PTY after them (past the prompt state, like an
// InputTo) closes the segment once the stub echoed it.
func (st *stubSession) written() []byte {
	st.t.Helper()
	st.marks++
	mark := fmt.Sprintf("<mark%d>", st.marks)
	if _, err := st.sess.ptmx.Write([]byte(mark)); err != nil {
		st.t.Fatal(err)
	}
	r := st.waitRing(mark)
	end := bytes.Index(r, []byte(mark))
	seg := append([]byte(nil), r[st.from:end]...)
	st.from = end + len(mark)
	return seg
}

func (st *stubSession) hub() *Client {
	st.t.Helper()
	cl, err := Dial(ctxT(st.t), st.path)
	if err != nil {
		st.t.Fatal(err)
	}
	st.t.Cleanup(func() { _ = cl.Close() })
	return cl
}

func (st *stubSession) req(text string) DeliverReq {
	return DeliverReq{Row: st.info.Row, Run: st.info.Run, Launch: st.info.Launch, Text: text,
		SettleMs: testSettle, SubmitIf: true}
}

func (st *stubSession) deliver(cl *Client, r DeliverReq, check func(context.Context) DeliverCheckReplyMsg) DeliveredMsg {
	st.t.Helper()
	if check == nil {
		check = okCheck
	}
	out, err := cl.Deliver(ctxT(st.t), r, check)
	if err != nil {
		st.t.Fatal(err)
	}
	return out
}

func okCheck(context.Context) DeliverCheckReplyMsg {
	return DeliverCheckReplyMsg{Fresh: true, CanSubmit: true}
}

func noCheck(t *testing.T) func(context.Context) DeliverCheckReplyMsg {
	return func(context.Context) DeliverCheckReplyMsg {
		t.Error("re-check asked for a line that only pastes")
		return DeliverCheckReplyMsg{}
	}
}

func paste(s string) []byte { return PastePayload(s) }

func cat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

func wantOutcome(t *testing.T, got DeliveredMsg, outcome, reason string) {
	t.Helper()
	if got.Outcome != outcome || (reason != "" && got.Reason != reason) {
		t.Fatalf("delivered = %+v, want %s %s", got, outcome, reason)
	}
}

func wantBytes(t *testing.T, got, want []byte, what string) {
	t.Helper()
	if !bytes.Equal(got, want) {
		t.Fatalf("%s: written %q, want %q", what, got, want)
	}
}

// Twin of testAnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn:
// one bracketed paste with no control byte inside, then the Return alone,
// strictly after the pause.
func TestProj12_AnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	line := "Ask #7 answered (choice: yes)\n— read it\twith get_ask 7"
	start := time.Now()
	var atCheck []byte
	out := st.deliver(st.hub(), st.req(line), func(context.Context) DeliverCheckReplyMsg {
		if el := time.Since(start); el < testSettle*time.Millisecond {
			t.Errorf("re-check after %v, before the pause ended", el)
		}
		atCheck = st.waitRing(string(pasteEnd))[st.from:] // the paste echoed
		return okCheck(context.Background())
	})
	wantOutcome(t, out, OutcomeSubmitted, "")
	one := "Ask #7 answered (choice: yes)— read itwith get_ask 7"
	wantBytes(t, atCheck, paste(one), "before the Return")
	wantBytes(t, st.written(), cat(paste(one), []byte{0x0D}), "the delivery")
	if st.sess.promptHoldsText() {
		t.Fatal("a submitted line left the prompt holding text")
	}
}

// Twin of testOverTheOwnersDraftSubmitPromptOnlyPastes.
func TestProj12_OverTheOwnersDraftSubmitPromptOnlyPastes(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	st.desktop.typeChunks([]byte("half"))
	wantBytes(t, st.written(), []byte("half"), "the draft")

	out := st.deliver(st.hub(), st.req("answer"), noCheck(t))
	wantOutcome(t, out, OutcomeTyped, TypedBesideText)
	wantBytes(t, st.written(), paste("answer"), "over the draft")
}

// Twin of testTheOwnerTypingDuringThePauseStopsTheReturn.
func TestProj12_TheOwnerTypingDuringThePauseStopsTheReturn(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	out := st.deliver(st.hub(), st.req("answer"), func(context.Context) DeliverCheckReplyMsg {
		st.desktop.typeChunks([]byte("x"))
		return okCheck(context.Background())
	})
	wantOutcome(t, out, OutcomeTyped, TypedTextDuringPause)
	wantBytes(t, st.written(), cat(paste("answer"), []byte("x")), "no Return of ours")
	if !st.sess.promptHoldsText() {
		t.Fatal("the line left typed does not hold the prompt")
	}
}

// Twin of testALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt.
func TestProj12_ALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	first := st.req("hand-off")
	first.SubmitIf = false
	wantOutcome(t, st.deliver(cl, first, noCheck(t)), OutcomeTyped, TypedNoSubmit)
	wantOutcome(t, st.deliver(cl, st.req("answer"), noCheck(t)), OutcomeTyped, TypedBesideText)
	wantBytes(t, st.written(), cat(paste("hand-off"), paste("answer")), "two lines, no Return")
}

// Twin of testAFailedRefreshAfterThePauseStopsTheReturn.
func TestProj12_AFailedRefreshAfterThePauseStopsTheReturn(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	out := st.deliver(st.hub(), st.req("answer"), func(context.Context) DeliverCheckReplyMsg {
		return DeliverCheckReplyMsg{Fresh: false, CanSubmit: true}
	})
	wantOutcome(t, out, OutcomeTyped, TypedCheckFailed)
	wantBytes(t, st.written(), paste("answer"), "no Return after a failed read")
	if !st.sess.promptHoldsText() {
		t.Fatal("the line left typed does not hold the prompt")
	}
}

// Twin of testWithoutBracketedPasteTheLineIsCopiedNotTyped: the host types
// nothing (the hub turns no_paste_mode into copied or cannot_type).
func TestProj12_WithoutBracketedPasteTheLineIsNotTyped(t *testing.T) {
	st := newStub(t, Options{}, "claude", `stty raw -echo; printf 'ready'; exec cat`)
	out := st.deliver(st.hub(), st.req("answer"), noCheck(t))
	wantOutcome(t, out, OutcomeNoPasteMode, "")
	wantBytes(t, st.written(), nil, "without bracketed paste")
	if st.sess.promptHoldsText() {
		t.Fatal("a line never typed marked the prompt")
	}
}

// Twin of testARelaunchDuringThePauseGetsNoReturn (Review Focus 3): the row
// is relaunched under the same run between paste and Return; the new run
// gets nothing.
func TestProj12_ARelaunchDuringThePauseGetsNoReturn(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	var next *stubSession
	out := st.deliver(st.hub(), st.req("answer"), func(context.Context) DeliverCheckReplyMsg {
		_ = syscall.Kill(-st.info.Pid, syscall.SIGKILL)
		ctl := dial(t, st.path)
		deadline := time.Now().Add(ioTimeout)
		for {
			if l := ctl.list(); len(l) == 1 && l[0].Exited {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("the old run never exited")
			}
			time.Sleep(5 * time.Millisecond)
		}
		ctl.send(Forget, AttachReq{Row: 1, Run: "r1"})
		ctl.expect(Forgot)
		next = launchStub(t, st.srv, st.path, 1, "claude", rawEchoAgent)
		return okCheck(context.Background())
	})
	wantOutcome(t, out, OutcomeNoSession, "")
	if next.info.Launch == st.info.Launch {
		t.Fatalf("relaunch kept launch %d", next.info.Launch)
	}
	wantBytes(t, next.written(), nil, "the new run")
	if next.sess.promptHoldsText() {
		t.Fatal("the new run's prompt holds text")
	}
}

// Twin of testTheOwnersReturnDuringThePauseOverADialogOrAFailedReadLeavesTheLineTyped:
// the owner's Return in the pause sent the line only when the re-check is
// fresh and shows no dialog; otherwise the line counts as still typed.
func TestProj12_TheOwnersReturnDuringThePauseOverADialogOrAFailedReadLeavesTheLineTyped(t *testing.T) {
	cases := []struct {
		name    string
		reply   DeliverCheckReplyMsg
		outcome string
		reason  string
	}{
		{"a permission prompt", DeliverCheckReplyMsg{Fresh: true, AnswersDialog: true}, OutcomeTyped, TypedOwnerReturnDialog},
		{"a failed read", DeliverCheckReplyMsg{Fresh: false, CanSubmit: true}, OutcomeTyped, TypedCheckFailed},
		// Whatever the caller's other condition: the owner's Return sent it.
		{"control: sent by the owner", DeliverCheckReplyMsg{Fresh: true, CanSubmit: false}, OutcomeSubmitted, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			st := newStub(t, Options{}, "claude", rawEchoAgent)
			cl := st.hub()
			out := st.deliver(cl, st.req("x"), func(context.Context) DeliverCheckReplyMsg {
				st.desktop.typeChunks([]byte{0x0D})
				return tc.reply
			})
			wantOutcome(t, out, tc.outcome, tc.reason)
			wantBytes(t, st.written(), cat(paste("x"), []byte{0x0D}), "the owner's Return only")
			held := st.deliver(cl, DeliverReq{Row: 1, Run: "r1", Launch: st.info.Launch, Text: "next",
				SettleMs: testSettle, SubmitIf: true, HoldIfPromptText: true}, nil)
			if tc.outcome == OutcomeTyped {
				wantOutcome(t, held, OutcomeHeld, HeldPromptHasText)
			} else {
				wantOutcome(t, held, OutcomeSubmitted, "")
			}
		})
	}
}

// Twin of testCodexSubmitIsBracketedPasteThenCR.
func TestProj12_CodexSubmitIsBracketedPasteThenCR(t *testing.T) {
	st := newStub(t, Options{}, "codex", rawEchoAgent)
	r := st.req("Fix the flaky test")
	r.SettleMs = 0 // the profile's pasteSettle
	start := time.Now()
	out := st.deliver(st.hub(), r, func(context.Context) DeliverCheckReplyMsg {
		if el := time.Since(start); el < ProfileFor("codex").PasteSettle {
			t.Errorf("re-check after %v, before codex's pasteSettle", el)
		}
		return okCheck(context.Background())
	})
	wantOutcome(t, out, OutcomeSubmitted, "")
	wantBytes(t, st.written(), cat(paste("Fix the flaky test"), []byte{0x0D}), "codex")
}

// Twin of testCodexMultilineAnswerOnePrompt: a hand-off keeps its line
// breaks inside one paste and goes as one prompt; an answer's are dropped.
func TestProj12_CodexMultilineAnswerOnePrompt(t *testing.T) {
	st := newStub(t, Options{}, "codex", rawEchoAgent)
	cl := st.hub()
	handOff := st.req("first\nsecond\r\nthird")
	handOff.KeepLineBreaks = true
	wantOutcome(t, st.deliver(cl, handOff, nil), OutcomeSubmitted, "")
	wantOutcome(t, st.deliver(cl, st.req("line one\nline two"), nil), OutcomeSubmitted, "")
	wantBytes(t, st.written(),
		cat(paste("first\nsecond\nthird"), []byte{0x0D}, paste("line oneline two"), []byte{0x0D}), "codex")
}

func (st *stubSession) phoneReq(text string) DeliverReq {
	r := st.req(text)
	r.HoldIfPromptText = true
	return r
}

func TestHoldIfPromptTextHoldsOverAnOwnerDraft(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	st.desktop.typeChunks([]byte("a"), []byte("b"), []byte("c"))
	wantBytes(t, st.written(), []byte("abc"), "the draft")
	out := st.deliver(st.hub(), st.phoneReq("from the phone"), noCheck(t))
	wantOutcome(t, out, OutcomeHeld, HeldPromptHasText)
	wantBytes(t, st.written(), nil, "after the draft")
}

func TestHoldIfPromptTextHoldsOverAPendingReturn(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	second := st.hub()
	var during DeliveredMsg
	out := st.deliver(st.hub(), st.req("answer"), func(context.Context) DeliverCheckReplyMsg {
		during = st.deliver(second, st.phoneReq("from the phone"), noCheck(t))
		return okCheck(context.Background())
	})
	wantOutcome(t, during, OutcomeHeld, HeldPromptHasText)
	wantOutcome(t, out, OutcomeSubmitted, "")
	wantBytes(t, st.written(), cat(paste("answer"), []byte{0x0D}), "only the first line")
}

func TestHoldIfPromptTextHoldsOverALineLeftTyped(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	first := st.req("hand-off")
	first.SubmitIf = false
	wantOutcome(t, st.deliver(cl, first, noCheck(t)), OutcomeTyped, TypedNoSubmit)
	wantOutcome(t, st.deliver(cl, st.phoneReq("from the phone"), noCheck(t)), OutcomeHeld, HeldPromptHasText)
	wantBytes(t, st.written(), paste("hand-off"), "only the first line")

	// The owner's Return sends the line left typed; the next goes.
	st.desktop.typeChunks([]byte{0x0D})
	wantOutcome(t, st.deliver(cl, st.phoneReq("now"), nil), OutcomeSubmitted, "")
}

// The Desktop composer's behaviour: beside the owner's draft a line is
// pasted and left typed, with no Return, and the pane hears it shares the
// prompt.
func TestWithoutHoldIfPromptTextALineBesideTheDraftIsTyped(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	st.desktop.typeChunks([]byte("abc"))
	wantBytes(t, st.written(), []byte("abc"), "the draft")
	out := st.deliver(st.hub(), st.req("composer line"), noCheck(t))
	wantOutcome(t, out, OutcomeTyped, TypedBesideText)
	wantBytes(t, st.written(), paste("composer line"), "beside the draft")
	evs := st.desktop.events(2)
	if evs[0].Kind != EventPasted || evs[1].Kind != EventLeftTyped || !evs[1].BesideText {
		t.Fatalf("events = %+v, want pasted then left_typed beside text", evs)
	}
}

// Review Focus 2: the requesting connection never answers the re-check.
// No Return follows, the pending Return clears, and the line counts as left
// typed for the next delivery.
func TestDeliverCheckTimeoutLeavesLineTyped(t *testing.T) {
	if NewServer(Options{}).opts.checkTimeout != CheckTimeout {
		t.Fatal("the default re-check timeout is not CheckTimeout")
	}
	st := newStub(t, Options{checkTimeout: 200 * time.Millisecond}, "claude", rawEchoAgent)
	raw := dial(t, st.path)
	r := st.req("answer")
	r.ID = "x1"
	raw.send(Deliver, r)
	var check DeliverCheckMsg
	if err := json.Unmarshal(raw.expect(DeliverCheck), &check); err != nil || check.ID != "x1" {
		t.Fatalf("check = %+v (%v)", check, err)
	}
	if !st.sess.promptHoldsText() {
		t.Fatal("no pending Return during the pause")
	}
	var out DeliveredMsg
	if err := json.Unmarshal(raw.expect(Delivered), &out); err != nil {
		t.Fatal(err)
	}
	if out.ID != "x1" {
		t.Fatalf("delivered id = %q", out.ID)
	}
	wantOutcome(t, out, OutcomeTyped, TypedCheckFailed)
	// A late answer is dropped.
	raw.send(DeliverCheckReply, DeliverCheckReplyMsg{ID: "x1", Fresh: true, CanSubmit: true})
	raw.expectNoError()
	wantBytes(t, st.written(), paste("answer"), "no Return without the re-check")
	st.sess.mu.Lock()
	pending, left := st.sess.prompt.pendingReturn, st.sess.prompt.leftTyped
	st.sess.mu.Unlock()
	if pending || !left {
		t.Fatalf("pendingReturn = %v, leftTyped = %v; want false, true", pending, left)
	}
	wantOutcome(t, st.deliver(st.hub(), st.phoneReq("next"), noCheck(t)), OutcomeHeld, HeldPromptHasText)
}

// The hub crashes during the pause: its connection drops, no Return
// follows and the pending Return clears.
func TestADroppedRequesterDuringThePauseLeavesTheLineTyped(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	raw := dial(t, st.path)
	r := st.req("answer")
	r.ID = "x1"
	raw.send(Deliver, r)
	raw.expect(DeliverCheck)
	_ = raw.nc.Close()
	deadline := time.Now().Add(ioTimeout)
	for {
		st.sess.mu.Lock()
		pending, left := st.sess.prompt.pendingReturn, st.sess.prompt.leftTyped
		st.sess.mu.Unlock()
		if !pending && left {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pendingReturn = %v, leftTyped = %v after the hub dropped", pending, left)
		}
		time.Sleep(5 * time.Millisecond)
	}
	wantBytes(t, st.written(), paste("answer"), "no Return after the hub dropped")
}

// events reads n DeliveryEvent frames, skipping Output.
func (c *client) events(n int) []DeliveryEventMsg {
	c.t.Helper()
	var out []DeliveryEventMsg
	for len(out) < n {
		var ev DeliveryEventMsg
		if err := json.Unmarshal(c.expect(DeliveryEvent), &ev); err != nil {
			c.t.Fatal(err)
		}
		out = append(out, ev)
	}
	return out
}

func TestDeliveryEventsReachAttachedClients(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	wantOutcome(t, st.deliver(cl, st.req("one"), nil), OutcomeSubmitted, "")
	evs := st.desktop.events(2)
	if evs[0] != (DeliveryEventMsg{Row: 1, Run: "r1", Kind: EventPasted}) ||
		evs[1] != (DeliveryEventMsg{Row: 1, Run: "r1", Kind: EventSubmitted}) {
		t.Fatalf("events = %+v, want pasted then submitted", evs)
	}
	two := st.req("two")
	two.SubmitIf = false
	wantOutcome(t, st.deliver(cl, two, noCheck(t)), OutcomeTyped, TypedNoSubmit)
	evs = st.desktop.events(2)
	if evs[0].Kind != EventPasted || evs[1] != (DeliveryEventMsg{Row: 1, Run: "r1", Kind: EventLeftTyped}) {
		t.Fatalf("events = %+v, want pasted then left_typed (not beside text)", evs)
	}
}

func TestDeliverNeverAttaches(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	raw := dial(t, st.path)
	r := st.req("hello")
	r.ID = "x1"
	raw.send(Deliver, r)
	raw.expect(DeliverCheck)
	raw.send(DeliverCheckReply, DeliverCheckReplyMsg{ID: "x1", Fresh: true, CanSubmit: true})
	var out DeliveredMsg
	if err := json.Unmarshal(raw.expect(Delivered), &out); err != nil {
		t.Fatal(err)
	}
	wantOutcome(t, out, OutcomeSubmitted, "")

	// The delivering connection is bound to nothing: Input is refused.
	raw.send(Input, []byte("x"))
	if msg := errMsg(t, raw.expect(Error)); !strings.Contains(msg, "not attached") {
		t.Fatalf("input after deliver = %q, want not attached", msg)
	}
	// The pane keeps its session: its Input still reaches the PTY and it
	// was never told it was taken over (expectNoError fails on an Error).
	st.desktop.typeChunks([]byte("z"))
	wantBytes(t, st.written(), cat(paste("hello"), []byte{0x0D}, []byte("z")), "pane input after deliver")
	st.srv.mu.Lock()
	bound := 0
	for c := range st.srv.conns {
		if c.bound {
			bound++
		}
	}
	st.srv.mu.Unlock()
	if bound != 1 {
		t.Fatalf("%d bound connections, want only the pane", bound)
	}
}

func TestDeliverToNoSession(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	wrongLaunch := st.req("x")
	wrongLaunch.Launch++
	wantOutcome(t, st.deliver(cl, wrongLaunch, noCheck(t)), OutcomeNoSession, "")
	unknown := st.req("x")
	unknown.Row = 99
	wantOutcome(t, st.deliver(cl, unknown, noCheck(t)), OutcomeNoSession, "")
	wantBytes(t, st.written(), nil, "no session")
}

// A line that cleans to nothing is refused: no empty paste, no Return.
func TestDeliverRefusesTextThatCleansToNothing(t *testing.T) {
	st := newStub(t, Options{}, "claude", rawEchoAgent)
	cl := st.hub()
	_, err := cl.Deliver(ctxT(t), st.req("\n\r\x1b"), noCheck(t))
	var he *HostError
	if !errors.As(err, &he) || !strings.Contains(he.Message, "empty text") {
		t.Fatalf("deliver empty = %v, want the empty-text refusal", err)
	}
	wantBytes(t, st.written(), nil, "empty text")
	if st.sess.promptHoldsText() {
		t.Fatal("a refused line marked the prompt")
	}
	// The Client stays usable after the refusal.
	wantOutcome(t, st.deliver(cl, st.req("after"), nil), OutcomeSubmitted, "")
}

func TestSettleIsClampedToMaxSettle(t *testing.T) {
	prof := ProfileFor("claude")
	cases := map[int]time.Duration{
		0:                                 prof.PasteSettle,
		-5:                                prof.PasteSettle,
		500:                               500 * time.Millisecond,
		int(MaxSettle / time.Millisecond): MaxSettle,
		1 << 30:                           MaxSettle,
	}
	for ms, want := range cases {
		if got := settleFor(ms, prof); got != want {
			t.Errorf("settleFor(%d) = %v, want %v", ms, got, want)
		}
	}
}

// A reply sent before the host asked its DeliverCheck is no answer to it:
// a pre-answered Fresh/CanSubmit gets no Return.
func TestACheckReplyBeforeTheCheckIsIgnored(t *testing.T) {
	st := newStub(t, Options{checkTimeout: 200 * time.Millisecond}, "claude", rawEchoAgent)
	raw := dial(t, st.path)
	r := st.req("answer")
	r.ID = "x1"
	r.SettleMs = 300
	raw.send(Deliver, r)
	raw.send(DeliverCheckReply, DeliverCheckReplyMsg{ID: "x1", Fresh: true, CanSubmit: true})
	raw.expect(DeliverCheck) // asked, never answered after it
	var out DeliveredMsg
	if err := json.Unmarshal(raw.expect(Delivered), &out); err != nil {
		t.Fatal(err)
	}
	wantOutcome(t, out, OutcomeTyped, TypedCheckFailed)
	wantBytes(t, st.written(), paste("answer"), "no Return on a pre-answer")
}
