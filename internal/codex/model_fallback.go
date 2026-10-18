package codex

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"

	"watchtower/internal/providers"
)

// ModelUnavailableError is codex refusing the model before the turn ran:
// the installed CLI is too old for it (NeedsUpdate), or the signed-in
// account does not offer it. Its text names the cause and the way out, so
// the surfaces show it as is (board #666).
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

// refusedModels remembers, for the life of the process, the models codex
// refused and the fallback that replaced each, so a long-running daemon
// pays the refused attempt once, not on every call.
var refusedModels sync.Map // model → fallback model

// modelFor is the model to run instead of model: its remembered fallback,
// or model itself.
func modelFor(model string) string {
	if fb, ok := refusedModels.Load(model); ok {
		return fb.(string)
	}
	return model
}

// fallbackFor returns the model to retry once with when err is codex
// refusing model, remembering the swap and logging it; "" = no retry.
func fallbackFor(model string, light bool, err error) string {
	var refused *ModelUnavailableError
	if !errors.As(err, &refused) {
		return ""
	}
	fb := providers.FallbackModel("codex", model, light)
	if fb == "" {
		return ""
	}
	refusedModels.Store(model, fb)
	log.Printf("codex: %v; falling back to %s", err, fb)
	return fb
}

// withFallbackErr keeps the first refusal as the cause when the retry with
// fb failed too: the configured model is what the owner has to act on.
func withFallbackErr(first error, fb string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%w (fallback %s failed too: %v)", first, fb, err)
}

// turnError is the error for a failed codex turn with message msg: the
// server's JSON body is unwrapped to its human message, and a model refusal
// becomes a *ModelUnavailableError.
func turnError(model, msg string) error {
	var body struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(msg), &body) == nil && body.Error.Message != "" {
		msg = body.Error.Message
	}
	lower := strings.ToLower(msg)
	switch {
	case strings.Contains(lower, "requires a newer version of codex"):
		return &ModelUnavailableError{Model: model, NeedsUpdate: true}
	case strings.Contains(lower, "model is not supported"),
		strings.Contains(lower, "does not exist or you do not have access"):
		return &ModelUnavailableError{Model: model}
	}
	return fmt.Errorf("codex error: %s", msg)
}

// failedTurn finds why a codex run failed in its JSONL output: the
// turn.failed (or error) event's message, as turnError builds it. nil when
// the output carries none.
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
