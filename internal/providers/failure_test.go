package providers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

func requireCategory(t *testing.T, err error, want ErrorCategory) *Failure {
	t.Helper()
	var failure *Failure
	if !errors.As(err, &failure) || failure.Category != want {
		t.Fatalf("category(%v)=%+v want %s", err, failure, want)
	}
	return failure
}
func TestTerminalFailureCategories(t *testing.T) {
	sentinel := errors.New("sentinel")
	for _, tc := range []struct {
		code   string
		status int
		want   ErrorCategory
	}{
		{"usage_limit_reached", 429, Quota}, {"usage_limit_reached", 401, Auth}, {"usage_limit_reached", 403, Policy}, {"rate_limit_error", 429, RateLimit}, {"server_overloaded", 503, Overload},
		{"authentication_error", 401, Auth}, {"model_not_found", 404, Model}, {"policy_denied", 403, Policy},
		{"context_length_exceeded", 400, ContextLimit}, {"error_max_turns", 0, Budget}, {"", 429, RateLimit},
		{"quota_exceeded", 0, Unknown}, {"usage_not_included", 0, Unknown}, {"", 0, Unknown},
	} {
		t.Run(tc.code+fmt.Sprint(tc.status), func(t *testing.T) {
			err := TerminalFailure("codex", FailureDetail{Code: tc.code, ResetsAt: 1700003600}, tc.status, sentinel)
			failure := requireCategory(t, err, tc.want)
			if !errors.Is(err, sentinel) {
				t.Fatal("lost cause")
			}
			if tc.want == Quota && (failure.Scope != "installation" || !failure.ResetAt.Equal(time.Unix(1700003600, 0))) {
				t.Fatalf("quota hints=%+v", failure)
			}
			if tc.want != Quota && (!failure.ResetAt.IsZero() || failure.Scope != "") {
				t.Fatalf("nonquota hints=%+v", failure)
			}
		})
	}
}
func TestClaudeTerminalQuotaTrust(t *testing.T) {
	for _, tc := range []struct {
		name, event, subtype, message string
		failed                        bool
		raw                           string
		want                          ErrorCategory
	}{
		{"machine quota", "result", "error_during_execution", "", true, `{"type":"usage_limit_reached","resets_at":1700003600}`, Quota},
		{"fixture message", "result", "error_during_execution", "Claude AI usage limit reached|1760000000", true, "", Quota},
		{"successful quoted message", "result", "success", "Claude AI usage limit reached|1760000000", false, "", Unknown},
		{"tool message", "user", "error_during_execution", "Claude AI usage limit reached|1760000000", true, "", Unknown},
		{"partial output", "result", "error_max_turns", "Claude AI usage limit reached|1760000000", true, "", Budget},
		{"partial conflicting raw error", "result", "error_max_turns", "partial text", true, `{"type":"usage_limit_reached"}`, Budget},
		{"unrecognized subtype", "result", "future_subtype", "", true, `{"type":"usage_limit_reached"}`, Unknown},
		{"unknown phrase", "result", "error_during_execution", "usage limit reached", true, "", Unknown},
		{"short 429", "result", "error_during_execution", "API Error: 429 rate_limit_error", true, "", RateLimit},
		{"conflicting auth code", "result", "error_during_execution", "Claude AI usage limit reached|1760000000", true, `{"type":"authentication_error"}`, Auth},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_ = requireCategory(t, ClaudeResultFailure(tc.event, tc.subtype, tc.failed, json.RawMessage(tc.raw), tc.message, nil, errors.New("diagnostic")), tc.want)
		})
	}
}
func TestClaudeRateMetadataRequiresTerminalRejection(t *testing.T) {
	// Primary schema fixture: anthropics/claude-agent-sdk-python
	// tests/test_rate_limit_event_repro.py. Neutral synthetic session/reset.
	for _, tc := range []struct {
		name, status, overage, window string
		using, failed                 bool
		want                          ErrorCategory
	}{
		{"hard limit", "rejected", "rejected", "seven_day", false, true, Quota},
		{"warning", "allowed_warning", "rejected", "seven_day", false, true, Unknown},
		{"allowed", "allowed", "rejected", "seven_day", false, true, Unknown},
		{"overage available", "rejected", "allowed", "seven_day", false, true, Unknown},
		{"using overage", "rejected", "rejected", "seven_day", true, true, Unknown},
		{"unknown bucket", "rejected", "rejected", "other", false, true, Unknown},
		{"success", "rejected", "rejected", "seven_day", false, false, Unknown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			info := &ClaudeRateLimitInfo{Status: tc.status, OverageStatus: tc.overage, RateLimitType: tc.window, IsUsingOverage: &tc.using, ResetsAt: 1700003600}
			err := ClaudeResultFailure("result", "error_during_execution", tc.failed, nil, "failed", info, errors.New("diagnostic"))
			f := requireCategory(t, err, tc.want)
			if tc.want == Quota && (f.Window != "seven_day" || f.Bucket != "" || f.ResetAt.Unix() != 1700003600) {
				t.Fatalf("hints=%+v", f)
			}
		})
	}
	rejected := `{"type":"rate_limit_event","session_id":"a","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","overageStatus":"rejected"}}`
	for _, output := range []string{
		rejected + "\n" + `{"type":"result","is_error":true}` + "\n" + `{"type":"result","is_error":true}`,
		rejected + "\n" + `{"type":"result","session_id":"b","is_error":true}`,
		`{"type":"assistant","rate_limit_info":{"status":"rejected"}}` + "\n" + `{"type":"result","is_error":true}`,
	} {
		if got := ClaudeResultLimit([]byte(output)); got != nil {
			t.Fatalf("uncorrelated quota hint: %+v", got)
		}
	}
}
func TestContextFailureKeepsCauses(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	sentinel := errors.New("transport")
	err := ContextFailure("codex", ctx, sentinel)
	_ = requireCategory(t, err, Cancelled)
	if !errors.Is(err, context.Canceled) || !errors.Is(err, sentinel) {
		t.Fatal("context/inner cause lost")
	}
}

