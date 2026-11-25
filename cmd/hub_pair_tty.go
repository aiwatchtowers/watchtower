package cmd

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"watchtower/internal/hub"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/wire"
	"watchtower/internal/termqr"
)

// maxTerminalNameRunes caps a phone-supplied string printed during
// `hub pair`, ellipsis included.
const maxTerminalNameRunes = 64

// sanitizeForTerminal makes a phone-supplied string (its name, a refusal
// reason) safe to print in the owner's terminal during `hub pair` (go-hub
// plan 2 Task 6, Review Focus 4). It drops:
//   - every control rune (C0, DEL, C1 — CSI U+009B and OSC U+009D among
//     them), so an escape sequence loses its ESC and prints as plain text;
//   - every format rune (Unicode Cf: the bidi controls, zero-width
//     characters, U+FEFF, U+00AD, the tag characters) and the line and
//     paragraph separators U+2028/U+2029;
//   - every byte that is not valid UTF-8, since a raw 0x9B byte is CSI to an
//     8-bit terminal.
//
// It keeps at most two combining marks (Mn) after a base rune, so a Zalgo
// name cannot paint over the lines around it, and cuts the result to
// maxTerminalNameRunes runes, the last one "…", when it is longer.
func sanitizeForTerminal(s string) string {
	kept := make([]rune, 0, min(len(s), maxTerminalNameRunes+1))
	marks := 0
	for i := 0; i < len(s) && len(kept) <= maxTerminalNameRunes; {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		switch {
		case r == utf8.RuneError && size <= 1,
			unicode.IsControl(r), unicode.Is(unicode.Cf, r),
			r == '\u2028', r == '\u2029':
			continue
		case unicode.Is(unicode.Mn, r):
			if marks == 2 {
				continue
			}
			marks++
		default:
			marks = 0
		}
		kept = append(kept, r)
	}
	if len(kept) > maxTerminalNameRunes {
		kept = append(kept[:maxTerminalNameRunes-1], '…')
	}
	return string(kept)
}

// The terminal copy of `hub pair` (go-hub plan 2 Task 6, reviewed in the
// mockup docs/design/mockups/go-hub/hub-pair-terminal.html, ask #883). The
// SAS prompt is the spec's pinned line.
const (
	hubPairNoTerminal = "hub pair needs a terminal; scripts use --json --stream"
	hubPairCancelled  = "Cancelled. Not linked."
	hubPairWaiting    = "Waiting for your phone… (Ctrl-C cancels)"
)

// errQuietExit ends a command with its exit code and no line: Execute
// prints nothing for an empty error.
var errQuietExit = errors.New("")

// hubPairRefusalLines are the refused event's lines, one per reason.
var hubPairRefusalLines = map[string]string{
	wire.RefusedUsedCode:        "This code was already used. Run watchtower hub pair for a new one.",
	wire.RefusedExpiredCode:     "This code expired. Run watchtower hub pair for a new one.",
	wire.RefusedUnknownCode:     "The phone sent a code this host does not know. Run watchtower hub pair again.",
	wire.RefusedNotConfirmed:    "Not linked: the code was not confirmed.",
	wire.RefusedTooManyRequests: "Too many phones tried this code. Run watchtower hub pair for a new one.",
}

// hubPairRefusal is the line of a refused event; a reason this build does
// not know prints as it came, made safe.
func hubPairRefusal(reason string) string {
	if line, ok := hubPairRefusalLines[reason]; ok {
		return line
	}
	return "Not linked (" + sanitizeForTerminal(reason) + ")."
}

// hubPairInterrupts delivers Ctrl-C to the terminal flow; a seam so tests
// interrupt without a signal.
var hubPairInterrupts = func() (<-chan os.Signal, func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	return ch, func() { signal.Stop(ch) }
}

// hubPairTerminal is cmd's stdin and stdout when both are terminals.
func hubPairTerminal(cmd *cobra.Command) (in, out *os.File, ok bool) {
	in, inOK := cmd.InOrStdin().(*os.File)
	out, outOK := cmd.OutOrStdout().(*os.File)
	if !inOK || !outOK || !term.IsTerminal(int(in.Fd())) || !term.IsTerminal(int(out.Fd())) {
		return nil, nil, false
	}
	return in, out, true
}

