// Package ollama implements ai.Provider and digest.Generator using the Ollama
// OpenAI-compatible API (http://localhost:11434/v1/chat/completions).
package ollama

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"watchtower/internal/ai"
)

// DefaultBaseURL is the default Ollama API endpoint. Kept in sync with
// config.DefaultOllamaURL (config cannot be imported here without widening
// this package's dependency surface).
const DefaultBaseURL = "http://localhost:11434"

// Client implements ai.Provider by calling the Ollama OpenAI-compatible API.
type Client struct {
	model   string
	baseURL string
	http    *http.Client
}

// NewClient creates a new Ollama AI client.
// baseURL is the Ollama server address (e.g. "http://localhost:11434"); pass "" for default.
func NewClient(model, baseURL string) *Client {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Client{
		model:   model,
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    &http.Client{},
	}
}

// chatRequest is the OpenAI-compatible chat completion request body.
type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// chatResponse is the non-streaming response from the chat completions API,
// and also the shape of one SSE data line in the streaming path. A failure
// after the initial 200 (model OOM, context overflow while generating) is
// reported this way rather than as an HTTP status — an OpenAI-compatible
// server (Ollama/vLLM/LM Studio) sends it as an "error" object with zero
// choices instead of tearing down the connection. Object/Message additionally
// catch vLLM's legacy top-level error shape, {"object":"error","message":
// "..."} — no nested "error" key at all — alongside the standard one; see
// asError.
type chatResponse struct {
	Choices []chatChoice `json:"choices"`
	Usage   *chatUsage   `json:"usage,omitempty"`
	Error   *chatError   `json:"error,omitempty"`
	Object  string       `json:"object,omitempty"`
	Message string       `json:"message,omitempty"`
}

// asError normalizes both inline-error shapes an OpenAI-compatible server
// can send into one chatError: the standard {"error":{"message":...}}
// object, and vLLM's legacy top-level {"object":"error","message":"..."}
// shape. Returns nil when neither is present.
func (r *chatResponse) asError() *chatError {
	if r.Error != nil {
		return r.Error
	}
	if r.Object == "error" && strings.TrimSpace(r.Message) != "" {
		return &chatError{Message: r.Message}
	}
	return nil
}

type chatChoice struct {
	Message      chatMessage `json:"message"`
	Delta        chatMessage `json:"delta"`
	FinishReason string      `json:"finish_reason"`
}

type chatUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// chatError is the OpenAI-compatible inline error object. Deliberately no
// "code" field: vLLM and llama.cpp send it as a JSON number ("code":400),
// and formatChatError never reads it anyway — a string-typed field here
// would fail json.Unmarshal on the WHOLE chunk on those servers, which is
// exactly the silent-failure shape this type exists to catch (an unmarshal
// error on the SSE data line makes streamSSE `continue` right past the
// error line, same as having no Error field at all).
type chatError struct {
	Message string `json:"message"`
	Type    string `json:"type,omitempty"`
}

// maxStreamErrorMessage caps a reported error's message the same way the
// non-streaming HTTP-status path already caps its raw error body (1024
// bytes, see QuerySync/Query below) — the server can otherwise attach
// unbounded detail (e.g. a stack trace) to the message.
const maxStreamErrorMessage = 1024

// formatChatError renders a chatError into a bounded, rune-safe message —
// never echoed past the cap, since it may carry arbitrary server-side detail.
func formatChatError(e *chatError) string {
	msg := strings.TrimSpace(e.Message)
	if msg == "" {
		msg = "ollama reported an error with no message"
	}
	if e.Type != "" {
		msg = fmt.Sprintf("%s (%s)", msg, e.Type)
	}
	if len(msg) <= maxStreamErrorMessage {
		return msg
	}
	cut := maxStreamErrorMessage
	for cut > 0 && !utf8.RuneStart(msg[cut]) {
		cut--
	}
	return msg[:cut] + fmt.Sprintf("… (%d bytes truncated)", len(msg)-cut)
}

// buildMessages creates the message array from system prompt and user message.
func buildMessages(systemPrompt, userMessage string) []chatMessage {
	var msgs []chatMessage
	if systemPrompt != "" {
		msgs = append(msgs, chatMessage{Role: "system", Content: systemPrompt})
	}
	msgs = append(msgs, chatMessage{Role: "user", Content: userMessage})
	return msgs
}

