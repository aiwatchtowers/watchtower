package ollama

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"watchtower/internal/digest"
)

// Generator implements digest.Generator using the Ollama OpenAI-compatible API.
type Generator struct {
	modelLight  string
	modelStrong string
	baseURL     string
	http        *http.Client
}

// NewGenerator creates a digest generator backed by an OpenAI-compatible
// server. modelLight/modelStrong are the per-tier models (see
// digest.TierForSource); baseURL is the server address, "" for the default.
func NewGenerator(modelLight, modelStrong, baseURL string) *Generator {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Generator{
		modelLight:  modelLight,
		modelStrong: modelStrong,
		baseURL:     strings.TrimRight(baseURL, "/"),
		http:        &http.Client{},
	}
}

// Generate calls the server and returns the response text, token usage, and
// an empty session ID (no session concept in the chat completions API).
func (g *Generator) Generate(ctx context.Context, systemPrompt, userMessage, _ string) (string, *digest.Usage, string, error) {
	model := g.modelStrong
	if s, ok := digest.SourceFromContext(ctx); ok && digest.TierForSource(s) == digest.TierLight {
		model = g.modelLight
	}

	body, err := json.Marshal(chatRequest{
		Model:    model,
		Messages: buildMessages(systemPrompt, userMessage),
		Stream:   false,
	})
	if err != nil {
		return "", nil, "", fmt.Errorf("marshaling request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.baseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", nil, "", fmt.Errorf("creating request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := g.http.Do(req)
	if err != nil {
		return "", nil, "", fmt.Errorf("ollama request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return "", nil, "", fmt.Errorf("ollama returned HTTP %d: %s", resp.StatusCode, string(b))
	}

	var result chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", nil, "", fmt.Errorf("decoding ollama response: %w", err)
	}

	if len(result.Choices) == 0 {
		return "", nil, "", fmt.Errorf("ollama returned no choices")
	}

	text := strings.TrimSpace(result.Choices[0].Message.Content)
	if text == "" {
		return "", nil, "", fmt.Errorf("ollama returned empty result")
	}

	var usage *digest.Usage
	if result.Usage != nil {
		usage = &digest.Usage{
			Model:          model,
			InputTokens:    result.Usage.PromptTokens,
			OutputTokens:   result.Usage.CompletionTokens,
			TotalAPITokens: result.Usage.TotalTokens,
		}
	}

	return text, usage, "", nil
}