// pairTTY is one `hub pair` in a terminal: the hub's pairing stream on one
// side, the owner's keyboard and Ctrl-C on the other.
//
// The owner's answer is bound to the request the prompt showed (#2384, the
// terminal side of #2191): the confirm names that sas's code,
// moves_to_relay and request (pairConfirmRequest), so the hub refuses it
// code_changed when the phone's request was replaced meanwhile. A
// replacement while the prompt is open prints the new code; the line being
// read across it may answer the earlier code, so it is not sent: the owner
// is told and asked again. A code_changed from the hub asks about the
// newer request, or, while its sas is still on its way, waits for it with
// no prompt open (the code expiring meanwhile ends the pairing expired).
// What was typed before a read starts is dropped (hubPairFlush, after the
// prompt is printed), so a line a fresh read returns was typed after that
// read's prompt; a flush that fails takes no typed answer: the prompt is a
// no.
type pairTTY struct {
	c        *hub.ControlClient
	inFile   *os.File
	in       *bufio.Reader
	out      *os.File
	expires  time.Time  // the code's expiry, from the qr event
	macName  string     // the host's name from the link, made safe ("" when it names none)
	device   string     // the phone whose code is shown, once a sas came
	name     string     // that phone's name, made safe
	shown    hubPairSAS // device's latest request: the open prompt's, or newer while none is open
	sent     hubPairSAS // the request the last answer sent was bound to
	answers  <-chan ttyAnswer
	stale    bool // a prompt was printed while answers was being read
	asking   bool // a prompt is open: the owner's next line answers it
	answered bool // the owner's answer was sent to the hub
	awaiting bool // code_changed came before the newer sas: no prompt until it does
	expiry   <-chan time.Time
}

// ttyAnswer is one line of the owner's: yes, or eof when the terminal
// closed (Ctrl-D) before a line.
type ttyAnswer struct{ yes, eof bool }

// The lines of a replaced request (#2384).
const (
	hubPairReplaced    = "The phone sent a new code."
	hubPairStaleAnswer = "The code changed, so that answer was not sent. Check the code on your phone and answer again."
	hubPairCodeChanged = "The phone sent a new code before your answer reached the hub. Nothing was linked."
	hubPairAwaitingNew = "Waiting for the phone's new code…"
	hubPairFlushFailed = "Could not clear what was typed before this question, so no answer can be taken."
)

// hubPairRelayMove is the line over a prompt whose request moves the host
// to Relay: the Mac sheet's approved copy (MobilePairingModel
// .relayMoveWarning, ask #1829).
func hubPairRelayMove(macName string) string {
	if macName == "" {
		macName = "this Mac"
	}
	return "Linking this iPhone moves " + macName + " to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe."
}

// hubPairFlush drops what was typed into the terminal and not read yet; a
// seam so tests make it fail.
var hubPairFlush = flushTerminalInput

// hubPairReadDeadline sets the pairing stream's read deadline; a seam so
// tests see which deadline a step sets without waiting for it.
var hubPairReadDeadline = func(c *hub.ControlClient, t time.Time) { _ = c.SetReadDeadline(t) }

func (p *pairTTY) deadline(t time.Time) { hubPairReadDeadline(p.c, t) }

// hubPairReading, when set, is told when a read of the owner's line starts
// (true, after the flush) and returns (false); a seam so tests type only
// into an open read.
var hubPairReading func(bool)

type pairNext struct {
	a   hub.ControlAnswer
	err error
}

// runHubPairTTY is `hub pair` without --json: the QR in block characters,
// the [y/N] SAS prompt, one line per outcome (spec §10).
func runHubPairTTY(cmd *cobra.Command) error {
	in, out, ok := hubPairTerminal(cmd)
	if !ok {
		return &exitCodeError{code: 2, err: errors.New(hubPairNoTerminal)}
	}
	c, err := hubPairDial()
	if err != nil {
		return err
	}
	defer func() { _ = c.Close() }()
	interrupts, stop := hubPairInterrupts()
	defer stop()

	done := make(chan struct{})
	defer close(done)
	events := make(chan pairNext)
	go func() {
		for {
			a, err := c.Next()
			select {
			case events <- pairNext{a, err}:
			case <-done:
				return
			}
			if err != nil {
				return
			}
		}
	}()

	p := &pairTTY{c: c, inFile: in, in: bufio.NewReader(in), out: out}
	for {
		select {
		case <-interrupts:
			p.println()
			if p.answered {
				// The answer is with the hub and the phone may still link:
				// no line that says it did not.
				return &exitCodeError{code: 130, err: errQuietExit}
			}
			if p.asking {
				if req, ok, err := pairConfirmRequest(p.device, p.shown, false, pairAnswer{}); ok && err == nil {
					_ = c.Send(req)
				}
			}
			return &exitCodeError{code: 130, err: errors.New(hubPairCancelled)} //nolint:staticcheck // ST1005: the owner's line (ask #883)
		case ans := <-p.answers:
			if err := p.answer(ans); err != nil {
				return err
			}
		case <-p.expiry:
			p.expiry = nil
			if p.awaiting {
				// The newer request never came within the code's life.
				return &exitCodeError{code: 1, err: errors.New(hubPairRefusal(wire.RefusedExpiredCode))}
			}
			p.println()
			if err := p.confirm(false); err != nil {
				return err
			}
		case n := <-events:
			if n.err != nil {
				var ne net.Error
				if errors.As(n.err, &ne) && ne.Timeout() {
					// Before an answer the code ran out; after one the hub
					// never said how the pairing ended.
					reason := wire.RefusedExpiredCode
					if p.answered {
						reason = "timeout"
					}
					return &exitCodeError{code: 1, err: errors.New(hubPairRefusal(reason))}
				}
				return fmt.Errorf("the hub closed the pairing: %w", n.err)
			}
			end, err := p.handle(n.a)
			if end || err != nil {
				return err
			}
		}
	}
}

