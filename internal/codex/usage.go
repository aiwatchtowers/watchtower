package codex

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// UsageError contains only a stable safe code; transport payloads are never exposed.
type UsageError struct{ Code string }

func (e *UsageError) Error() string { return "codex usage: " + e.Code }

// UsageSnapshot contains current limits. Scope is a one-way account/home namespace
// hash, never the source account identifier. Unknown identity forbids history reuse.
type UsageSnapshot struct {
	Scope                string
	IdentityKnown        bool
	PlanType             string
	OrdinaryUsageAllowed *bool
	Quotas               []UsageQuota
}

type UsageQuota struct {
	Key             string
	Bucket          string
	Name            string
	Slot            string
	UsedPercent     float64
	DurationMinutes *int64
	ResetsAt        *int64
}

type usageAccount struct {
	Account *struct {
		Type     string `json:"type"`
		PlanType string `json:"planType"`
	} `json:"account"`
}
type usageLimits struct {
	AccountID            *string                    `json:"accountId"`
	OrdinaryUsageAllowed *bool                      `json:"ordinaryUsageAllowed"`
	RateLimits           json.RawMessage            `json:"rateLimits"`
	ByID                 map[string]json.RawMessage `json:"rateLimitsByLimitId"`
}
type usageBucket struct {
	LimitID   string          `json:"limitId"`
	LimitName string          `json:"limitName"`
	PlanType  string          `json:"planType"`
	Primary   json.RawMessage `json:"primary"`
	Secondary json.RawMessage `json:"secondary"`
}
type usageWindow struct {
	UsedPercent *float64 `json:"usedPercent"`
	Duration    *int64   `json:"windowDurationMins"`
	Reset       *int64   `json:"resetsAt"`
}

// ReadUsage runs a bounded read-only app-server conversation in a neutral folder.
// bin must be the resolved CLI path; env is its complete environment. codexHome
// identifies the config namespace (normally OwnerHome()). No auth files are read.
// A parse failure can return verified identity metadata alongside the safe error.
func ReadUsage(ctx context.Context, bin string, env []string, codexHome string) (UsageSnapshot, error) {
	return readUsage(ctx, usageProcess(bin, env), codexHome, appServerBudget)
}

// errCLIMissing is the launcher's answer for a bin that is not there.
var errCLIMissing = errors.New("codex CLI missing")

// usageProcess is ReadUsage's app-server: bin, if it exists, started in the
// neutral temp folder.
func usageProcess(bin string, env []string) appServerLauncher {
	return func() (AppServerConn, error) {
		if _, err := exec.LookPath(bin); err != nil {
			return nil, errCLIMissing
		}
		return appServerProcess(bin, nil, env, os.TempDir())()
	}
}

// ReadUsageFrom is ReadUsage over the app-server launch returns, under the
// same conversation budget: the seam another package's test drives an
// in-process server (codextest) through.
func ReadUsageFrom(ctx context.Context, launch func() (AppServerConn, error), codexHome string) (UsageSnapshot, error) {
	return readUsage(ctx, launch, codexHome, appServerBudget)
}

func readUsage(ctx context.Context, launch appServerLauncher, codexHome string, limit time.Duration) (out UsageSnapshot, err error) {
	out = UsageSnapshot{Quotas: []UsageQuota{}}
	if err := ctx.Err(); err != nil {
		return out, usageFailure(ctx, ctx, err)
	}
	s, err := openAppServer(ctx, launch, limit)
	if errors.Is(err, errCLIMissing) {
		return out, &UsageError{Code: "cli_missing"}
	}
	if err != nil {
		return out, usageFailure(ctx, ctx, err)
	}
	budget := s.budget
	defer func() {
		closeErr := s.Close()
		// Close owns the final bounded phase of this fetch. Its cancellation
		// must not turn a partially completed conversation into a success.
		if err == nil && (closeErr != nil || ctx.Err() != nil || errors.Is(budget.Err(), context.DeadlineExceeded)) {
			if closeErr == nil {
				closeErr = ctx.Err()
			}
			err = usageFailure(ctx, budget, closeErr)
		}
	}()
	if err = s.initialize(budget); err != nil {
		return out, usageFailure(ctx, budget, err)
	}
	var account usageAccount
	if err = s.call(budget, "account/read", map[string]any{"refreshToken": false}, &account); err != nil {
		return out, usageFailure(ctx, budget, err)
	}
	if account.Account == nil {
		return out, &UsageError{Code: "no_credentials"}
	}
	if account.Account.Type != "chatgpt" {
		return out, &UsageError{Code: "unsupported_auth"}
	}
	out.PlanType = account.Account.PlanType
	var raw json.RawMessage
	if err = s.call(budget, "account/rateLimits/read", map[string]any{"excludeResetCreditDetails": true}, &raw); err != nil {
		return out, usageFailure(ctx, budget, err)
	}
	return normalizeUsage(raw, codexHome, out)
}

