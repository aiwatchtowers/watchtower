package cmd

import (
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/wire"
)

// ttyScripted opens a terminal pairing against a scripted hub up to the
// phone's first prompt (code 1111, request r1, or none on an old hub).
func ttyScripted(t *testing.T, request string) (*scriptedPairHub, *ttyPair) {
	t.Helper()
	f, r := ttyScriptedWaiting(t)
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventSAS, DeviceID: fakePairDevice, Name: "acme phone", Code: "1111", Request: request})
	r.waitFor(t, "Confirm code 1111 on your phone? [y/N] ")
	return f, r
}

// ttyScriptedWaiting opens a terminal pairing against a scripted hub up to
// the waiting line.
func ttyScriptedWaiting(t *testing.T) (*scriptedPairHub, *ttyPair) {
	t.Helper()
	dir := hubShortDir(t)
	f := startScriptedPairHub(t, dir)
	exp := time.Now().Add(10 * time.Minute)
	r := startPairTTY(t, 120)
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventQR, URL: testLinkURL(t), ExpiresAt: &exp})
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventWaiting})
	r.waitFor(t, hubPairWaiting)
	return f, r
}

// ttySend hands the scripted hub's next line to the CLI; the CLI ending
// first fails the test at once.
func ttySend(t *testing.T, r *ttyPair, f *scriptedPairHub, a hub.ControlAnswer) {
	t.Helper()
	select {
	case f.send <- a:
	case err := <-r.done:
		r.finished, r.err = true, err
		t.Fatalf("the CLI ended (%v) before %+v; output:\n%s", err, a, r.out.String())
	}
}

// ttyGot is the CLI's next request to the scripted hub; the CLI ending
// first fails the test at once.
func ttyGot(t *testing.T, r *ttyPair, f *scriptedPairHub) hub.ControlRequest {
	t.Helper()
	select {
	case req := <-f.got:
		return req
	case err := <-r.done:
		r.finished, r.err = true, err
		t.Fatalf("the CLI ended (%v) before its request; output:\n%s", err, r.out.String())
		return hub.ControlRequest{}
	}
}

// ttyNothingSent: no request reached the scripted hub so far. The CLI
// sends a confirm in the step that would otherwise print the line the test
// waited for, so once that line is on screen no request is on its way.
func ttyNothingSent(t *testing.T, f *scriptedPairHub) {
	t.Helper()
	select {
	case req := <-f.got:
		t.Fatalf("a request reached the hub: %+v", req)
	default:
	}
}

// ttyLink ends a scripted terminal pairing: the hub accepts and links.
func ttyLink(t *testing.T, r *ttyPair, f *scriptedPairHub) {
	t.Helper()
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, OK: true, DeviceID: fakePairDevice})
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventLinked, DeviceID: fakePairDevice})
	code, err := r.wait(t)
	require.NoError(t, err)
	assert.Equal(t, 0, code)
	r.waitFor(t, " typing|start_sessions\n") // the pty may still hold the last lines
}

// ttyRefuse ends a scripted terminal pairing after the owner's no: the hub
// accepts it and refuses the phone.
func ttyRefuse(t *testing.T, r *ttyPair, f *scriptedPairHub) {
	t.Helper()
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, OK: true, DeviceID: fakePairDevice})
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventRefused, DeviceID: fakePairDevice, Reason: wire.RefusedNotConfirmed})
	code, err := r.wait(t)
	assert.Equal(t, 1, code)
	assert.EqualError(t, err, "Not linked: the code was not confirmed.")
}

func ttyYes(code, request string, moves bool) hub.ControlRequest {
	return hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Confirm: true, Code: code, MovesToRelay: &moves, Request: request}
}

// ttySAS is the phone's sas for request with code.
func ttySAS(code, request string) hub.ControlAnswer {
	return hub.ControlAnswer{Event: link.EventSAS, DeviceID: fakePairDevice, Name: "acme phone", Code: code, Request: request}
}