// answer takes the owner's line. A line that comes with no prompt open
// (the code expired first) is dropped. A line read while a newer prompt
// was printed may answer the earlier code: it is not sent, and the owner is
// asked again. The terminal closing is a no whichever code was on screen:
// the owner left, and the no is bound to the request shown last.
func (p *pairTTY) answer(ans ttyAnswer) error {
	p.answers = nil
	stale := p.stale
	p.stale = false
	switch {
	case !p.asking:
		return nil
	case stale && !ans.eof:
		p.println(hubPairStaleAnswer)
		return p.prompt()
	}
	p.expiry = nil
	return p.confirm(ans.yes)
}

// prompt asks about p.shown and opens the answer. A read already out
// (started for an earlier prompt) is marked stale. Otherwise, once the
// prompt is printed, what was typed before it is dropped and a fresh read
// starts; a flush that fails takes no typed answer, and the prompt is a no.
func (p *pairTTY) prompt() error {
	p.awaiting = false
	p.deadline(time.Time{}) // before the prompt shows: the owner takes their time
	if p.shown.MovesToRelay {
		p.println(hubPairRelayMove(p.macName))
	}
	_, _ = fmt.Fprintf(p.out, "Confirm code %s on your phone? [y/N] ", sanitizeForTerminal(p.shown.Code))
	p.asking, p.answered = true, false
	if p.expiry == nil && !p.expires.IsZero() {
		p.expiry = time.After(time.Until(p.expires))
	}
	if p.answers != nil {
		p.stale = true
		return nil
	}
	if err := hubPairFlush(p.inFile); err != nil {
		p.println("", hubPairFlushFailed)
		p.expiry = nil
		return p.confirm(false)
	}
	// A tty in canonical mode returns at most one line per read, so the
	// buffer is empty here; a terminal in raw mode (stty -icanon) can hand
	// a read several lines, and the ones after the line answered were
	// typed before this prompt.
	_, _ = p.in.Discard(p.in.Buffered()) // Discard of Buffered() cannot fail
	p.answers = p.readAnswer()
	return nil
}

// sas takes a sas event of p.device (or the first phone's): the first
// opens the prompt; a replaced request (another code, moves_to_relay or
// request) prints the new code while the prompt is open or while waiting
// for it after a code_changed, and while the answer is with the hub waits
// for the hub's code_changed. A repeat of the request shown, or a new name
// alone, is no replacement.
func (p *pairTTY) sas(a hub.ControlAnswer) error {
	line := hubPairSAS{Event: a.Event, DeviceID: a.DeviceID, Name: a.Name, Code: a.Code, MovesToRelay: a.MovesToRelay,
		Request: a.Request}
	if p.device == "" {
		p.device, p.name, p.shown = a.DeviceID, sanitizeForTerminal(a.Name), line
		p.println("", `"`+p.name+`" wants to link.`)
		return p.prompt()
	}
	if line.Code == p.shown.Code && line.MovesToRelay == p.shown.MovesToRelay && line.Request == p.shown.Request {
		return nil
	}
	p.name, p.shown = sanitizeForTerminal(a.Name), line
	switch {
	case p.awaiting:
		p.println(`"` + p.name + `" wants to link.`)
	case p.asking:
		p.println("", hubPairReplaced, `"`+p.name+`" wants to link.`)
	default:
		return nil
	}
	return p.prompt()
}