func TestCodexHumanQuotaTemplates(t *testing.T) {
	// Display templates from openai/codex rust-v0.166.0
	// codex-rs/protocol/src/error.rs UsageLimitReachedError::fmt.
	for _, message := range []string{
		"You’ve hit your usage limit. Try again later.",
		"You’ve hit your usage limit. Try again at Nov 3rd, 2026 2:30 PM.",
		"You’ve hit your usage limit. To get more access now, send a request to your admin or try again later.",
		"You’ve hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again later.",
		"You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again later.",
		"You've hit your usage limit. Try again at 2:30 PM.",
		"You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again later.",
	} {
		f := requireCategory(t, CodexMessageFailure(message, errors.New("diagnostic")), Quota)
		if !f.ResetAt.IsZero() {
			t.Fatal("guessed timezone from a local display reset")
		}
	}
	for _, message := range []string{
		"usage limit reached", "You’ve hit your usage limit, please retry", "You’ve hit your usage limit. Try again at an unknown time.", "Quota exceeded. Check your plan and billing details.",
		"quoted: You’ve hit your usage limit. Try again later.", "You’ve hit your usage limit. Try again later. Model continuation",
	} {
		_ = requireCategory(t, CodexMessageFailure(message, errors.New("diagnostic")), Unknown)
	}
}

func TestProfileRefusalAndReplayBoundary(t *testing.T) {
	for _, profile := range []InvocationProfile{BatchText, Image, ReviewReadonly, ToolPreflight} {
		if profile.ReplaySafe() != (profile == BatchText || profile == Image) {
			t.Fatalf("unsafe replay for %s", profile)
		}
	}
	cause := errors.New("CLI rejected startup")
	for _, provider := range []string{"claude", "codex"} {
		err := ProfileStartupFailure(provider, BatchText, "error: unknown option '--disable-slash-commands'", cause)
		failure := requireCategory(t, err, Capability)
		if !errors.Is(err, cause) || failure.Required != BatchText {
			t.Fatal("lost startup cause/profile")
		}
		typed := WithFailure(provider, Quota, cause)
		if got := ProfileStartupFailure(provider, BatchText, "error: unknown option '--settings'", typed); !errors.Is(got, typed) {
			t.Fatal("stderr replaced trusted terminal classification")
		}
	}
}