func usageFailure(ctx, budget context.Context, err error) error {
	code := "network"
	var rpc *rpcError
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		code = "cancelled"
	case errors.Is(budget.Err(), context.DeadlineExceeded):
		code = "timeout"
	case errors.As(err, &rpc) && rpc.Code == -32601:
		code = "unsupported_cli"
	case strings.Contains(err.Error(), "unreadable answer"), strings.Contains(err.Error(), "unexpected result"):
		code = "parse"
	}
	return &UsageError{Code: code}
}

func normalizeUsage(raw []byte, home string, out UsageSnapshot) (UsageSnapshot, error) {
	var wire usageLimits
	if err := json.Unmarshal(raw, &wire); err != nil {
		return out, &UsageError{Code: "parse"}
	}
	out.OrdinaryUsageAllowed = wire.OrdinaryUsageAllowed
	if wire.AccountID != nil && strings.TrimSpace(*wire.AccountID) != "" {
		sum := sha256.Sum256([]byte(home + "\x00" + *wire.AccountID))
		out.Scope = hex.EncodeToString(sum[:])
		out.IdentityKnown = true
	}
	buckets := wire.ByID
	if len(buckets) == 0 {
		key := "codex"
		var legacy usageBucket
		if json.Unmarshal(wire.RateLimits, &legacy) == nil && legacy.LimitID != "" {
			key = legacy.LimitID
		}
		buckets = map[string]json.RawMessage{key: wire.RateLimits}
	}
	keys := make([]string, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	malformed := false
	for _, key := range keys {
		var b usageBucket
		if len(buckets[key]) == 0 || string(buckets[key]) == "null" || json.Unmarshal(buckets[key], &b) != nil {
			malformed = true
			continue
		}
		if out.PlanType == "" {
			out.PlanType = b.PlanType
		}
		for _, slot := range []struct {
			name string
			raw  json.RawMessage
		}{{"primary", b.Primary}, {"secondary", b.Secondary}} {
			if len(slot.raw) == 0 || string(slot.raw) == "null" {
				continue
			}
			var w usageWindow
			if json.Unmarshal(slot.raw, &w) != nil || w.UsedPercent == nil || math.IsNaN(*w.UsedPercent) || math.IsInf(*w.UsedPercent, 0) {
				malformed = true
				continue
			}
			if w.Duration != nil && *w.Duration <= 0 {
				w.Duration = nil
			}
			if w.Reset != nil && *w.Reset <= 0 {
				w.Reset = nil
			}
			duration := "unknown"
			if w.Duration != nil {
				duration = fmt.Sprint(*w.Duration)
			}
			// Length prefix avoids collisions even with arbitrary bucket identifiers.
			quotaKey := fmt.Sprintf("%d:%s:%s:%s", len(key), key, slot.name, duration)
			out.Quotas = append(out.Quotas, UsageQuota{Key: quotaKey, Bucket: key, Name: b.LimitName, Slot: slot.name, UsedPercent: math.Max(0, math.Min(100, *w.UsedPercent)), DurationMinutes: w.Duration, ResetsAt: w.Reset})
		}
	}
	if malformed || len(out.Quotas) == 0 {
		return out, &UsageError{Code: "parse"}
	}
	return out, nil
}