// handle prints one line of the stream; end is true once the pairing is
// over (err nil: linked, exit 0).
func (p *pairTTY) handle(a hub.ControlAnswer) (end bool, err error) {
	if a.Event == "" {
		if a.Error == hub.ErrClassHubOff {
			return true, errors.New("the hub is not running")
		}
		if a.Op == hub.OpConfirm && (a.Error == hub.ErrClassNoCode || a.Error == hub.ErrClassNoRequest) {
			// The request expired while the owner looked at the code.
			return true, &exitCodeError{code: 1, err: errors.New(hubPairRefusal(wire.RefusedExpiredCode))}
		}
		if a.Op == hub.OpConfirm && a.Error == hub.ErrClassCodeChanged {
			// The phone's request was replaced before the answer reached the
			// hub: the newer request is asked about, or, while its sas is
			// still on its way, awaited with no prompt open.
			p.println(hubPairCodeChanged)
			if p.shown == p.sent {
				p.awaiting, p.answered = true, false
				if !p.expires.IsZero() {
					// The wait is the code's, not the answer's: the
					// after-confirm deadline would end it early.
					p.deadline(p.expires.Add(hubPairGrace))
					if p.expiry == nil {
						p.expiry = time.After(time.Until(p.expires))
					}
				}
				p.println(hubPairAwaitingNew)
				return false, nil
			}
			p.println(`"` + p.name + `" wants to link.`)
			return false, p.prompt()
		}
		if err := hubAnswerError(a); err != nil {
			return true, err
		}
		return false, nil
	}
	switch a.Event {
	case link.EventQR:
		if a.ExpiresAt != nil {
			p.expires = *a.ExpiresAt
			p.deadline(p.expires.Add(hubPairGrace))
		}
		return false, p.printQR(a.URL)
	case link.EventWaiting:
		p.println("", hubPairWaiting)
	case link.EventSAS:
		if p.device != "" && !strings.EqualFold(a.DeviceID, p.device) {
			return false, nil // another phone while this one waits for the owner
		}
		return false, p.sas(a)
	case link.EventLinked:
		if p.device == "" || !strings.EqualFold(a.DeviceID, p.device) {
			return false, nil
		}
		p.println(`Linked "`+p.name+`".`,
			"To let it type into sessions or start them: watchtower hub allow "+sanitizeForTerminal(a.DeviceID)+" typing|start_sessions")
		return true, nil
	case link.EventRefused:
		if p.device != "" && !strings.EqualFold(a.DeviceID, p.device) {
			return false, nil
		}
		return true, &exitCodeError{code: 1, err: errors.New(hubPairRefusal(a.Reason))}
	}
	return false, nil
}

// printQR prints the code's header, the QR (or, in a window narrower than
// the QR, the hint to widen it), the link and the expiry.
func (p *pairTTY) printQR(url string) error {
	name := "this host"
	if lp, err := wire.ParseLinkURL(url); err == nil && lp.MacName != "" {
		name = sanitizeForTerminal(lp.MacName)
		p.macName = name
	}
	p.println("Link your iPhone to "+name, "")
	width, err := termqr.Width(url)
	if err != nil {
		return fmt.Errorf("hub pair: the code does not fit a QR code: %w", err)
	}
	if cols, _, err := term.GetSize(int(p.out.Fd())); err == nil && cols < width {
		p.println(fmt.Sprintf("Widen this window to at least %d columns to see the QR code.", width))
	} else if _, err := termqr.Render(p.out, url); err != nil {
		return err
	}
	expiry := "Needs a phone with Relay."
	if !p.expires.IsZero() {
		expiry += " The code expires at " + p.expires.Local().Format("15:04") + "."
	}
	p.println("",
		"Scan it with the Watchtower app on your iPhone, or open this link on the phone:",
		url, // the hub's own base64url link, never a phone's text
		expiry)
	return nil
}

// readAnswer reads the owner's line once: y or yes in any case is a yes;
// anything else a no, and the terminal closing before a line (EOF) eof.
// Only one read is out at a time (p.answers).
func (p *pairTTY) readAnswer() <-chan ttyAnswer {
	ch := make(chan ttyAnswer, 1)
	reading := hubPairReading // read here: a reader can outlive the run
	go func() {
		if reading != nil {
			reading(true)
		}
		line, err := p.in.ReadString('\n')
		if reading != nil {
			reading(false)
		}
		if err != nil && line == "" {
			ch <- ttyAnswer{eof: true}
			return
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes":
			ch <- ttyAnswer{yes: true}
		default:
			ch <- ttyAnswer{}
		}
	}()
	return ch
}

// confirm sends the owner's answer, bound to the request shown
// (pairConfirmRequest: a yes on a hub that names no request is
// errPairHubTooOld, nothing sent); the hub's linked or refused ends the
// stream within hubPairAfterConfirm.
func (p *pairTTY) confirm(yes bool) error {
	req, _, err := pairConfirmRequest(p.device, p.shown, false, pairAnswer{confirm: yes})
	if err != nil {
		return err
	}
	p.deadline(time.Now().Add(hubPairAfterConfirm)) // before the send: the hub may answer at once
	if err := p.c.Send(req); err != nil {
		return fmt.Errorf("the hub closed the pairing: %w", err)
	}
	p.asking, p.answered, p.sent = false, true, p.shown
	return nil
}

func (p *pairTTY) println(lines ...string) {
	if len(lines) == 0 {
		lines = []string{""}
	}
	for _, l := range lines {
		_, _ = fmt.Fprintln(p.out, l)
	}
}
