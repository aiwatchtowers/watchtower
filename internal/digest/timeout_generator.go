package digest

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/url"
	"os/exec"
	"regexp"
	"syscall"
	"time"
)

// DaemonAICallTimeout bounds a single AI subprocess call made from the
// daemon's sequential pipeline cycle. Without a deadline, a hung claude/codex
// process holds sync.lock for as long as the process lives, freezing every
// later phase in that cycle indefinitely (H8). Interactive commands (ask,
// chat) are bounded by the user instead and must NOT go through this
// decorator — see cliPooledGenerator vs cliGenerator in cmd/generator.go.
const DaemonAICallTimeout = 10 * time.Minute

// timeoutGenerator wraps a Generator so every call is bounded by a wall-clock
// deadline derived from the caller's context, without replacing that
// context — a parent cancellation (e.g. daemon shutdown) still propagates.
type timeoutGenerator struct {
	inner   Generator
	timeout time.Duration
}

// WithCallTimeout returns a Generator that fails a call once it runs longer
// than d, rather than blocking forever on a hung subprocess. Every
// implementation of Generator ultimately runs its subprocess via
// exec.CommandContext(ctx, ...), so the derived deadline kills the process.
//
// The decorator sits INSIDE PooledGenerator (cliPooledGenerator wraps the raw
// generator, then hands it to NewPooledGenerator), so d bounds the call
// itself: time a call spends queued for a pool slot is NOT counted against it.
// A saturated pool can therefore still delay a phase past d — what this
// guarantees is that no single subprocess runs longer than d.
func WithCallTimeout(inner Generator, d time.Duration) Generator {
	return &timeoutGenerator{inner: inner, timeout: d}
}

// CallTimeout reports the bound g carries, if any. Boundedness is otherwise
// invisible from outside this package, and the wiring tests that pin every
// unattended AI path as bounded (H8) need to see it.
func CallTimeout(g Generator) (time.Duration, bool) {
	tg, ok := g.(*timeoutGenerator)
	if !ok {
		return 0, false
	}
	return tg.timeout, true
}

// Generate implements Generator.
//
// A call killed by OUR deadline is reported as a deadline error — wrapping
// context.DeadlineExceeded so errors.Is works at every caller — with the
// inner generator's own message kept in the text (a killed subprocess reports
// "signal: killed", which is the useful part). A call that died because the
// CALLER's context expired (daemon shutdown, a shorter caller deadline) keeps
// its message: it is not our cap that fired, and saying so would send the
// reader looking for a 10-minute hang that never happened. A transport-level
// failure (see ErrAICall) also matches ErrAICall; its message is unchanged.
func (g *timeoutGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	parent := ctx
	ctx, cancel := context.WithTimeout(parent, g.timeout)
	defer cancel()

	result, usage, newSessionID, err := g.inner.Generate(ctx, systemPrompt, userMessage, sessionID)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) && parent.Err() == nil {
		return "", nil, "", WithCause(fmt.Errorf("ai call exceeded %s (%v): %w", g.timeout, err, context.DeadlineExceeded), ErrAICall)
	}
	if err != nil && aiTransportFailure(err) {
		return result, usage, newSessionID, WithCause(err, ErrAICall)
	}
	return result, usage, newSessionID, err
}

// ErrAICall marks a failure of an AI call that says nothing about the
// request: the call timed out, its process could not start or was killed,
// the network to the provider failed, the provider reported an outage, or
// the CLI's login or key is not usable (aiUnavailable). The
// history backfill retries those instead of counting a strike against the
// chunk (docs/features/history-backfill.md). Any other reply — an error
// envelope such as error_max_turns, an empty result, output the parser
// cannot read — is about the request and does not match.
var ErrAICall = errors.New("ai call failed")

// aiTransportFailure reports the failures ErrAICall stands for.
func aiTransportFailure(err error) bool {
	var execErr *exec.Error
	var pathErr *fs.PathError
	var exitErr *exec.ExitError
	return errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, exec.ErrNotFound) ||
		errors.As(err, &execErr) || errors.As(err, &pathErr) ||
		(errors.As(err, &exitErr) && !exitErr.Exited()) || // killed by a signal
		NetworkFailure(err) ||
		aiUnavailable.MatchString(err.Error())
}

// NetworkFailure reports a connection-level failure: a timeout, a dial/
// read/write error, a DNS failure, or a reset, refused or unreachable
// connection. A *url.Error alone is not enough: a bad certificate, a
// malformed URL or a refused redirect will not clear by waiting.
func NetworkFailure(err error) bool {
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	var opErr *net.OpError
	var dnsErr *net.DNSError
	var urlErr *url.Error
	return errors.As(err, &opErr) || errors.As(err, &dnsErr) ||
		// The server closed the connection mid-request ("Get …: EOF").
		(errors.As(err, &urlErr) && (errors.Is(urlErr.Err, io.EOF) || errors.Is(urlErr.Err, io.ErrUnexpectedEOF))) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH)
}

// aiUnavailable matches what the claude, codex and Ollama generators report,
// inside an error envelope or on stderr, when the provider cannot serve any
// request right now: a connection error, an overloaded API, a 5xx or 429
// status, a rate limit, a request timeout, or a login or API key that is
// missing, invalid or expired. None of them is about the request, so they
// are transport failures. The list is explicit and narrow: error_max_turns,
// an empty result or unreadable output stay reply errors.
var aiUnavailable = regexp.MustCompile(`(?i)` +
	`api error: (connection error|5\d\d\b|429\b)|overloaded_error|\boverloaded\b|rate_limit_error|` +
	`request timed out|status code (5\d\d|429)\b|ollama returned http (5\d\d|429)\b|` +
	`invalid api key|authentication_error|not logged in|please run /login|` +
	`(oauth token|login|session|credentials?) (has )?expired`)

// WithCause returns an error with err's message that also matches cause in
// errors.Is and errors.As, so a generator can keep its readable message and
// still expose the exec error behind it.
func WithCause(err, cause error) error { return causeError{err, cause} }

type causeError struct{ err, cause error }

func (e causeError) Error() string   { return e.err.Error() }
func (e causeError) Unwrap() []error { return []error{e.err, e.cause} }
