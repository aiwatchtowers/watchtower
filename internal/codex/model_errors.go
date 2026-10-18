package codex

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"watchtower/internal/digest"
)

// ModelUnavailableError is codex refusing the model before the turn ran:
// the installed CLI is too old for it (NeedsUpdate), or the signed-in
// account does not offer it. Its text names the model and the way out, and
// the surfaces show it as is. Settings → Test Connection words it the same
// (ConnectionTest.codexTurnError; shared fixture testdata/turn_failures.json).
type ModelUnavailableError struct {
	Model       string
	NeedsUpdate bool
}

func (e *ModelUnavailableError) Error() string {
	if e.NeedsUpdate {
		return fmt.Sprintf("Codex needs an update to use %s: run `codex update`, or pick another model in Settings → System → AI", e.Model)
	}
	return fmt.Sprintf("%s isn't available on your Codex account: pick another model in Settings → System → AI", e.Model)
}

// The server's refusal phrasings (codex-cli 0.145, ChatGPT sign-in, and the
// OpenAI API's unknown-model reply), lowercased.
const (
	refusalNeedsUpdate = "model requires a newer version of codex"
	refusalChatGPT     = "model is not supported when using codex with a chatgpt account"
	refusalNoAccess    = "does not exist or you do not have access to it"
)

// turnError is the error for a failed codex turn with message msg. A JSON
// envelope ({"type":"error","status":429,"error":{"type":…,"message":…}})
// is unwrapped to its message, keeping its type and status in the text
// ("codex error (rate_limit_error, status code 429): …") so digest's
// aiUnavailable still sees rate limits and outages; a model refusal becomes
// a *ModelUnavailableError.
func turnError(model, msg string) error {
	var body struct {
		Status int `json:"status"`
		Error  struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(msg), &body) != nil || body.Error.Message == "" {
		return classifyTurn(model, msg, "")
	}
	var tags []string
	if body.Error.Type != "" {
		tags = append(tags, body.Error.Type)
	}
	if body.Status != 0 {
		tags = append(tags, fmt.Sprintf("status code %d", body.Status))
	}
	return classifyTurn(model, body.Error.Message, strings.Join(tags, ", "))
}

// classifyTurn is turnError for an unwrapped message and its envelope tags.
func classifyTurn(model, msg, tags string) error {
	lower := strings.ToLower(msg)
	switch {
	case strings.Contains(lower, refusalNeedsUpdate):
		return &ModelUnavailableError{Model: model, NeedsUpdate: true}
	case strings.Contains(lower, refusalChatGPT), strings.Contains(lower, refusalNoAccess):
		return &ModelUnavailableError{Model: model}
	case tags != "":
		return fmt.Errorf("codex error (%s): %s", tags, msg)
	}
	return fmt.Errorf("codex error: %s", msg)
}

// failedTurn finds why a codex run failed in its JSONL output: the
// turn.failed event's message, or — only when there is none — the last
// top-level "error" event's (codex exec emits that one first and then
// turn.failed with the same text; on its own it may be a retry notice, so
// it counts only once the run has failed). nil when the output has neither.
func failedTurn(model string, output []byte) error {
	var last string
	for line := range bytes.SplitSeq(output, []byte("\n")) {
		var event CodexEvent
		if json.Unmarshal(bytes.TrimSpace(line), &event) != nil {
			continue
		}
		switch {
		case event.Error != nil:
			return turnError(model, event.Error.Message)
		case event.Type == "error" && event.Message != "":
			last = event.Message
		}
	}
	if last != "" {
		return turnError(model, last)
	}
	return nil
}

// runError is the error for a codex run that exited with err: the failed
// turn's reason from its JSONL output when there is one (codex exec reports
// it there, not on stderr), else classifyError. The exit error stays a
// cause (digest.WithCause) so a kill by a signal still classifies as a
// transport failure, and a non-empty stderr stays in the text.
func runError(model string, output []byte, err error, stderr, codexBin string) error {
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return classifyError(err, stderr, codexBin)
	}
	turnErr := failedTurn(model, output)
	if turnErr == nil {
		return classifyError(err, stderr, codexBin)
	}
	if s := strings.TrimSpace(stderr); s != "" {
		turnErr = fmt.Errorf("%w (stderr: %s)", turnErr, s)
	}
	return digest.WithCause(turnErr, exitErr)
}
