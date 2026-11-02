package planusage

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/codex"
	"watchtower/internal/db"
)

// CodexStore is the publication/history slice used by the adapter. Network and
// process calls must complete before any of these methods open a transaction.
type CodexStore interface {
	GetCodexPlanUsageStatus() (*db.CodexPlanUsageStatus, error)
	UpsertCodexPlanUsageStatus(db.CodexPlanUsageStatus) error
	PublishCodexPlanUsage(db.CodexPlanUsageStatus, []db.CodexPlanUsageSample) error
	CodexPlanUsageHistory(string, string, time.Time, time.Time, time.Time) ([]db.PlanUsageSample, error)
}

func codexLimits(snapshot codex.UsageSnapshot) ([]WindowLimit, error) {
	limits := make([]WindowLimit, 0, len(snapshot.Quotas))
	seen := map[string]bool{}
	for _, q := range snapshot.Quotas {
		if q.Key == "" || seen[q.Key] || !percentValid(q.UsedPercent) {
			return nil, errors.New("codex plan usage: invalid normalized quota")
		}
		seen[q.Key] = true
		l := WindowLimit{Key: q.Key, Percent: q.UsedPercent, WindowDurationMinutes: q.DurationMinutes,
			Group: "window", Projection: Projection{State: "idle"}}
		if q.DurationMinutes != nil && *q.DurationMinutes > 0 {
			switch *q.DurationMinutes {
			case 300:
				l.Group, l.Label = "session", "5 hours"
			case 10080:
				l.Group, l.Label = "weekly", "Weekly"
			default:
				l.Label = fmt.Sprintf("%d minutes", *q.DurationMinutes)
			}
		} else {
			l.WindowDurationMinutes = nil
			l.Label = "Usage"
		}
		if q.Name != "" {
			l.Label += " · " + q.Name
		}
		if q.ResetsAt != nil {
			reset := time.Unix(*q.ResetsAt, 0).UTC()
			l.ResetsAt = &reset
		}
		limits = append(limits, l)
	}
	if len(limits) == 0 {
		return nil, errors.New("codex plan usage: no normalized quotas")
	}
	return limits, nil
}

// StoreCodexUsage consumes a successful normalized response. Projection reads
// happen before the single atomic status+samples publication. The caller holds
// the provider lock across the fetch and this function.
func StoreCodexUsage(store CodexStore, now time.Time, snapshot codex.UsageSnapshot) error {
	now = now.UTC().Truncate(time.Second)
	limits, err := codexLimits(snapshot)
	if err != nil {
		return err
	}
	if snapshot.IdentityKnown != (snapshot.Scope != "") {
		return errors.New("codex plan usage: inconsistent normalized identity")
	}
	samples := []db.CodexPlanUsageSample{}
	current := map[string]bool{}
	for i, l := range limits {
		history := []db.PlanUsageSample{}
		if snapshot.IdentityKnown {
			s := db.PlanUsageSample{LimitKey: l.Key, TakenAt: now, Percent: l.Percent}
			if l.ResetsAt != nil {
				s.ResetsAt = *l.ResetsAt
				history, err = store.CodexPlanUsageHistory(snapshot.Scope, l.Key, now.Add(-lookback(l.Group)), now, *l.ResetsAt)
				if err != nil {
					return fmt.Errorf("codex plan usage: load projection history: %w", err)
				}
			}
			// A same-second poll replaces the observation, matching the database
			// upsert so status, candidate and its current sample remain coherent.
			filtered := history[:0]
			for _, old := range history {
				if !old.TakenAt.Equal(now) {
					filtered = append(filtered, old)
				}
			}
			history = append(filtered, s)
			samples = append(samples, db.CodexPlanUsageSample{PlanUsageSample: s, Scope: snapshot.Scope})
			current[l.Key] = len(CurrentWindowSamples(history, l, now)) > 0
		}
		limits[i].Projection = ProjectWindow(now, l, history)
	}
	plot, err := BuildPlot(now, limits, snapshot.IdentityKnown, current)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(limits)
	if err != nil {
		return fmt.Errorf("codex plan usage: encode limits: %w", err)
	}
	st := db.CodexPlanUsageStatus{PlanUsageStatus: db.PlanUsageStatus{State: "ok", Plan: snapshot.PlanType,
		FetchedAt: &now, UpdatedAt: now, LimitsJSON: string(encoded), BreakdownJSON: "[]", PlotJSON: plot},
		Scope: snapshot.Scope, IdentityKnown: snapshot.IdentityKnown, OrdinaryUsageAllowed: snapshot.OrdinaryUsageAllowed}
	return store.PublishCodexPlanUsage(st, samples)
}

