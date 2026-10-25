package digest

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"watchtower/internal/fsutil"
)

// ImageGenerator is a Generator backend that can also take one image with
// the prompt. The call runs with no tools and no session, like Generate; the
// reply is the model's text.
type ImageGenerator interface {
	GenerateWithImage(ctx context.Context, systemPrompt, userMessage, imagePath, mediaType string) (string, *Usage, error)
}

// errNotImageCapable is what a wrapper's GenerateWithImage returns when the
// generator it wraps takes no images; ImageCapable says so before a call.
var errNotImageCapable = errors.New("the AI provider does not take images")

// maxImageInput bounds the image file one call sends (the pass downscales
// anything larger before it gets here).
const maxImageInput = 5 << 20

// workDirKey is the context key for WithWorkDir.
type workDirKey struct{}

// WithWorkDir names the root under which GenerateWithImage creates the call's
// own empty 0700 working directory (removed when the call returns), so no
// project or local settings, hooks or MCP config are found where the child
// runs. The media pass passes <workspace>/tmp/media. An image call without it
// fails before starting anything.
func WithWorkDir(ctx context.Context, root string) context.Context {
	return context.WithValue(ctx, workDirKey{}, root)
}

// WorkDirFromContext returns the root WithWorkDir set, for an image
// generator outside this package.
func WorkDirFromContext(ctx context.Context) (string, bool) {
	root, ok := ctx.Value(workDirKey{}).(string)
	return root, ok && root != ""
}

// generatorWrapper is a decorator around another Generator.
type generatorWrapper interface {
	wrappedGenerator() Generator
}

// ImageCapable returns g's image call when g, through any of the daemon's
// wrappers (PooledGenerator, WithCallTimeout), ends in a generator that takes
// images.
func ImageCapable(g Generator) (ImageGenerator, bool) {
	if w, ok := g.(generatorWrapper); ok {
		if _, ok := ImageCapable(w.wrappedGenerator()); !ok {
			return nil, false
		}
	}
	ig, ok := g.(ImageGenerator)
	return ig, ok
}

// imageArgs builds the CLI args for an image call: stream-json in (the image
// travels as a content block on stdin) and out, no tools, and
// --strict-mcp-config with no --mcp-config so no MCP server loads at all.
// argv carries flags and paths only. See validateModelArgs for why
// --setting-sources project,local is required.
func imageArgs(model, systemPromptFile string) []string {
	args := []string{
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--model", model,
		"--no-session-persistence",
		"--tools", "",
		"--strict-mcp-config",
		"--setting-sources", "project,local",
	}
	if systemPromptFile != "" {
		args = append(args, "--system-prompt-file", systemPromptFile)
	}
	return args
}

// The stream-json user line, the shape internal/chat/attachments.go sends
// (copied: chat imports digest).
type imageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

type imageBlock struct {
	Type   string       `json:"type"`
	Source *imageSource `json:"source,omitempty"`
	Text   string       `json:"text,omitempty"`
}

type imageUserMessage struct {
	Role    string       `json:"role"`
	Content []imageBlock `json:"content"`
}

type imageUserEnvelope struct {
	Type    string           `json:"type"`
	Message imageUserMessage `json:"message"`
}

// imageUserLine renders the one stdin line: the image block first (the
// API's recommended order), then the text; an all-whitespace text is
// omitted (an empty text block is rejected).
func imageUserLine(data []byte, mediaType, text string) ([]byte, error) {
	content := []imageBlock{{Type: "image", Source: &imageSource{
		Type: "base64", MediaType: mediaType, Data: base64.StdEncoding.EncodeToString(data),
	}}}
	if strings.TrimSpace(text) != "" {
		content = append(content, imageBlock{Type: "text", Text: text})
	}
	line, err := json.Marshal(imageUserEnvelope{Type: "user", Message: imageUserMessage{Role: "user", Content: content}})
	if err != nil {
		return nil, fmt.Errorf("encoding the image message: %w", err)
	}
	return append(line, '\n'), nil
}

// parseStreamResult finds the last result event in stream-json output (one
// JSON event per line).
func parseStreamResult(output []byte) (*cliResponse, error) {
	lines := bytes.Split(output, []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		line := bytes.TrimSpace(lines[i])
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var ev cliResponse
		if err := json.Unmarshal(line, &ev); err == nil && ev.Type == "result" {
			return &ev, nil
		}
	}
	return nil, fmt.Errorf("no result event in claude CLI stream-json output (%d lines)", len(lines))
}

// readImage reads the image file, refusing one over maxImageInput.
func readImage(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("opening the image: %w", err)
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxImageInput+1))
	if err != nil {
		return nil, fmt.Errorf("reading the image: %w", err)
	}
	if len(data) > maxImageInput {
		return nil, fmt.Errorf("the image is over %d bytes", maxImageInput)
	}
	return data, nil
}

// GenerateWithImage sends one image and a text to the model, with no tools
// and no MCP servers, from a fresh empty 0700 directory under the
// WithWorkDir root that is removed when the call returns. The image is a
// base64 content block on stdin, the system prompt a 0600 file: neither
// reaches argv. The reply and usage come from the final result event.
func (g *ClaudeGenerator) GenerateWithImage(ctx context.Context, systemPrompt, userMessage, imagePath, mediaType string) (string, *Usage, error) {
	root, ok := WorkDirFromContext(ctx)
	if !ok {
		return "", nil, errors.New("image call without a work directory (digest.WithWorkDir)")
	}
	data, err := readImage(imagePath)
	if err != nil {
		return "", nil, err
	}
	line, err := imageUserLine(data, mediaType, userMessage)
	if err != nil {
		return "", nil, err
	}
	if err := fsutil.MakePrivateDir(root); err != nil {
		return "", nil, fmt.Errorf("creating the media work root: %w", err)
	}
	dir, err := os.MkdirTemp(root, "media-call-")
	if err != nil {
		return "", nil, fmt.Errorf("creating the call's work directory: %w", err)
	}
	defer func() { _ = os.RemoveAll(dir) }()

	systemPromptFile, cleanup, err := writeSystemPromptFile(systemPrompt)
	if err != nil {
		return "", nil, err
	}
	defer cleanup()

	model := g.modelForContext(ctx)
	resp, err := g.runClaude(ctx, imageArgs(model, systemPromptFile), bytes.NewReader(line), dir, parseStreamResult)
	if err != nil {
		return "", nil, err
	}
	return resp.Result, cliUsageOf(model, resp), nil
}
