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

	"watchtower/internal/ai"
)

const (
	// ModelDefault is the default model when none is configured.
	ModelDefault = "gemma4:31b"

	// DefaultBaseURL is the default Ollama API endpoint.
	DefaultBaseURL = "http://localhost:11434"
)

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

// chatResponse is the non-streaming response from the chat completions API.
type chatResponse struct {
	Choices []chatChoice `json:"choices"`
	Usage   *chatUsage   `json:"usage,omitempty"`
}

type chatChoice struct {
	Message chatMessage `json:"message"`
	Delta   chatMessage `json:"delta"`
}

type chatUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
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
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan string, <-chan error, <-chan string) {
	textCh := make(chan string, 64)
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

		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}
			// SSE format: "data: {...}" or "data: [DONE]"
			data, ok := strings.CutPrefix(line, "data: ")
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
			if len(chunk.Choices) > 0 {
				text := chunk.Choices[0].Delta.Content
				if text == "" {
					continue
				}
				select {
				case textCh <- text:
				case <-ctx.Done():
					errCh <- ctx.Err()
					return
				}
			}
		}

		if err := scanner.Err(); err != nil {
			errCh <- fmt.Errorf("reading ollama stream: %w", err)
		}
	}()

	return textCh, errCh, sidCh
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
