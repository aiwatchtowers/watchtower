package digest

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"watchtower/internal/providers"
)

func TestBatchIsolationOverrides(t *testing.T) {
	args, _ := generateArgs("m", "", "prompt")
	for _, a := range [][]string{args, imageArgs("m", ""), validateModelArgs("m")} {
		joined := strings.Join(a, " ")
		for _, flag := range []string{"--strict-mcp-config", "--disable-slash-commands", `--settings {"disableAllHooks":true}`} {
			if !strings.Contains(joined, flag) {
				t.Errorf("missing %s: %s", flag, joined)
			}
		}
	}
}

func TestBatchMetadataInvocationAndTypedQuota(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// The SDK emits rate_limit_event on stream-json + verbose. This fake
	// refuses to supply that metadata when the actual argv selects another mode.
	body := `#!/bin/sh
cat >/dev/null
case "$*" in *"--output-format stream-json"*"--verbose"*) ;; *) exit 42 ;; esac
printf '%s\n' '{"type":"rate_limit_event","session_id":"a","rate_limit_info":{"status":"rejected","resetsAt":1700003600,"rateLimitType":"seven_day","isUsingOverage":false,"overageStatus":"rejected"}}'
printf '%s\n' '{"type":"result","session_id":"a","subtype":"error_during_execution","is_error":true,"result":"Call rejected"}'
exit 1
`
	bin := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(bin, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	gen := NewClaudeGenerator("m", "m", bin)
	gen.SetIsolatedChild()
	_, _, _, err := gen.Generate(context.Background(), "", "prompt", "")
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure.Category != providers.Quota || failure.ResetAt.Unix() != 1700003600 || failure.Bucket != "" || failure.Window != "seven_day" {
		t.Fatalf("failure=%+v err=%v", failure, err)
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		t.Fatal("lost exit cause")
	}
}
func TestQuotaCauseSurvivesTimeoutDecorator(t *testing.T) {
	typed := &providers.Failure{Provider: "claude", Category: providers.Quota, Scope: "installation", Cause: errors.New("diagnostic")}
	_, _, _, err := WithCallTimeout(errGenerator{typed}, time.Second).Generate(context.Background(), "", "", "")
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure != typed {
		t.Fatalf("lost typed cause: %v", err)
	}
	if errors.Is(err, ErrAICall) {
		t.Fatal("quota became a transport failure")
	}
	// The deadline wrapper must preserve every original cause, including an
	// error produced by a CLI while cancellation was reaching the child.
	wrapped := (&timeoutGenerator{timeout: time.Second}).deadlineError(typed)
	if !errors.As(wrapped, &failure) || failure.Category != providers.Timeout || !errors.Is(wrapped, typed) || !errors.Is(wrapped, ErrAICall) || !errors.Is(wrapped, context.DeadlineExceeded) {
		t.Fatalf("deadline lost causes: %v", wrapped)
	}
}
func TestClaudeGeneratorTerminalTrust(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, tc := range []struct {
		name, body string
		want       providers.ErrorCategory
	}{
		{"terminal", `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached|1760000000"}`, providers.Quota},
		{"partial", `{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Claude AI usage limit reached|1760000000"}`, providers.Budget},
		{"unknown", `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"usage limit reached"}`, providers.Unknown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			gen := NewClaudeGenerator("m", "m", fakeClaude(t, tc.body, 0))
			gen.SetIsolatedChild()
			_, _, _, err := gen.Generate(context.Background(), "", "prompt", "")
			var failure *providers.Failure
			if !errors.As(err, &failure) || failure.Category != tc.want {
				t.Fatalf("failure=%+v err=%v", failure, err)
			}
		})
	}
}

func TestImageCapabilityRefusalStaysTyped(t *testing.T) {
	wrapped := WithCallTimeout(errGenerator{errors.New("not called")}, time.Second)
	if _, ok := ImageCapable(wrapped); ok {
		t.Fatal("text leaf acquired image capability")
	}
	_, _, err := wrapped.(ImageGenerator).GenerateWithImage(context.Background(), "", "", "missing.png", "image/png")
	var failure *providers.Failure
	if !errors.As(err, &failure) || failure.Category != providers.Capability {
		t.Fatalf("untyped image refusal: %v", err)
	}
}

func TestBatchChildKeepsAuthAndTransportWithoutTools(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	auth, capture := t.TempDir(), t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", auth)
	t.Setenv("WT_PROFILE_CAPTURE", capture)
	t.Setenv("ANTHROPIC_BASE_URL", "https://models.example.com")
	bin := filepath.Join(t.TempDir(), "claude")
	script := `#!/bin/sh
printf '%s\n' "$@" >"$WT_PROFILE_CAPTURE/args"
printf '%s' "$CLAUDE_CONFIG_DIR" >"$WT_PROFILE_CAPTURE/home"
printf '%s' "$ANTHROPIC_BASE_URL" >"$WT_PROFILE_CAPTURE/transport"
cat >"$WT_PROFILE_CAPTURE/stdin"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
`
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	gen := NewClaudeGenerator("m", "m", bin)
	gen.SetIsolatedChild()
	if _, _, _, err := gen.Generate(context.Background(), "system-marker", "user-marker", ""); err != nil {
		t.Fatal(err)
	}
	read := func(name string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(capture, name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	raw := read("args")
	args := strings.Split(raw, "\n")
	for _, flag := range []string{"--strict-mcp-config", "--disable-slash-commands"} {
		if !slices.Contains(args, flag) {
			t.Errorf("missing %s", flag)
		}
	}
	if !containsPair(args, "--tools", "") || !containsPair(args, "--settings", `{"disableAllHooks":true}`) {
		t.Fatalf("tools/hooks inherited: %v", args)
	}
	if strings.Contains(raw, "system-marker") || strings.Contains(raw, "user-marker") || slices.Contains(args, "--bare") {
		t.Fatal("prompt on argv or subscription auth disabled")
	}
	if read("home") != auth || read("transport") != "https://models.example.com" || read("stdin") != "user-marker" {
		t.Fatal("authentication/transport/stdin changed")
	}
}