func TestOptionalClaudeMetadataStaysConservative(t *testing.T) {
	cause := errors.New("diagnostic")
	for _, info := range []*ClaudeRateLimitInfo{
		{Status: "rejected", RateLimitType: "five_hour", OverageStatus: "rejected"},
		{Status: "rejected", RateLimitType: "five_hour", IsUsingOverage: new(bool)},
	} {
		_ = requireCategory(t, ClaudeResultFailure("result", "error_during_execution", true, nil, "rejected", info, cause), Unknown)
	}
	tracker := ClaudeLimitTracker{}
	_ = tracker.Observe([]byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}`))
	_ = tracker.Observe([]byte(`{"type":"system","subtype":"init"}`))
	if info := tracker.Observe([]byte(`{"type":"result"}`)); info != nil {
		t.Fatal("stale metadata survived a new turn init")
	}
	_ = tracker.Observe([]byte(`{"type":"rate_limit_event","parent_tool_use_id":"child","rate_limit_info":{"status":"rejected"}}`))
	if info := tracker.Observe([]byte(`{"type":"result"}`)); info != nil {
		t.Fatal("subagent metadata established main-turn quota")
	}
	_ = requireCategory(t, ClaudeResultFailure("result", "success", true, nil, "API Error: 429 rate_limit_error", nil, cause), RateLimit)
	_ = requireCategory(t, ClaudeResultFailure("result", "success", true, nil, "API Error: 4291 issue", nil, cause), Unknown)
}

func TestCodexNamedModelQuotaRequiresSelectedModel(t *testing.T) {
	// Primary source: codex rust-v0.166.0 protocol/src/error.rs:691-708.
	message := "You’ve hit your usage limit for GPT-5.6-Sol. Switch to another model now, or try again later."
	f := requireCategory(t, CodexModelMessageFailure(message, "gpt-5.6-sol", errors.New("diagnostic")), Quota)
	if f.Scope != "model" || f.Bucket != "gpt-5.6-sol" {
		t.Fatalf("scope: %+v", f)
	}
	for _, model := range []string{"", "gpt-other", "codex", "gpt-reserve"} {
		_ = requireCategory(t, CodexModelMessageFailure(message, model, errors.New("diagnostic")), Unknown)
	}
	for _, message := range []string{"You hit your spend cap set in your workspace. Increase your spend cap to continue.", "Your workspace is out of credits. Add credits to continue.", "You’ve hit your usage limit for gpt-5.6-sol. Ask billing.", "You’ve hit your usage limit for promo. Switch to another model now, or try again later."} {
		_ = requireCategory(t, CodexModelMessageFailure(message, "gpt-5.6-sol", errors.New("diagnostic")), Unknown)
	}
}

// A clean exit without a completion takes the category its stderr names when
// a line is one of the narrow CLI diagnostics, else invalid_output; never
// quota.
func TestCleanExitFailure(t *testing.T) {
	cases := []struct {
		stderr string
		want   ErrorCategory
	}{
		{"", InvalidOutput},
		{"something unrelated", InvalidOutput},
		{"Invalid API key · Please run /login", Auth},
		{"warming up\nAPI Error: 401 {}", Auth},
		{"API Error: 429 slow down", RateLimit},
		{"Overloaded", Overload},
		{"API Error: 403 forbidden", Policy},
		{"usage limit reached", InvalidOutput},
	}
	for _, tc := range cases {
		_ = requireCategory(t, CleanExitFailure("claude", tc.stderr, errors.New("diagnostic")), tc.want)
	}
}
