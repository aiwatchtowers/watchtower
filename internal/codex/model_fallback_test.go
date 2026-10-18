package codex

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"watchtower/internal/digest"
)

// refusingCodex writes a fake codex that answers "ok:<model>" for the
// models in accepted and refuses every other one the way codex-cli 0.145
// does (exit 1, the refusal only in the JSONL turn.failed event), with
// refusal as the server's message ("%s" = the model). Each run's model is
// appended to the returned log file.
func refusingCodex(t *testing.T, refusal string, accepted ...string) (bin, runLog string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI test skipped on windows")
	}
	t.Cleanup(refusedModels.Clear)
	dir := t.TempDir()
	bin, runLog = filepath.Join(dir, "codex"), filepath.Join(dir, "runs.log")
	msg := strings.ReplaceAll(refusal, "%s", "$model")
	script := `#!/bin/sh
case "$1" in --version) echo "codex-cli 0.145.0"; exit 0;; esac
cat >/dev/null
model=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--model" ]; then model="$a"; fi
  prev="$a"
done
echo "$model" >> '` + runLog + `'
case " ` + strings.Join(accepted, " ") + ` " in
*" $model "*)
  echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok:$model\"}}"
  exit 0;;
esac
echo "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"error\",\"message\":\"Model metadata for $model not found.\"}}"
echo "{\"type\":\"error\",\"message\":\"{\\\"type\\\":\\\"error\\\",\\\"status\\\":400,\\\"error\\\":{\\\"type\\\":\\\"invalid_request_error\\\",\\\"message\\\":\\\"` + msg + `\\\"}}\"}"
echo "{\"type\":\"turn.failed\",\"error\":{\"message\":\"{\\\"type\\\":\\\"error\\\",\\\"status\\\":400,\\\"error\\\":{\\\"type\\\":\\\"invalid_request_error\\\",\\\"message\\\":\\\"` + msg + `\\\"}}\"}}"
exit 1
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, runLog
}

const (
	refusalNeedsUpdate = "The '%s' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."
	refusalAccount     = "The '%s' model is not supported when using Codex with a ChatGPT account."
)

func runs(t *testing.T, runLog string) []string {
	t.Helper()
	b, err := os.ReadFile(runLog)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Fields(string(b))
}

// A strong model the CLI is too old for falls back once to gpt-5.6-sol,
// and the process remembers it: the next call goes straight to the
// fallback (board #666).
func TestGenerate_RefusedModelFallsBackOnce(t *testing.T) {
	bin, runLog := refusingCodex(t, refusalNeedsUpdate, "gpt-5.6-sol")
	gen := NewCodexGenerator("gpt-5.6-luna", "gpt-6-astra", bin)

	for range 2 {
		out, usage, _, err := gen.Generate(context.Background(), "sys", "msg", "")
		if err != nil {
			t.Fatalf("Generate: %v", err)
		}
		if out != "ok:gpt-5.6-sol" || usage.Model != "gpt-5.6-sol" {
			t.Fatalf("Generate = %q (usage model %q), want the fallback's answer", out, usage.Model)
		}
	}
	if got := strings.Join(runs(t, runLog), ","); got != "gpt-6-astra,gpt-5.6-sol,gpt-5.6-sol" {
		t.Errorf("runs = %s, want one refused attempt, then the fallback only", got)
	}
}

// A light-tier refusal falls back to the light fallback.
func TestGenerate_RefusedLightModelUsesLightFallback(t *testing.T) {
	bin, _ := refusingCodex(t, refusalAccount, "gpt-5.6-luna")
	gen := NewCodexGenerator("gpt-6-luna", "gpt-6-astra", bin)

	out, _, _, err := gen.Generate(digest.WithSource(context.Background(), "digest.period"), "sys", "msg", "")
	if err != nil || out != "ok:gpt-5.6-luna" {
		t.Fatalf("Generate = %q, %v; want the light fallback's answer", out, err)
	}
}

// With nothing to fall back to, the error names the model and the cause
// instead of "codex CLI failed with exit code 1".
func TestGenerate_RefusedModelHonestError(t *testing.T) {
	tests := []struct {
		refusal, want string
		needsUpdate   bool
	}{
		{refusalNeedsUpdate, "Codex needs an update to use gpt-5.6-sol", true},
		{refusalAccount, "gpt-5.6-sol isn't available on your Codex account", false},
	}
	for _, tt := range tests {
		bin, runLog := refusingCodex(t, tt.refusal)
		gen := NewCodexGenerator("gpt-5.6-luna", "gpt-5.6-sol", bin)

		_, _, _, err := gen.Generate(context.Background(), "sys", "msg", "")
		var refused *ModelUnavailableError
		if !errors.As(err, &refused) || refused.NeedsUpdate != tt.needsUpdate {
			t.Fatalf("Generate error = %v, want a *ModelUnavailableError (needs update %v)", err, tt.needsUpdate)
		}
		if !strings.Contains(err.Error(), tt.want) {
			t.Errorf("error = %q, want it to contain %q", err, tt.want)
		}
		if n := len(runs(t, runLog)); n != 1 {
			t.Errorf("runs = %d, want 1 (the fallback is the model itself)", n)
		}
	}
}

// When the fallback is refused too, the configured model's refusal stays
// the cause the owner sees.
func TestGenerate_FallbackRefusedTooKeepsFirstCause(t *testing.T) {
	bin, _ := refusingCodex(t, refusalNeedsUpdate)
	gen := NewCodexGenerator("gpt-5.6-luna", "gpt-6-astra", bin)

	_, _, _, err := gen.Generate(context.Background(), "sys", "msg", "")
	if err == nil || !strings.HasPrefix(err.Error(), "Codex needs an update to use gpt-6-astra") ||
		!strings.Contains(err.Error(), "fallback gpt-5.6-sol failed too") {
		t.Fatalf("Generate error = %v, want the first refusal plus the fallback's failure", err)
	}
}

func TestQuerySync_RefusedModelFallsBack(t *testing.T) {
	bin, runLog := refusingCodex(t, refusalNeedsUpdate, "gpt-5.6-sol")
	c := NewClient("gpt-6-astra", "", bin)

	out, _, err := c.QuerySync(context.Background(), "", "msg", "")
	if err != nil || out != "ok:gpt-5.6-sol" {
		t.Fatalf("QuerySync = %q, %v; want the fallback's answer", out, err)
	}
	if got := strings.Join(runs(t, runLog), ","); got != "gpt-6-astra,gpt-5.6-sol" {
		t.Errorf("runs = %s", got)
	}
}

func TestQuery_RefusedModelFallsBack(t *testing.T) {
	bin, _ := refusingCodex(t, refusalNeedsUpdate, "gpt-5.6-sol")
	c := NewClient("gpt-6-astra", "", bin)

	textCh, errCh, _ := c.Query(context.Background(), "", "msg", "")
	var text strings.Builder
	for chunk := range textCh {
		text.WriteString(chunk.Text)
	}
	if err := <-errCh; err != nil {
		t.Fatalf("Query error: %v", err)
	}
	if text.String() != "ok:gpt-5.6-sol" {
		t.Errorf("Query text = %q, want the fallback's answer", text.String())
	}
}

func TestQuery_RefusedModelHonestError(t *testing.T) {
	bin, _ := refusingCodex(t, refusalAccount)
	c := NewClient("gpt-5.6-sol", "", bin)

	textCh, errCh, _ := c.Query(context.Background(), "", "msg", "")
	for range textCh {
	}
	err := <-errCh
	var refused *ModelUnavailableError
	if !errors.As(err, &refused) || refused.Model != "gpt-5.6-sol" {
		t.Fatalf("Query error = %v, want the account refusal for gpt-5.6-sol", err)
	}
}

// Any other failed turn surfaces the server's human message, not its JSON
// envelope.
func TestTurnError_UnwrapsServerMessage(t *testing.T) {
	err := turnError("m", `{"type":"error","status":429,"error":{"type":"rate_limit","message":"slow down"}}`)
	if err.Error() != "codex error: slow down" {
		t.Errorf("turnError = %q", err)
	}
	if err := turnError("m", "plain text"); err.Error() != "codex error: plain text" {
		t.Errorf("turnError(plain) = %q", err)
	}
}
