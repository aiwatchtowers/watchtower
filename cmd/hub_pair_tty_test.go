package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/termqr"
)

// TestHubPairEscapesThePhoneName is Review Focus 4 at the function level: the
// phone names itself, and the terminal prints that name before the SAS
// prompt. An OSC title sequence, its BEL terminator and a right-to-left
// override must not reach the terminal; the printable rest stays.
func TestHubPairEscapesThePhoneName(t *testing.T) {
	require.Equal(t, "acme]0;x", sanitizeForTerminal("acme\x1b]0;x\x07\u202e"))
}

func TestSanitizeForTerminal(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"plain", "Colleague A's iPhone", "Colleague A's iPhone"},
		{"non-latin kept", "Айфон 15 — 📱", "Айфон 15 — 📱"},
		{"C0 controls", "a\x00b\tc\nd\re\x1bf", "abcdef"},
		{"DEL", "a\x7fb", "ab"},
		{"C1 controls (CSI, OSC as code points)", "a\u009b31mb\u009dc\u0080d\u009fe", "a31mbcde"},
		{"raw 8-bit C1 byte (invalid UTF-8)", "a\x9b31mb", "a31mb"},
		{"invalid UTF-8 dropped", "a\xff\xfeb", "ab"},
		{"embedding and override controls", "a\u202ab\u202bc\u202cd\u202de\u202ef", "abcdef"},
		{"isolate controls", "a\u2066b\u2067c\u2068d\u2069e", "abcde"},
		{"bidi marks", "a\u200eb\u200fc\u061cd", "abcd"},
		{"CSI clear screen", "x\x1b[2Jy", "x[2Jy"},
		{"line and paragraph separators", "a\u2028b\u2029c", "abc"},
		{"zero-width space and joiner", "a\u200bb\u200cc\u200dd\u2060e", "abcde"},
		{"byte order mark, soft hyphen, Mongolian vowel separator", "\ufeffa\u00adb\u180ec", "abc"},
		{"tag characters", "a\U000E0001\U000E0041\U000E007Fb", "ab"},
		{"combining marks capped at two per base", "e\u0301\u0302\u0303\u0304x\u0300", "e\u0301\u0302x\u0300"},
		{"Zalgo flood", "Z" + strings.Repeat("\u0336", 5000) + "a", "Z\u0336\u0336a"},
		{"64 runes kept as is", strings.Repeat("ж", 64), strings.Repeat("ж", 64)},
		{"10 000-rune name cut with an ellipsis", strings.Repeat("ж", 10000), strings.Repeat("ж", 63) + "…"},
		{"dropped runes do not count toward the cap", strings.Repeat("\u200b", 100) + "ab", "ab"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			require.Equal(t, c.want, sanitizeForTerminal(c.in))
		})
	}
}

// syncBuffer collects the pty's output while the test reads it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// String is the output so far, the pty's \r\n folded to \n.
func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.ReplaceAll(b.buf.String(), "\r\n", "\n")
}

// ttyPair is one `hub pair` run in-process on a pty (stdin, stdout and
// stderr the pty's terminal end), with Ctrl-C injected through
// hubPairInterrupts.
type ttyPair struct {
	pty  *os.File
	out  *syncBuffer
	sigs chan os.Signal
	done chan error

	finished bool // done was read into err
	err      error
}

func startPairTTY(t *testing.T, cols uint16) *ttyPair {
	t.Helper()
	ptm, tty, err := pty.Open()
	require.NoError(t, err)
	require.NoError(t, pty.Setsize(ptm, &pty.Winsize{Rows: 80, Cols: cols}))
	r := &ttyPair{pty: ptm, out: &syncBuffer{}, sigs: make(chan os.Signal, 1), done: make(chan error, 1)}
	copied := make(chan struct{})
	go func() { _, _ = io.Copy(r.out, ptm); close(copied) }()

	orig := hubPairInterrupts
	hubPairInterrupts = func() (<-chan os.Signal, func()) { return r.sigs, func() {} }
	rootCmd.SetIn(tty)
	rootCmd.SetOut(tty)
	rootCmd.SetErr(tty)
	rootCmd.SetArgs([]string{"hub", "pair"})
	go func() { r.done <- rootCmd.Execute() }()
	t.Cleanup(func() {
		if !r.finished {
			select {
			case <-r.done:
			case <-time.After(10 * time.Second):
				t.Error("hub pair did not return")
			}
		}
		// A prompt that ended without the owner's line (expiry, Ctrl-C) left
		// its reader blocked on the terminal, which keeps the pty open past
		// the closes below: one line releases it.
		_, _ = io.WriteString(ptm, "\n")
		_ = tty.Close()
		_ = ptm.Close()
		<-copied
		hubPairInterrupts = orig
		rootCmd.SetIn(nil)
		rootCmd.SetOut(nil)
		rootCmd.SetErr(nil)
		rootCmd.SetArgs(nil)
		for _, c := range hubCmd.Commands() {
			c.Flags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
		}
	})
	return r
}

