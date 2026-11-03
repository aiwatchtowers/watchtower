package chat

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"watchtower/internal/providers"
)

func TestClaudeTypedTerminalCause(t *testing.T) {
	tr := NewClaudeTranslator(func() string { return "turn" })
	events := feedAll(t, tr,
		`{"type":"rate_limit_event","session_id":"a","rate_limit_info":{"status":"rejected","resetsAt":1700003600,"rateLimitType":"seven_day","isUsingOverage":false,"overageStatus":"rejected"}}`,
		`{"type":"result","session_id":"a","subtype":"error_during_execution","is_error":true,"result":"Call rejected"}`)
	if len(events) != 2 || events[1].Type != EventError {
		t.Fatalf("events=%+v", events)
	}
	var failure *providers.Failure
	if !errors.As(events[1].Cause, &failure) || failure.Category != providers.Quota || failure.ResetAt.Unix() != 1700003600 {
		t.Fatalf("failure=%+v", failure)
	}
	// This step does not change protocol-v2 wire codes or expose Go diagnostics.
	raw, err := json.Marshal(events[1])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "Cause") || strings.Contains(string(raw), "subscription_quota") {
		t.Fatalf("host cause leaked into protocol: %s", raw)
	}
	events = feedAll(t, tr, `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"unknown failure"}`)
	if !errors.As(events[1].Cause, &failure) || failure.Category != providers.Unknown {
		t.Fatal("previous turn's quota leaked")
	}
	events = feedAll(t, tr, `{"type":"result","subtype":"success","is_error":false,"result":"Claude AI usage limit reached|1760000000"}`)
	if len(events) != 2 || events[1].Type != EventTurnDone || events[1].Cause != nil {
		t.Fatal("successful model text established quota")
	}
}