// Query sends a streaming request and returns channels for text chunks, errors,
// and session ID (always empty for Ollama — no session support).
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan ai.StreamChunk, 64)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)

	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)

		body, err := json.Marshal(chatRequest{
			Model:    c.model,
			Messages: buildMessages(systemPrompt, userMessage),
			Stream:   true,
		})
		if err != nil {
			errCh <- fmt.Errorf("marshaling request: %w", err)
			return
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/chat/completions", bytes.NewReader(body))
		if err != nil {
			errCh <- fmt.Errorf("creating request: %w", err)
			return
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := c.http.Do(req)
		if err != nil {
			errCh <- fmt.Errorf("ollama request failed: %w", err)
			return
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
			errCh <- fmt.Errorf("ollama returned HTTP %d: %s", resp.StatusCode, string(b))
			return
		}

		streamSSE(ctx, resp.Body, textCh, errCh)
	}()

	return textCh, errCh, sidCh
}

// streamSSE reads an SSE chat-completions stream and forwards each delta's
// text to textCh until "[DONE]", the stream ends, or ctx is cancelled. Ollama's
// chat surface has no tools, so it never emits a tool-boundary chunk.
//
// A failure reported mid-stream — an inline "error" object, or the
// connection closing before either "[DONE]" or a chunk carrying
// finish_reason — is surfaced as an error rather than silently treated as a
// clean, if short, end of stream: both would otherwise unmarshal to zero
// choices and fall through to a normal return, leaving the caller with an
// empty or truncated answer indistinguishable from a real (if terse) reply.
func streamSSE(ctx context.Context, body io.Reader, textCh chan<- ai.StreamChunk, errCh chan<- error) {
	scanner := bufio.NewScanner(body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	sawTerminal := false

	for scanner.Scan() {
		// SSE format: "data: {...}" or "data: [DONE]"
		data, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok {
			continue
		}
		if data == "[DONE]" {
			return
		}

		var chunk chatResponse
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if errObj := chunk.asError(); errObj != nil {
			errCh <- fmt.Errorf("ollama stream error: %s", formatChatError(errObj))
			return
		}
		if len(chunk.Choices) == 0 {
			continue
		}
		if chunk.Choices[0].FinishReason != "" {
			sawTerminal = true
		}
		if chunk.Choices[0].Delta.Content == "" {
			continue
		}
		select {
		case textCh <- ai.StreamChunk{Text: chunk.Choices[0].Delta.Content}:
		case <-ctx.Done():
			errCh <- ctx.Err()
			return
		}
	}

	if err := scanner.Err(); err != nil {
		errCh <- fmt.Errorf("reading ollama stream: %w", err)
		return
	}

	// The scanner ended (EOF) with no [DONE] and no chunk ever carrying a
	// finish_reason: the connection closed early (server crash/restart) —
	// scanner.Err() is nil for a clean EOF, so this is the only signal left
	// that the stream was cut short rather than completed.
	if !sawTerminal {
		errCh <- fmt.Errorf("ollama stream ended without [DONE] or a finish_reason (connection closed early)")
	}
}

// QuerySync sends a non-streaming request and returns the full response.
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, _ string) (string, *ai.Usage, error) {
	body, err := json.Marshal(chatRequest{
		Model:    c.model,
		Messages: buildMessages(systemPrompt, userMessage),
		Stream:   false,
	})
	if err != nil {
		return "", nil, fmt.Errorf("marshaling request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", nil, fmt.Errorf("creating request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", nil, fmt.Errorf("ollama request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return "", nil, fmt.Errorf("ollama returned HTTP %d: %s", resp.StatusCode, string(b))
	}

	var result chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", nil, fmt.Errorf("decoding ollama response: %w", err)
	}

	// A 200 response can still carry an inline error object with zero
	// choices (the same shape streamSSE now checks, either error envelope) —
	// report it directly instead of the generic "no choices" below, which
	// would otherwise hide the real reason.
	if errObj := result.asError(); errObj != nil {
		return "", nil, fmt.Errorf("ollama returned an error: %s", formatChatError(errObj))
	}

	if len(result.Choices) == 0 {
		return "", nil, fmt.Errorf("ollama returned no choices")
	}

	text := strings.TrimRight(result.Choices[0].Message.Content, "\n")

	var usage *ai.Usage
	if result.Usage != nil {
		usage = &ai.Usage{
			InputTokens:    result.Usage.PromptTokens,
			OutputTokens:   result.Usage.CompletionTokens,
			TotalAPITokens: result.Usage.TotalTokens,
		}
	}

	return text, usage, nil
}
