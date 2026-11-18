package daemon

import (
	"context"

	"watchtower/internal/aiconsent"
)

// SetConsent injects the background-AI consent reader. nil (the default)
// reads aiconsent.Current, never "ungated" (fail closed). The built-ins'
// slot runner (SetBuiltins) reads the same one.
func (d *Daemon) SetConsent(r aiconsent.Reader) {
	d.consent = r
	if d.builtins != nil {
		d.builtins.SetConsent(r)
	}
}

// consentNow reads the consent state and logs the paused line once per
// state change (effective state and reason), not once per cycle.
func (d *Daemon) consentNow() aiconsent.State {
	r := d.consent
	if r == nil {
		r = aiconsent.Current
	}
	s := r()
	if s.Effective != d.consentLogged.Effective || s.Reason != d.consentLogged.Reason {
		d.consentLogged = s
		if line := aiconsent.LogLine(s); line != "" {
			d.logger.Print(line)
		}
	}
	return s
}

// aiPhase runs fn, a cycle phase that calls a model, only while background
// AI is allowed, on a ctx admitted as the unit "phase:<name>". The state is
// read before each phase, so a pause written mid-cycle lets the running
// phase finish and skips the next one (D12). Paused, it returns before the
// phase's own checks, lock, pipeline_runs or automation_runs row.
func (d *Daemon) aiPhase(ctx context.Context, name string, fn func(ctx context.Context)) {
	if !d.consentNow().Allowed() {
		return
	}
	fn(aiconsent.WithAdmitted(ctx, "phase:"+name))
}