func (r *ttyPair) waitFor(t *testing.T, text string) {
	t.Helper()
	waitFor(t, fmt.Sprintf("%q in the output", text), func() bool { return strings.Contains(r.out.String(), text) })
}

func (r *ttyPair) typeLine(t *testing.T, s string) {
	t.Helper()
	_, err := io.WriteString(r.pty, s)
	require.NoError(t, err)
}

// wait is the run's exit code (0 for nil) and its error.
func (r *ttyPair) wait(t *testing.T) (int, error) {
	t.Helper()
	if !r.finished {
		select {
		case r.err = <-r.done:
			r.finished = true
		case <-time.After(10 * time.Second):
			t.Fatalf("hub pair did not finish; output:\n%s", r.out.String())
		}
	}
	var ec *exitCodeError
	switch {
	case r.err == nil:
		return 0, nil
	case errors.As(r.err, &ec):
		return ec.code, r.err
	default:
		return 1, r.err
	}
}

// fakePairHub serves the pairing stream on dir's control socket: it reads
// the pair request, writes before, and when before has a sas reads the
// owner's confirm into confirms and writes after.
type fakePairHub struct {
	confirms chan hub.ControlRequest
}

func startFakePairHub(t *testing.T, dir string, before, after []hub.ControlAnswer) *fakePairHub {
	t.Helper()
	require.NoError(t, os.MkdirAll(dir, 0o700))
	l, err := net.Listen("unix", filepath.Join(dir, hub.SocketName))
	require.NoError(t, err)
	f := &fakePairHub{confirms: make(chan hub.ControlRequest, 1)}
	served := make(chan struct{})
	go func() {
		defer close(served)
		conn, err := l.Accept()
		if err != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		dec, enc := json.NewDecoder(conn), json.NewEncoder(conn)
		var req hub.ControlRequest
		if dec.Decode(&req) != nil || req.Op != hub.OpPair {
			return
		}
		sas := false
		for _, a := range before {
			_ = enc.Encode(a)
			sas = sas || a.Event == link.EventSAS
		}
		if sas {
			if dec.Decode(&req) != nil {
				return
			}
			f.confirms <- req
			for _, a := range after {
				_ = enc.Encode(a)
			}
		}
		_, _ = io.Copy(io.Discard, conn) // until the CLI hangs up
	}()
	t.Cleanup(func() { _ = l.Close(); <-served })
	return f
}

const fakePairDevice = "BBBBBBBB-0000-4000-8000-000000000002"

// fakePairOpening is the stream up to the sas of a phone named name,
// expiring at exp.
func fakePairOpening(t *testing.T, exp time.Time, name string) (string, []hub.ControlAnswer) {
	t.Helper()
	url := testLinkURL(t)
	return url, []hub.ControlAnswer{
		{Event: link.EventQR, URL: url, ExpiresAt: &exp},
		{Event: link.EventWaiting},
		{Event: link.EventSAS, DeviceID: fakePairDevice, Name: name, Code: "4827"},
	}
}

