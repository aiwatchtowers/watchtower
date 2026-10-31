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
type pairTTY struct {
	c       *hub.ControlClient
	in      *bufio.Reader
	out     *os.File
	expires time.Time // the code's expiry, from the qr event
	device  string    // the phone whose code is shown, once a sas came
	name    string    // that phone's name, made safe
	asking  bool      // the SAS prompt was just printed
}

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

	p := &pairTTY{c: c, in: bufio.NewReader(in), out: out}
	var answer <-chan bool      // the owner's line, while the prompt is up
	var expiry <-chan time.Time // the code's expiry, while the prompt is up
	for {
		select {
		case <-interrupts:
			if answer != nil {
				_ = c.Send(hub.ControlRequest{Op: hub.OpConfirm, Device: p.device, Confirm: false})
			}
			p.println()
			return &exitCodeError{code: 130, err: errors.New(hubPairCancelled)} //nolint:staticcheck // ST1005: the owner's line (ask #883)
		case yes := <-answer:
			answer, expiry = nil, nil
			if err := p.confirm(yes); err != nil {
				return err
			}
		case <-expiry:
			answer, expiry = nil, nil
			p.println()
			if err := p.confirm(false); err != nil {
				return err
			}
		case n := <-events:
			if n.err != nil {
				var ne net.Error
				if errors.As(n.err, &ne) && ne.Timeout() {
					return &exitCodeError{code: 1, err: errors.New(hubPairRefusal(wire.RefusedExpiredCode))}
				}
				return fmt.Errorf("the hub closed the pairing: %w", n.err)
			}
			end, err := p.handle(n.a)
			if end || err != nil {
				return err
			}
			if p.asking {
				p.asking = false
				answer = p.readAnswer()
				if !p.expires.IsZero() {
					expiry = time.After(time.Until(p.expires))
				}
			}
		}
	}
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
		if err := hubAnswerError(a); err != nil {
			return true, err
		}
		return false, nil
	}
	switch a.Event {
	case link.EventQR:
		if a.ExpiresAt != nil {
			p.expires = *a.ExpiresAt
			_ = p.c.SetReadDeadline(p.expires.Add(hubPairGrace))
		}
		return false, p.printQR(a.URL)
	case link.EventWaiting:
		p.println("", hubPairWaiting)
	case link.EventSAS:
		if p.device != "" {
			return false, nil // another phone while this one waits for the owner
		}
		p.device, p.name = a.DeviceID, sanitizeForTerminal(a.Name)
		_ = p.c.SetReadDeadline(time.Time{})
		p.println("", `"`+p.name+`" wants to link.`)
		_, _ = fmt.Fprintf(p.out, "Confirm code %s on your phone? [y/N] ", sanitizeForTerminal(a.Code))
		p.asking = true
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
// anything else, or the terminal closing (EOF), a no.
func (p *pairTTY) readAnswer() <-chan bool {
	ch := make(chan bool, 1)
	go func() {
		line, err := p.in.ReadString('\n')
		if err != nil && line == "" {
			ch <- false
			return
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes":
			ch <- true
		default:
			ch <- false
		}
	}()
	return ch
}

// confirm sends the owner's answer; the hub's linked or refused ends the
// stream within hubPairAfterConfirm.
func (p *pairTTY) confirm(yes bool) error {
	if err := p.c.Send(hub.ControlRequest{Op: hub.OpConfirm, Device: p.device, Confirm: yes}); err != nil {
		return fmt.Errorf("the hub closed the pairing: %w", err)
	}
	_ = p.c.SetReadDeadline(time.Now().Add(hubPairAfterConfirm))
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