// #2384: the owner's y names the code and the request the prompt showed.
func TestHubPairTTYYesNamesTheRequestShown(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r1", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// #2384: a no, stdin closing and Ctrl-C name the request shown too, so they
// never refuse a newer request the owner did not see.
func TestHubPairTTYNoNamesTheRequestShown(t *testing.T) {
	no := hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r1"}
	t.Run("n", func(t *testing.T) {
		f, r := ttyScripted(t, "r1")
		r.typeLine(t, "n\n")
		assert.Equal(t, no, ttyGot(t, r, f))
		ttyRefuse(t, r, f)
	})
	t.Run("stdin closed", func(t *testing.T) {
		f, r := ttyScripted(t, "r1")
		r.typeLine(t, "\x04")
		assert.Equal(t, no, ttyGot(t, r, f))
		ttyRefuse(t, r, f)
	})
	t.Run("Ctrl-C", func(t *testing.T) {
		f, r := ttyScripted(t, "r1")
		r.sigs <- os.Interrupt
		code, _ := r.wait(t)
		assert.Equal(t, 130, code)
		<-f.eof // the CLI hung up: every request it sent is in got
		select {
		case req := <-f.got:
			assert.Equal(t, no, req)
		default:
			t.Fatal("Ctrl-C at the prompt sent no confirm")
		}
	})
}

// #2384: the phone's request is replaced while the prompt is open. The new
// code is printed; the line the owner types next was being read while the
// prompt changed, so it may answer the earlier code: nothing is sent, the
// owner is told and asked again, and the next answer names the new request.
func TestHubPairTTYReplacedWhileThePromptIsOpen(t *testing.T) {
	for name, first := range map[string]string{"a yes": "y\n", "a no": "n\n"} {
		t.Run(name, func(t *testing.T) {
			f, r := ttyScripted(t, "r1")
			ttySend(t, r, f, ttySAS("2222", "r2"))
			r.waitFor(t, "Confirm code 2222 on your phone? [y/N] ")
			r.typeLine(t, first)
			r.waitFor(t, hubPairStaleAnswer+"\nConfirm code 2222 on your phone? [y/N] ")
			ttyNothingSent(t, f)
			r.typeLine(t, "y\n")
			assert.Equal(t, ttyYes("2222", "r2", false), ttyGot(t, r, f))
			ttyLink(t, r, f)
			assertInOrder(t, r.out.String(),
				"Confirm code 1111 on your phone? [y/N] \n",
				hubPairReplaced+"\n",
				"\"acme phone\" wants to link.\n",
				"Confirm code 2222 on your phone? [y/N] "+first,
				hubPairStaleAnswer+"\n",
				"Confirm code 2222 on your phone? [y/N] y\n",
				"Linked \"acme phone\".\n")
		})
	}
}

// #2384: a replacement that only turns moves_to_relay on (same four
// digits) is a replacement: the prompt is printed again under the Relay
// move warning, and the yes is sent with moves_to_relay true.
func TestHubPairTTYReplacedIntoARelayMove(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	assert.NotContains(t, r.out.String(), hubPairRelayMove("Test Mac"))
	moved := ttySAS("1111", "r1")
	moved.MovesToRelay = true
	ttySend(t, r, f, moved)
	r.waitFor(t, hubPairReplaced+"\n\"acme phone\" wants to link.\n"+hubPairRelayMove("Test Mac")+"\nConfirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	r.waitFor(t, hubPairStaleAnswer+"\n"+hubPairRelayMove("Test Mac")+"\nConfirm code 1111 on your phone? [y/N] ")
	ttyNothingSent(t, f)
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r1", true), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// The Relay move warning is printed over the first prompt too, and names
// "this Mac" when the link names no host.
func TestHubPairTTYRelayMoveWarning(t *testing.T) {
	assert.Equal(t, "Linking this iPhone moves this Mac to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe.",
		hubPairRelayMove(""))
	f, r := ttyScriptedWaiting(t)
	first := ttySAS("1111", "r1")
	first.MovesToRelay = true
	ttySend(t, r, f, first)
	r.waitFor(t, "\"acme phone\" wants to link.\n"+hubPairRelayMove("Test Mac")+"\nConfirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r1", true), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// #2384: the replacement arrives before the owner answers anything: the
// earlier code is never confirmed, even when the owner types y only once
// the new code is on screen (the line was being read across the change).
func TestHubPairTTYReplacedBeforeTheAnswer(t *testing.T) {
	f, r := ttyScriptedWaiting(t)
	ttySend(t, r, f, ttySAS("1111", "r1"))
	ttySend(t, r, f, ttySAS("2222", "r2"))
	r.waitFor(t, "Confirm code 2222 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	r.waitFor(t, hubPairStaleAnswer+"\nConfirm code 2222 on your phone? [y/N] ")
	ttyNothingSent(t, f)
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("2222", "r2", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// #2384: a replacement that drew the same four digits is still another
// request: printed again, and the answer typed across it is not sent.
func TestHubPairTTYReplacedWithTheSameCode(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	ttySend(t, r, f, ttySAS("1111", "r2"))
	r.waitFor(t, hubPairReplaced+"\n\"acme phone\" wants to link.\nConfirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	r.waitFor(t, hubPairStaleAnswer+"\nConfirm code 1111 on your phone? [y/N] ")
	ttyNothingSent(t, f)
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r2", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// A sas that repeats the request shown, or only renames the phone, is not
// a replacement: nothing is printed again and the owner's y goes through.
func TestHubPairTTYUnchangedRequestIsNoReplacement(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	ttySend(t, r, f, ttySAS("1111", "r1"))
	renamed := ttySAS("1111", "r1")
	renamed.Name = "acme phone 2"
	ttySend(t, r, f, renamed)
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r1", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
	assert.NotContains(t, r.out.String(), hubPairReplaced)
}

// #2384: the replacement reaches the hub after the owner's y was sent: the
// hub refuses it code_changed, and the terminal prints the new code and
// asks again instead of confirming it.
func TestHubPairTTYReplacedAfterTheAnswer(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("1111", "r1", false), ttyGot(t, r, f))
	ttySend(t, r, f, ttySAS("2222", "r2"))
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassCodeChanged})
	r.waitFor(t, hubPairCodeChanged+"\n\"acme phone\" wants to link.\nConfirm code 2222 on your phone? [y/N] ")
	ttyNothingSent(t, f)
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("2222", "r2", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// #2384: the hub refused the answer code_changed before the replacing sas
// reached the terminal: no prompt for the old code, the terminal waits for
// the new one and asks about it when it comes.
func TestHubPairTTYCodeChangedBeforeTheReplacement(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	r.typeLine(t, "y\n")
	ttyGot(t, r, f)
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassCodeChanged})
	r.waitFor(t, hubPairCodeChanged+"\n"+hubPairAwaitingNew+"\n")
	ttySend(t, r, f, ttySAS("2222", "r2"))
	r.waitFor(t, hubPairAwaitingNew+"\n\"acme phone\" wants to link.\nConfirm code 2222 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("2222", "r2", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
	assert.Equal(t, 1, strings.Count(r.out.String(), "Confirm code 1111"), "the old code is not asked about again")
}

// #2384: the new request never comes while the terminal waits for it: the
// code's expiry ends the pairing expired, with nothing more sent.
func TestHubPairTTYAwaitedReplacementExpires(t *testing.T) {
	dir := hubShortDir(t)
	f := startScriptedPairHub(t, dir)
	// The code's expiry is already past, so no clock is waited on: the
	// prompt is answered no at once (the code expired), and the wait for
	// the new request ends at once too.
	exp := time.Now()
	r := startPairTTY(t, 120)
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventQR, URL: testLinkURL(t), ExpiresAt: &exp})
	ttySend(t, r, f, ttySAS("1111", "r1"))
	assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r1"}, ttyGot(t, r, f))
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassCodeChanged})
	code, err := r.wait(t)
	assert.Equal(t, 1, code)
	assert.EqualError(t, err, "This code expired. Run watchtower hub pair for a new one.")
	r.waitFor(t, hubPairCodeChanged+"\n"+hubPairAwaitingNew+"\n") // the pty may still hold the last lines
	assertNothingMoreSent(t, f)
}

// #2384: a flush that fails cannot tell an answer typed before the prompt
// from one typed after it: no typed answer is taken, the prompt is a no
// bound to the request shown, and the owner is told why.
func TestHubPairTTYFlushFailureIsANo(t *testing.T) {
	orig := hubPairFlush
	hubPairFlush = func(*os.File) error { return errors.New("flush failed") }
	t.Cleanup(func() { hubPairFlush = orig })
	f, r := ttyScriptedWaiting(t)
	ttySend(t, r, f, ttySAS("1111", "r1"))
	assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r1"}, ttyGot(t, r, f))
	ttyRefuse(t, r, f)
	r.waitFor(t, "Confirm code 1111 on your phone? [y/N] \n"+hubPairFlushFailed+"\n") // the pty may still hold the last lines
}

// #2384: a terminal in raw mode hands one read several lines; the ones
// after the line answered were typed before the next prompt and never
// answer it (the bufio buffer is dropped with the terminal's queue).
func TestHubPairTTYBufferedLinesAreDropped(t *testing.T) {
	f, r := ttyScriptedWaiting(t)
	r.raw(t)
	ttySend(t, r, f, ttySAS("1111", "r1"))
	r.waitFor(t, "Confirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "y\ny\n") // one read in raw mode: the second y stays buffered
	assert.Equal(t, ttyYes("1111", "r1", false), ttyGot(t, r, f))
	ttySend(t, r, f, ttySAS("2222", "r2"))
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassCodeChanged})
	r.waitFor(t, "Confirm code 2222 on your phone? [y/N] ")
	// The second read starts; had the buffered y not been dropped it
	// returns at once and its confirm reaches the hub instead of the n.
	waitFor(t, "the second read or a confirm", func() bool { return r.started.Load() >= 2 || len(f.got) > 0 })
	ttyNothingSent(t, f)
	r.typeAhead(t, "n\n")
	assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r2"}, ttyGot(t, r, f))
	ttyRefuse(t, r, f)
}

// #2384 round 2: waiting for the newer request after code_changed is the
// code's wait, not the answer's: the read deadline moves from the
// after-confirm bound to the code's expiry plus grace, so a sas that comes
// after hubPairAfterConfirm but before the code expires is still read.
func TestHubPairTTYAwaitingUsesTheCodesDeadline(t *testing.T) {
	var mu sync.Mutex
	var deadlines []time.Time
	orig := hubPairReadDeadline
	hubPairReadDeadline = func(_ *hub.ControlClient, d time.Time) { // recorded, never applied: no clock runs
		mu.Lock()
		defer mu.Unlock()
		deadlines = append(deadlines, d)
	}
	t.Cleanup(func() { hubPairReadDeadline = orig })
	last := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return deadlines[len(deadlines)-1]
	}

	dir := hubShortDir(t)
	f := startScriptedPairHub(t, dir)
	exp := time.Now().Add(10 * time.Minute)
	r := startPairTTY(t, 120)
	ttySend(t, r, f, hub.ControlAnswer{Event: link.EventQR, URL: testLinkURL(t), ExpiresAt: &exp})
	ttySend(t, r, f, ttySAS("1111", "r1"))
	r.waitFor(t, "Confirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	ttyGot(t, r, f)
	assert.True(t, !last().IsZero() && last().Before(exp), "after the answer the deadline is the after-confirm bound")
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassCodeChanged})
	r.waitFor(t, hubPairAwaitingNew+"\n")
	assert.True(t, last().Equal(exp.Add(hubPairGrace)), "the wait for the new code runs to the code's expiry plus grace")
	ttySend(t, r, f, ttySAS("2222", "r2"))
	r.waitFor(t, "Confirm code 2222 on your phone? [y/N] ")
	assert.True(t, last().IsZero(), "an open prompt has no read deadline")
	r.typeLine(t, "y\n")
	assert.Equal(t, ttyYes("2222", "r2", false), ttyGot(t, r, f))
	ttyLink(t, r, f)
}

