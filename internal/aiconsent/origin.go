package aiconsent

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"
)

// ErrPaused refuses a background model call that was not admitted while
// background AI is not allowed.
var ErrPaused = errors.New("Background AI is paused") //nolint:staticcheck // ST1005: the exact user-facing text (spec §4.2)

// Origin says who started a model call.
type Origin int

const (
	// OriginOwner: the owner's own gesture (a typed command, a click, a reply).
	OriginOwner Origin = iota
	// OriginBackground: a timer, a sync cycle or an event.
	OriginBackground
)

const (
	// EnvOrigin=background marks a process started by a background unit.
	EnvOrigin = "WATCHTOWER_AI_ORIGIN"
	// EnvAdmitted=<unit id> marks that unit as started under consent.
	EnvAdmitted = "WATCHTOWER_AI_ADMITTED"
	// RunMarkerEnv is the automation run marker; it equals
	// automations.RunEnvMarker (pinned there).
	RunMarkerEnv = "WATCHTOWER_AUTOMATION_RUN_ID"

	envBackground = "background"
)

type originMark struct {
	origin Origin
	unit   string // admitted unit id; "" = not admitted
}

type originKey struct{}

// WithOwnerStarted marks ctx as serving the owner's gesture.
func WithOwnerStarted(ctx context.Context) context.Context {
	return context.WithValue(ctx, originKey{}, originMark{origin: OriginOwner})
}

// WithAdmitted marks ctx as a background unit that started under consent;
// unit names it (e.g. "phase:digests", "run:7") and travels to its children.
func WithAdmitted(ctx context.Context, unit string) context.Context {
	if unit == "" {
		unit = "unit"
	}
	return context.WithValue(ctx, originKey{}, originMark{origin: OriginBackground, unit: unit})
}

// proc is the process default, set once by InitProcess.
var proc struct {
	mu     sync.Mutex
	mark   originMark
	runID  string // automation run marker whose trigger is not read yet
	lookup func(runID int64) (string, error)
}

// InitProcess sets the process default origin: role "daemon" is background;
// otherwise EnvOrigin=background is background (admitted when EnvAdmitted is
// set); otherwise the automation run marker takes its run's trigger, read
// once on first use; otherwise owner.
func InitProcess(role string, getenv func(string) string) {
	proc.mu.Lock()
	defer proc.mu.Unlock()
	proc.mark, proc.runID = originMark{origin: OriginOwner}, ""
	switch {
	case role == "daemon":
		proc.mark.origin = OriginBackground
	case getenv(EnvOrigin) == envBackground:
		proc.mark = originMark{origin: OriginBackground, unit: getenv(EnvAdmitted)}
	case getenv(RunMarkerEnv) != "":
		proc.runID = getenv(RunMarkerEnv)
	}
}

// SetRunTriggerLookup wires how a process under the run marker reads its
// run's trigger (the DB lives outside this leaf package).
func SetRunTriggerLookup(f func(runID int64) (trigger string, err error)) {
	proc.mu.Lock()
	defer proc.mu.Unlock()
	proc.lookup = f
}

// BackgroundTrigger reports whether an automation run trigger is background.
func BackgroundTrigger(trigger string) bool {
	switch trigger {
	case "schedule", "catch_up", "event", "sync":
		return true
	}
	return false
}

// processMark returns the process default, resolving a pending run marker.
// Fails closed: no lookup yet, an unparsable id or a lookup error read as
// background. A resolved trigger and an unparsable id are kept; no lookup
// and a lookup error are retried on the next call.
func processMark() originMark {
	background := originMark{origin: OriginBackground}
	proc.mu.Lock()
	raw, lookup, mark := proc.runID, proc.lookup, proc.mark
	if raw == "" || lookup == nil {
		proc.mu.Unlock()
		if raw == "" {
			return mark
		}
		return background
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		proc.runID, proc.mark = "", background
		proc.mu.Unlock()
		logf("aiconsent: %s=%q is not a run id (%v); its AI calls run as background", RunMarkerEnv, raw, err)
		return background
	}
	proc.mu.Unlock()

	// The lookup reads the database: run it outside the lock.
	trigger, err := lookup(id)
	if err != nil {
		// Not cached: the next call retries.
		logf("aiconsent: cannot read the trigger of automation run %d (%v); its AI calls run as background", id, err)
		return background
	}
	resolved := background
	if !BackgroundTrigger(trigger) {
		resolved = originMark{origin: OriginOwner}
	}
	proc.mu.Lock()
	if proc.runID == raw { // InitProcess did not run meanwhile
		proc.runID, proc.mark = "", resolved
	}
	proc.mu.Unlock()
	return resolved
}

func markOf(ctx context.Context) originMark {
	if m, ok := ctx.Value(originKey{}).(originMark); ok {
		return m
	}
	return processMark()
}

// OriginOf returns who started the call in ctx: the ctx mark wins, else the
// process default.
func OriginOf(ctx context.Context) (o Origin, admitted bool) {
	m := markOf(ctx)
	return m.origin, m.origin == OriginBackground && m.unit != ""
}

// Check is CheckWith(ctx, Current).
func Check(ctx context.Context) error { return CheckWith(ctx, Current) }

// CheckWith refuses with ErrPaused only a background call that was not
// admitted while r() is not allowed. A nil r reads Current.
func CheckWith(ctx context.Context, r Reader) error {
	if o, admitted := OriginOf(ctx); o == OriginOwner || admitted {
		return nil
	}
	if r == nil {
		r = Current
	}
	if !r().Allowed() {
		return ErrPaused
	}
	return nil
}

// ChildEnv is the env a background ctx passes to a process it spawns:
// EnvOrigin=background and, when admitted, EnvAdmitted=<unit>. nil for an
// owner ctx. Spawn sites build the child env as
// append(OwnerEnv(os.Environ()), ChildEnv(ctx)...), so an owner child never
// inherits this process's own EnvOrigin/EnvAdmitted.
func ChildEnv(ctx context.Context) []string {
	m := markOf(ctx)
	if m.origin != OriginBackground {
		return nil
	}
	env := []string{EnvOrigin + "=" + envBackground}
	if m.unit != "" {
		env = append(env, EnvAdmitted+"="+m.unit)
	}
	return env
}

// OwnerEnv returns env without EnvOrigin and EnvAdmitted, for a spawn that
// serves one owner request.
func OwnerEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if strings.HasPrefix(kv, EnvOrigin+"=") || strings.HasPrefix(kv, EnvAdmitted+"=") {
			continue
		}
		out = append(out, kv)
	}
	return out
}
