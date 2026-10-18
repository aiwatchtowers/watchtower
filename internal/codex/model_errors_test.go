package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/digest"
)

// turnFailureCase is one entry of testdata/turn_failures.json, the fixture
// shared with the Desktop's Test Connection (ConnectionTestTests): the same
// codex output must read the same on both sides. want "" = no failure.
type turnFailureCase struct {
	Name  string `json:"name"`
	Model string `json:"model"`
	JSONL string `json:"jsonl"`
	Want  string `json:"want"`
}

func turnFailureCases(t *testing.T) []turnFailureCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "turn_failures.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []turnFailureCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) < 7 {
		t.Fatalf("fixture has %d cases, want at least 7", len(cases))
	}
	return cases
}

// Every fixture case: the refusals by their exact phrasing (board #666),
// the envelope's type and status kept, turn.failed winning over a
// top-level error, and a top-level error alone.
func TestFailedTurn_SharedFixture(t *testing.T) {
	for _, tc := range turnFailureCases(t) {
		t.Run(tc.Name, func(t *testing.T) {
			err := failedTurn(tc.Model, []byte(tc.JSONL))
			got := ""
			if err != nil {
				got = err.Error()
			}
			if got != tc.Want {
				t.Errorf("failedTurn = %q, want %q", got, tc.Want)
			}
		})
	}
}

// Only the observed phrasings are refusals; a message that merely mentions
// a model and access stays an ordinary codex error.
func TestTurnError_RefusalNeedsExactPhrasing(t *testing.T) {
	for _, msg := range []string{
		"model access check failed, please retry",
		"a newer version of Codex is available",
		"this feature is not supported when using Codex with a ChatGPT account",
		"the file does not exist",
	} {
		var refused *ModelUnavailableError
		if err := turnError("m", msg); errors.As(err, &refused) {
			t.Errorf("turnError(%q) = %v, want a plain codex error", msg, err)
		}
	}
}

func fixtureCase(t *testing.T, name string) turnFailureCase {
	t.Helper()
	for _, tc := range turnFailureCases(t) {
		if strings.HasPrefix(tc.Name, name) {
			return tc
		}
	}
	t.Fatalf("no fixture case %q", name)
	return turnFailureCase{}
}

// fakeCodexRun writes a fake codex that prints jsonl, writes stderr and
// exits with exitCode (it answers --version like codex-cli 0.145).
func fakeCodexRun(t *testing.T, jsonl, stderr string, exitCode int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fake CLI test skipped on windows")
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "out.jsonl")
	if err := os.WriteFile(out, []byte(jsonl), 0o600); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "codex")
	script := "#!/bin/sh\n" +
		"case \"$1\" in --version) echo \"codex-cli 0.145.0\"; exit 0;; esac\n" +
		"cat >/dev/null\n" +
		"cat '" + out + "'\n"
	if stderr != "" {
		script += "printf '%s' '" + stderr + "' 1>&2\n"
	}
	script += "exit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// A refused default no longer reads "codex CLI failed with exit code 1":
// every codex path names the model and the way out, and the exit error
// stays a cause.
func TestRefusedModel_HonestErrorOnEveryPath(t *testing.T) {
	tc := fixtureCase(t, "CLI too old")
	bin := fakeCodexRun(t, tc.JSONL, "", 1)

	_, _, _, genErr := NewCodexGenerator("gpt-5.6-luna", "gpt-6-astra", bin).Generate(context.Background(), "sys", "msg", "")
	_, _, syncErr := NewClient("gpt-6-astra", "", bin).QuerySync(context.Background(), "", "msg", "")
	textCh, errCh, _ := NewClient("gpt-6-astra", "", bin).Query(context.Background(), "", "msg", "")
	for range textCh {
	}
	streamErr := <-errCh

	for name, err := range map[string]error{"Generate": genErr, "QuerySync": syncErr, "Query": streamErr} {
		var refused *ModelUnavailableError
		if !errors.As(err, &refused) || !refused.NeedsUpdate || refused.Model != "gpt-6-astra" {
			t.Errorf("%s error = %v, want the needs-update refusal for gpt-6-astra", name, err)
			continue
		}
		if err.Error() != tc.Want {
			t.Errorf("%s error = %q, want %q", name, err, tc.Want)
		}
	}
	var exitErr *exec.ExitError
	if !errors.As(genErr, &exitErr) || !errors.As(syncErr, &exitErr) {
		t.Errorf("the exit error must stay a cause: Generate %v, QuerySync %v", genErr, syncErr)
	}
}

// The stderr of a failed run stays in the text next to the turn's reason.
func TestRunError_KeepsStderr(t *testing.T) {
	bin := fakeCodexRun(t, fixtureCase(t, "rate limit").JSONL, "warning: config ignored", 1)

	_, _, _, err := NewCodexGenerator("gpt-5.6-sol", "gpt-5.6-sol", bin).Generate(context.Background(), "sys", "msg", "")
	if err == nil || !strings.HasSuffix(err.Error(), "(stderr: warning: config ignored)") {
		t.Fatalf("Generate error = %v, want the turn error plus the stderr", err)
	}
}

// A refusal never picks up stderr: transport words there ("connection
// reset") would make it an ErrAICall the backfill retries forever.
func TestRunError_RefusalIgnoresStderr(t *testing.T) {
	tc := fixtureCase(t, "model not offered")
	bin := fakeCodexRun(t, tc.JSONL, "error: connection reset by peer", 1)

	_, _, _, err := digest.WithCallTimeout(NewCodexGenerator("gpt-5.4", "gpt-5.4", bin), time.Minute).
		Generate(context.Background(), "sys", "msg", "")
	var refused *ModelUnavailableError
	if !errors.As(err, &refused) || err.Error() != tc.Want || errors.Is(err, digest.ErrAICall) {
		t.Fatalf("Generate error = %v, want exactly %q and no ErrAICall", err, tc.Want)
	}
}

// A rate limit inside the envelope still classifies as a transport failure
// (digest.ErrAICall), so the history backfill retries instead of striking
// the chunk; a model refusal does not.
func TestTurnError_RateLimitStaysTransportFailure(t *testing.T) {
	limited := fakeCodexRun(t, fixtureCase(t, "rate limit").JSONL, "", 1)
	refused := fakeCodexRun(t, fixtureCase(t, "CLI too old").JSONL, "", 1)

	_, _, _, err := digest.WithCallTimeout(NewCodexGenerator("gpt-5.6-sol", "gpt-5.6-sol", limited), time.Minute).
		Generate(context.Background(), "sys", "msg", "")
	if !errors.Is(err, digest.ErrAICall) || !strings.Contains(err.Error(), "rate_limit_error, status code 429") {
		t.Errorf("rate-limited Generate error = %v, want an ErrAICall naming the rate limit", err)
	}
	_, _, _, err = digest.WithCallTimeout(NewCodexGenerator("gpt-6-astra", "gpt-6-astra", refused), time.Minute).
		Generate(context.Background(), "sys", "msg", "")
	if err == nil || errors.Is(err, digest.ErrAICall) {
		t.Errorf("refused Generate error = %v, want a reply error, not ErrAICall", err)
	}
}