// #2384: stdin closing is the owner's no whichever code was on screen: it
// is sent, named after the request shown last, even across a replacement.
func TestHubPairTTYStdinClosedAfterAReplacement(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	ttySend(t, r, f, ttySAS("2222", "r2"))
	r.waitFor(t, "Confirm code 2222 on your phone? [y/N] ")
	r.typeLine(t, "\x04")
	assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r2"}, ttyGot(t, r, f))
	ttyRefuse(t, r, f)
}

// The request moved to another pairing stream, or is gone: no_request ends
// the terminal pairing as an expired code.
func TestHubPairTTYNoRequestEnds(t *testing.T) {
	f, r := ttyScripted(t, "r1")
	r.typeLine(t, "y\n")
	ttyGot(t, r, f)
	ttySend(t, r, f, hub.ControlAnswer{Op: hub.OpConfirm, Error: hub.ErrClassNoRequest})
	code, err := r.wait(t)
	assert.Equal(t, 1, code)
	assert.EqualError(t, err, "This code expired. Run watchtower hub pair for a new one.")
}

// #2384: a running hub older than the command names no request, so no yes
// could be bound to the request shown: the yes ends the pairing with
// errPairHubTooOld and nothing is confirmed. A no still goes through.
func TestHubPairTTYFailsClosedOnAnOldHub(t *testing.T) {
	t.Run("yes", func(t *testing.T) {
		f, r := ttyScripted(t, "")
		r.typeLine(t, "y\n")
		_, err := r.wait(t)
		require.ErrorIs(t, err, errPairHubTooOld)
		assertNothingMoreSent(t, f)
	})
	t.Run("no", func(t *testing.T) {
		f, r := ttyScripted(t, "")
		r.typeLine(t, "n\n")
		assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice}, ttyGot(t, r, f))
		ttyRefuse(t, r, f)
	})
}

// #2384: a line typed before the prompt (while the phone was still on its
// way) never answers it.
func TestHubPairTTYTypeAheadIsDropped(t *testing.T) {
	f, r := ttyScriptedWaiting(t)
	r.typeAhead(t, "y\n")
	r.waitFor(t, hubPairWaiting+"\ny\n") // echoed: it is in the terminal's input queue
	ttySend(t, r, f, ttySAS("1111", "r1"))
	r.waitFor(t, "Confirm code 1111 on your phone? [y/N] ")
	r.typeLine(t, "n\n")
	assert.Equal(t, hub.ControlRequest{Op: hub.OpConfirm, Device: fakePairDevice, Request: "r1"}, ttyGot(t, r, f))
	ttyRefuse(t, r, f)
	r.waitFor(t, "[y/N] n\n")
}