// testLinkURL is the shared fixture's v4_headless link (mac_name "Test Mac").
func testLinkURL(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	require.NoError(t, err)
	var f struct {
		LinkPayload []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"link_payload"`
	}
	require.NoError(t, json.Unmarshal(raw, &f))
	for _, c := range f.LinkPayload {
		if c.Name == "v4_headless" {
			return c.URL
		}
	}
	t.Fatal("fixture case v4_headless")
	return ""
}

// assertInOrder checks that every line appears in out, in this order.
func assertInOrder(t *testing.T, out string, lines ...string) {
	t.Helper()
	rest := out
	for _, l := range lines {
		i := strings.Index(rest, l)
		require.GreaterOrEqual(t, i, 0, "%q (in order) in:\n%s", l, out)
		rest = rest[i+len(l):]
	}
}

func TestHubPairNeedsATerminal(t *testing.T) {
	hubShortDir(t) // no hub runs: the check comes before the dial
	_, err := runHub(t, "pair")
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 2, ec.code)
	assert.EqualError(t, err, "hub pair needs a terminal; scripts use --json --stream")

	_, err = runHub(t, "pair", "--json")
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 2, ec.code, "--json without --stream is a usage error")
}

// TestHubPairTTYFlowLinked drives a real test hub and a Go phone through the
// terminal: the QR, the prompt, a y, linked.
func TestHubPairTTYFlowLinked(t *testing.T) {
	dir := hubShortDir(t)
	setHubMeta(t, dir, state.MetaEnabled, "1")
	setHubMeta(t, dir, state.MetaDisplayName, "acme-pi")
	fake := startTestHub(t, dir)
	waitHubState(t, dir, hub.StateRunning)

	r := startPairTTY(t, 120)
	r.waitFor(t, hubPairWaiting)
	var url string
	for _, l := range strings.Split(r.out.String(), "\n") {
		if strings.HasPrefix(l, "watchtower://link?d=") {
			url = l
		}
	}
	require.NotEmpty(t, url, "the link is printed on its own line")
	lp, err := wire.ParseLinkURL(url)
	require.NoError(t, err)
	phone, err := hubtest.FromLink(lp, fake, nil)
	require.NoError(t, err)
	require.NoError(t, phone.Hello(transport.PairZone("slot1")))
	fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot1"}})
	r.waitFor(t, "on your phone? [y/N] ")
	r.typeLine(t, "y\n")
	code, err := r.wait(t)
	require.NoError(t, err)
	assert.Equal(t, 0, code)
	r.waitFor(t, " typing|start_sessions\n") // the pty may still hold the last lines

	out := r.out.String()
	assert.Contains(t, out, "\x1b[30;107m", "the QR is drawn")
	assertInOrder(t, out,
		"Link your iPhone to acme-pi\n",
		"Scan it with the Watchtower app on your iPhone, or open this link on the phone:\n",
		url+"\n",
		"Needs a phone with Relay. The code expires at ",
		hubPairWaiting+"\n",
		"\" wants to link.\n",
		"Confirm code ",
		" on your phone? [y/N] y\n",
		"Linked \"",
		"To let it type into sessions or start them: watchtower hub allow ",
		" typing|start_sessions\n",
	)
	out2, err := runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.Contains(t, out2, strings.ToUpper(phone.ID().String()), "the phone is linked")
}

func TestHubPairTTYYesInAnyCase(t *testing.T) {
	for _, in := range []string{"Y\n", "YES\n", " yes \n"} {
		t.Run(strings.TrimSpace(in), func(t *testing.T) {
			dir := hubShortDir(t)
			exp := time.Now().Add(10 * time.Minute)
			_, before := fakePairOpening(t, exp, "Colleague A's iPhone")
			f := startFakePairHub(t, dir, before, []hub.ControlAnswer{{Event: link.EventLinked, DeviceID: fakePairDevice}})
			r := startPairTTY(t, 120)
			r.waitFor(t, "Confirm code 4827 on your phone? [y/N] ")
			r.typeLine(t, in)
			assert.True(t, (<-f.confirms).Confirm)
			code, err := r.wait(t)
			require.NoError(t, err)
			assert.Equal(t, 0, code)
			r.waitFor(t, " typing|start_sessions\n")
			assertInOrder(t, r.out.String(),
				"Link your iPhone to Test Mac\n",
				"The code expires at "+exp.Local().Format("15:04")+".\n",
				"\"Colleague A's iPhone\" wants to link.\n",
				"Linked \"Colleague A's iPhone\".\n",
				"watchtower hub allow "+fakePairDevice+" typing|start_sessions\n")
		})
	}
}

func TestHubPairTTYAnythingButYesRefuses(t *testing.T) {
	cases := []struct {
		name, in string
		exp      time.Duration
	}{
		{"n", "n\n", 10 * time.Minute},
		{"empty line", "\n", 10 * time.Minute},
		{"other word", "yep\n", 10 * time.Minute},
		{"EOF", "\x04", 10 * time.Minute},
		{"the code expires", "", 700 * time.Millisecond},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := hubShortDir(t)
			_, before := fakePairOpening(t, time.Now().Add(c.exp), "iPhone")
			f := startFakePairHub(t, dir, before, []hub.ControlAnswer{{Event: link.EventRefused, DeviceID: fakePairDevice, Reason: wire.RefusedNotConfirmed}})
			r := startPairTTY(t, 120)
			r.waitFor(t, "[y/N] ")
			if c.in != "" {
				r.typeLine(t, c.in)
			}
			select {
			case req := <-f.confirms:
				assert.Equal(t, hub.OpConfirm, req.Op)
				assert.Equal(t, fakePairDevice, req.Device)
				assert.False(t, req.Confirm)
			case <-time.After(10 * time.Second):
				t.Fatal("no confirm sent")
			}
			code, err := r.wait(t)
			assert.Equal(t, 1, code)
			assert.EqualError(t, err, "Not linked: the code was not confirmed.")
		})
	}
}

func TestHubPairTTYRefusalLines(t *testing.T) {
	cases := map[string]string{
		wire.RefusedUsedCode:        "This code was already used. Run watchtower hub pair for a new one.",
		wire.RefusedExpiredCode:     "This code expired. Run watchtower hub pair for a new one.",
		wire.RefusedUnknownCode:     "The phone sent a code this host does not know. Run watchtower hub pair again.",
		wire.RefusedNotConfirmed:    "Not linked: the code was not confirmed.",
		wire.RefusedTooManyRequests: "Too many phones tried this code. Run watchtower hub pair for a new one.",
		"slot_full":                 "Not linked (slot_full).",
		"bad\x1b[2Jreason":          "Not linked (bad[2Jreason).",
	}
	for reason, line := range cases {
		t.Run(reason, func(t *testing.T) {
			dir := hubShortDir(t)
			url, _ := fakePairOpening(t, time.Now().Add(10*time.Minute), "iPhone")
			exp := time.Now().Add(10 * time.Minute)
			startFakePairHub(t, dir, []hub.ControlAnswer{
				{Event: link.EventQR, URL: url, ExpiresAt: &exp},
				{Event: link.EventWaiting},
				{Event: link.EventRefused, Reason: reason},
			}, nil)
			r := startPairTTY(t, 120)
			code, err := r.wait(t)
			assert.Equal(t, 1, code)
			assert.EqualError(t, err, line)
		})
	}
}

func TestHubPairCtrlCDuringTheSASSendsNo(t *testing.T) {
	dir := hubShortDir(t)
	_, before := fakePairOpening(t, time.Now().Add(10*time.Minute), "iPhone")
	f := startFakePairHub(t, dir, before, nil)
	r := startPairTTY(t, 120)
	r.waitFor(t, "[y/N] ")
	r.sigs <- os.Interrupt
	select {
	case req := <-f.confirms:
		assert.False(t, req.Confirm)
		assert.Equal(t, fakePairDevice, req.Device)
	case <-time.After(10 * time.Second):
		t.Fatal("no confirm sent")
	}
	code, err := r.wait(t)
	assert.Equal(t, 130, code)
	assert.EqualError(t, err, "Cancelled. Not linked.")
}

func TestHubPairCtrlCWhileWaitingCancels(t *testing.T) {
	dir := hubShortDir(t)
	url, _ := fakePairOpening(t, time.Now().Add(10*time.Minute), "iPhone")
	exp := time.Now().Add(10 * time.Minute)
	startFakePairHub(t, dir, []hub.ControlAnswer{{Event: link.EventQR, URL: url, ExpiresAt: &exp}, {Event: link.EventWaiting}}, nil)
	r := startPairTTY(t, 120)
	r.waitFor(t, hubPairWaiting)
	r.sigs <- os.Interrupt
	code, err := r.wait(t)
	assert.Equal(t, 130, code)
	assert.EqualError(t, err, "Cancelled. Not linked.")
}

// TestHubPairTTYEscapesThePhoneName is Review Focus 4 through the flow: the
// name's escape never reaches the terminal.
func TestHubPairTTYEscapesThePhoneName(t *testing.T) {
	dir := hubShortDir(t)
	_, before := fakePairOpening(t, time.Now().Add(10*time.Minute), "acme\x1b]0;x\x07")
	f := startFakePairHub(t, dir, before, []hub.ControlAnswer{{Event: link.EventLinked, DeviceID: fakePairDevice}})
	r := startPairTTY(t, 120)
	r.waitFor(t, "[y/N] ")
	r.typeLine(t, "y\n")
	<-f.confirms
	code, _ := r.wait(t)
	assert.Equal(t, 0, code)
	out := r.out.String()
	assert.Contains(t, out, "\"acme]0;x\" wants to link.\n")
	assert.NotContains(t, out, "\x1b]")
	assert.NotContains(t, out, "\x07")
}

func TestHubPairNarrowWindowPrintsTheWidenHint(t *testing.T) {
	dir := hubShortDir(t)
	url, _ := fakePairOpening(t, time.Now().Add(10*time.Minute), "iPhone")
	width, err := termqr.Width(url)
	require.NoError(t, err)
	exp := time.Now().Add(10 * time.Minute)
	startFakePairHub(t, dir, []hub.ControlAnswer{{Event: link.EventQR, URL: url, ExpiresAt: &exp}, {Event: link.EventWaiting}}, nil)
	r := startPairTTY(t, uint16(width-1))
	r.waitFor(t, hubPairWaiting)
	out := r.out.String()
	assert.NotContains(t, out, "\x1b[30;107m", "no QR in a narrow window")
	assertInOrder(t, out,
		"Link your iPhone to Test Mac\n",
		fmt.Sprintf("Widen this window to at least %d columns to see the QR code.\n", width),
		"Scan it with the Watchtower app on your iPhone, or open this link on the phone:\n",
		url+"\n",
		hubPairWaiting)
	r.sigs <- os.Interrupt
	code, _ := r.wait(t)
	assert.Equal(t, 130, code)
}
