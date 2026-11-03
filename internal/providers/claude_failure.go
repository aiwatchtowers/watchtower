package providers

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strconv"
	"time"
)

// ClaudeRateLimitInfo is subscription metadata emitted by Claude Code 2.1.45+.
// A warning/utilization reading is never evidence of a rejected call.
// Schema: anthropics/claude-agent-sdk-python tests/test_rate_limit_event_repro.py.
type ClaudeRateLimitInfo struct {
	Status         string `json:"status"`
	ResetsAt       int64  `json:"resetsAt"`
	RateLimitType  string `json:"rateLimitType"`
	IsUsingOverage *bool  `json:"isUsingOverage"`
	OverageStatus  string `json:"overageStatus"`
}

// ClaudeLimitTracker only consumes top-level CLI events, and clears its state
// at every result. It must be local to a child/turn; never reuse shared health.
type ClaudeLimitTracker struct {
	info    *ClaudeRateLimitInfo
	session string
}

func (t *ClaudeLimitTracker) Observe(line []byte) *ClaudeRateLimitInfo {
	var e struct {
		Subtype         string               `json:"subtype"`
		ParentToolUseID *string              `json:"parent_tool_use_id"`
		Type            string               `json:"type"`
		Session         string               `json:"session_id"`
		Info            *ClaudeRateLimitInfo `json:"rate_limit_info"`
	}
	if json.Unmarshal(line, &e) != nil {
		t.info, t.session = nil, ""
		return nil
	}
	if e.ParentToolUseID != nil && *e.ParentToolUseID != "" {
		return nil
	}
	switch e.Type {
	case "system":
		if e.Subtype == "init" {
			t.info, t.session = nil, ""
		}
	case "rate_limit_event":
		t.info, t.session = e.Info, e.Session
	case "result":
		info := t.info
		if t.session != "" && e.Session != "" && t.session != e.Session {
			info = nil
		}
		t.info, t.session = nil, ""
		return info
	}
	return nil
}

// ClaudeResultLimit handles both JSON arrays and newline-delimited stream
// output. Only metadata correlated with the final result is returned.
func ClaudeResultLimit(output []byte) *ClaudeRateLimitInfo {
	var lines []json.RawMessage
	trimmed := bytes.TrimSpace(output)
	if len(trimmed) > 0 && trimmed[0] == '[' {
		if json.Unmarshal(trimmed, &lines) != nil {
			return nil
		}
	} else {
		for line := range bytes.SplitSeq(trimmed, []byte("\n")) {
			lines = append(lines, line)
		}
	}
	var tracker ClaudeLimitTracker
	var result *ClaudeRateLimitInfo
	for _, line := range lines {
		var e struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		hint := tracker.Observe(line)
		if e.Type == "result" {
			result = hint
		}
	}
	return result
}

var claudeUsageLimit = regexp.MustCompile(`^Claude AI usage limit reached\|([0-9]+)$`)

// ClaudeResultFailure classifies only a failed terminal result. Human quota
// fallback is anchored to the existing CLI fixture in chat's classifier tests;
// model partial output (max turns/budget) is never searched for quota phrases.
func ClaudeResultFailure(eventType, subtype string, isError bool, raw json.RawMessage, message string, limit *ClaudeRateLimitInfo, cause error) error {
	err := ClaudeFailure(eventType, subtype, isError, raw, cause)
	if eventType != "result" || !isError || (subtype != "error_during_execution" && subtype != "success") {
		return err
	}
	var detail FailureDetail
	if json.Unmarshal(raw, &detail) == nil && (detail.Code != "" || detail.Type != "") {
		return err
	}
	if limit != nil && limit.Status == "rejected" && limit.IsUsingOverage != nil && !*limit.IsUsingOverage && limit.OverageStatus == "rejected" && subscriptionWindow(limit.RateLimitType) {
		return &Failure{Provider: "claude", Category: Quota, ResetAt: resetTime(limit.ResetsAt), Scope: "installation", Window: limit.RateLimitType, Cause: cause}
	}
	if match := claudeUsageLimit.FindStringSubmatch(message); match != nil {
		seconds, parseErr := strconv.ParseInt(match[1], 10, 64)
		if parseErr != nil {
			seconds = 0
		}
		return &Failure{Provider: "claude", Category: Quota, ResetAt: resetTime(seconds), Scope: "installation", Cause: cause}
	}
	return TerminalFailure("claude", FailureDetail{Type: subtype, Message: message}, 0, cause)
}
func subscriptionWindow(window string) bool {
	switch window {
	case "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet":
		return true
	}
	return false
}
func resetTime(seconds int64) time.Time {
	if seconds <= 0 || seconds > 253402300799 {
		return time.Time{}
	}
	return time.Unix(seconds, 0).UTC()
}