// StoreCodexFailure stores only closed safe source codes, never transport text.
// A response that did not confirm the last scope invalidates identity proof.
// Last-good plot/fetchedAt survive for diagnostics but are ineligible to draw.
func StoreCodexFailure(store CodexStore, now time.Time, snapshot codex.UsageSnapshot, code string) error {
	switch code {
	case "no_credentials", "unsupported_auth", "cli_missing", "unsupported_cli", "network", "parse", "timeout":
	default:
		return errors.New("codex plan usage: invalid source error code")
	}
	previous, err := store.GetCodexPlanUsageStatus()
	if err != nil {
		return fmt.Errorf("codex plan usage: read retained status: %w", err)
	}
	st := db.CodexPlanUsageStatus{PlanUsageStatus: db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]", PlotJSON: "{}"}}
	if previous != nil {
		st = *previous
	}
	if !snapshot.IdentityKnown || previous == nil || snapshot.Scope != previous.Scope {
		st.Scope, st.IdentityKnown, st.OrdinaryUsageAllowed = "", false, nil
		// Raw retained fields stay private; readers explicitly suppress them
		// while identity is unconfirmed. No prior account becomes current.
	} else {
		st.Scope, st.IdentityKnown = snapshot.Scope, true
	}
	now = now.UTC().Truncate(time.Second)
	st.State, st.Reason, st.LastError = "error", code, "Codex usage: "+code
	if code == "no_credentials" || code == "unsupported_auth" || code == "cli_missing" || code == "unsupported_cli" {
		st.State = "unavailable"
	}
	st.UpdatedAt, st.LastErrorAt = now, &now
	return store.UpsertCodexPlanUsageStatus(st)
}

// DecodeWindowLimits validates stored quota/projection values without inventing
// absent windows. Rate sanitization belongs to public eligibility, not storage.
func DecodeWindowLimits(text string) ([]WindowLimit, error) {
	limits := []WindowLimit{}
	if err := json.Unmarshal([]byte(text), &limits); err != nil || limits == nil {
		return nil, errors.New("plan usage: malformed stored limits")
	}
	var raw []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(text), &raw); err != nil {
		return nil, errors.New("plan usage: malformed stored limits")
	}
	seen := map[string]bool{}
	for i, l := range limits {
		if value, ok := raw[i]["percent"]; !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("plan usage: missing stored percent")
		}
		var projection map[string]json.RawMessage
		if err := json.Unmarshal(raw[i]["projection"], &projection); err != nil {
			return nil, errors.New("plan usage: malformed stored projection")
		}
		if value, ok := projection["rate_per_hour"]; !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("plan usage: missing stored rate")
		}
		if l.Key == "" || seen[l.Key] || !percentValid(l.Percent) || !validProjectionState(l.Projection.State) {
			return nil, errors.New("plan usage: invalid stored limit")
		}
		seen[l.Key] = true
	}
	return limits, nil
}

// VisibleCodexLimits prevents a retained scoped row from proving the current
// account. A successful unknown-ID response still exposes its own current values.
func VisibleCodexLimits(st db.CodexPlanUsageStatus) ([]WindowLimit, error) {
	if !st.IdentityKnown && st.State != "ok" {
		return []WindowLimit{}, nil
	}
	return DecodeWindowLimits(st.LimitsJSON)
}
