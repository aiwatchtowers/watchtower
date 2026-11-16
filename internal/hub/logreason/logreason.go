// Package logreason names a hub error for a log line without its text, and
// keeps a failure that repeats every few seconds from flooding the log
// (#1873). An error's text can carry record contents or relay messages, so
// only enum codes and Go type names reach the log.
package logreason

import (
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"watchtower/internal/hub/transport/relay/client"
)

// Of names err for a log line: the hosted relay's error code when the chain
// carries one ("relay code INTERNAL"), else the Go type of the deepest typed
// error in it ("*net.OpError"), else "untyped" (only errors.New /
// fmt.Errorf texts). Never the error's text.
func Of(err error) string {
	if err == nil {
		return "no error"
	}
	var pe *client.Error
	if errors.As(err, &pe) && pe.E != nil {
		return "relay code " + strings.TrimPrefix(pe.E.GetCode().String(), "ERROR_CODE_")
	}
	if name, _ := deepestTyped(err, 0); name != "" {
		return name
	}
	return "untyped"
}

// With is a log line's class followed by err's reason: "unavailable: relay
// code UNAVAILABLE", "other: *net.OpError". A class that already names the
// relay's code (relay_internal, relay_<code>, #1872) stands alone.
func With(class string, err error) string {
	if strings.HasPrefix(class, "relay_") {
		return class
	}
	return class + ": " + Of(err)
}

// untyped is the wrappers and text-only errors that name nothing.
var untyped = map[string]bool{
	"*errors.errorString": true,
	"*fmt.wrapError":      true,
	"*fmt.wrapErrors":     true,
	"*errors.joinError":   true,
}

// maxDepth bounds the chain walk.
const maxDepth = 32

// deepestTyped walks err's chain (joins depth-first, in order) and returns
// the type of the deepest error that is not a bare text or a wrapper, with
// its depth (-1 when there is none); the first one found wins a tie.
func deepestTyped(err error, depth int) (string, int) {
	if err == nil || depth > maxDepth {
		return "", -1
	}
	name, at := "", -1
	if t := fmt.Sprintf("%T", err); !untyped[t] {
		name, at = t, depth
	}
	var children []error
	// The chain itself is walked here, one link at a time: errors.As has no
	// "every link" form.
	switch u := err.(type) { //nolint:errorlint // walks each link, not a match
	case interface{ Unwrap() []error }:
		children = u.Unwrap()
	case interface{ Unwrap() error }:
		children = []error{u.Unwrap()}
	}
	for _, c := range children {
		if n, d := deepestTyped(c, depth+1); d > at {
			name, at = n, d
		}
	}
	return name, at
}

// RepeatEvery is how often a repeating hub failure line reaches the log.
const RepeatEvery = 10 * time.Minute

// maxLines bounds the distinct lines a Limiter remembers.
const maxLines = 256

// Limiter logs a line the first time it is seen, then at most once per
// every, naming the copies it held back in between. A line that stops
// repeating loses its held-back count (nothing flushes it): its first copy
// was logged, and the hub's status carries the live state.
type Limiter struct {
	every time.Duration
	now   func() time.Time
	print func(string)

	mu    sync.Mutex
	lines map[string]*seen
}

type seen struct {
	logged time.Time // when the line last reached the log
	held   int       // copies held back since then
}

// NewLimiter returns a Limiter on now's clock that prints through log.Print.
func NewLimiter(every time.Duration, now func() time.Time) *Limiter {
	return &Limiter{every: every, now: now, print: func(s string) { log.Print(s) }, lines: map[string]*seen{}}
}

// Printf formats the line and logs it unless the same line was logged less
// than every ago; the next copy logged after that says how many were held.
func (l *Limiter) Printf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	now := l.now()
	l.mu.Lock()
	s, ok := l.lines[line]
	if ok && now.Sub(s.logged) < l.every {
		s.held++
		l.mu.Unlock()
		return
	}
	out := line
	if ok && s.held > 0 {
		out += fmt.Sprintf(" (repeated %d more times over %s)", s.held, now.Sub(s.logged).Round(time.Second))
	}
	if !ok {
		l.prune(now)
		s = &seen{}
		l.lines[line] = s
	}
	s.logged, s.held = now, 0
	l.mu.Unlock()
	l.print(out)
}

// prune drops the lines last logged every or more ago once the map is
// full; with every line recent it drops them all (a new burst starts fresh).
func (l *Limiter) prune(now time.Time) {
	if len(l.lines) < maxLines {
		return
	}
	for k, s := range l.lines {
		if now.Sub(s.logged) >= l.every {
			delete(l.lines, k)
		}
	}
	if len(l.lines) >= maxLines {
		clear(l.lines)
	}
}
