package providerrouting

import (
	"context"
	"time"

	"watchtower/internal/providerhealth"
)

// Status is content-free local quota metadata. A passed reset is not recovery.
// Only a successful real request clears quota_wait. Tokens, account scope keys
// and lease ownership are deliberately absent from this DTO.
type Status struct {
	Provider      string               `json:"provider"`
	State         providerhealth.State `json:"state"`
	ManualAllowed *bool                `json:"manual_allowed,omitempty"`
	NextProbeAt   *time.Time           `json:"next_probe_at,omitempty"`
}

// Status reads precisely the same account/model scopes as selection, without
// claiming a probe, starting a provider, or evaluating untrusted capabilities.
func (r *Router) Status(ctx context.Context, req Request, p string) (Status, error) {
	out := Status{Provider: p, State: providerhealth.Available}
	if err := r.allowed(p); err != nil {
		return out, err
	}
	if r.Health == nil {
		return out, providerhealth.ErrDegraded
	}
	for _, scope := range scopes(req, p) {
		snapshot, err := r.Health.Peek(ctx, scope)
		if err != nil {
			return out, err
		}
		if snapshot.State == providerhealth.Available {
			continue
		}
		if out.State != providerhealth.ProbeLeased {
			out.State = snapshot.State
		}
		if !snapshot.NextProbeAt.IsZero() && (out.NextProbeAt == nil || snapshot.NextProbeAt.After(*out.NextProbeAt)) {
			at := snapshot.NextProbeAt
			out.NextProbeAt = &at
		}
	}
	return out, nil
}

// CheckStatus reserves the existing metadata-only rate gate for precisely the
// routing account/model scopes. It never claims a lease or clears a quota.
func (r *Router) CheckStatus(ctx context.Context, req Request, p string) (Status, error) {
	status, err := r.Status(ctx, req, p)
	if err != nil {
		return status, err
	}
	allowed := true
	for _, scope := range scopes(req, p) {
		ok, err := r.Health.ManualCheck(ctx, scope)
		if err != nil {
			return status, err
		}
		allowed = allowed && ok
	}
	status.ManualAllowed = &allowed
	return status, nil
}
