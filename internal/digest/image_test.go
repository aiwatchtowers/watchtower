package digest

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// imageFakeClaude writes a fake claude that records its argv (one "[arg]"
// line each), its working directory, that directory's mode and listing at
// start, its stdin and its pid into rec, then prints stream-json events
// ending in a result. The call runs isolated (own process group), and the
// group is killed in t.Cleanup, so nothing it started outlives the test.
func imageFakeClaude(t *testing.T, rec string) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "fake-claude")
	body := `#!/bin/sh
echo $$ > "` + rec + `/pid"
for a in "$@"; do printf '[%s]\n' "$a"; done > "` + rec + `/argv"
pwd -P > "` + rec + `/pwd"
ls -ld . | cut -c1-10 > "` + rec + `/mode"
ls -A > "` + rec + `/listing"
cat > "` + rec + `/stdin"
echo '{"type":"system","subtype":"init","session_id":"s1"}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"ignored"}]}}'
echo '{"type":"result","subtype":"success","result":"described","is_error":false,"session_id":"s1","usage":{"input_tokens":11,"output_tokens":7,"cache_read_input_tokens":2}}'
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if b, err := os.ReadFile(filepath.Join(rec, "pid")); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
		}
	})
	return script
}

func readRec(t *testing.T, rec, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(rec, name))
	if err != nil {
		t.Fatalf("reading %s: %v", name, err)
	}
	return string(b)
}

// runImageCall runs one GenerateWithImage through the fake and returns the
// record dir, the media root and the image bytes.
func runImageCall(t *testing.T, system, user string) (rec, root string, img []byte, got string, usage *Usage) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	rec = t.TempDir()
	root = filepath.Join(t.TempDir(), "tmp", "media")
	img = []byte("\x89PNG\r\n\x1a\n-synthetic-image-bytes-for-the-test-")
	imgPath := filepath.Join(t.TempDir(), "media-img.png")
	if err := os.WriteFile(imgPath, img, 0o600); err != nil {
		t.Fatal(err)
	}
	gen := NewClaudeGenerator("light-model", "strong-model", imageFakeClaude(t, rec))
	gen.SetIsolatedChild()
	ctx := WithWorkDir(WithSource(context.Background(), "media.describe"), root)
	got, usage, err := gen.GenerateWithImage(ctx, system, user, imgPath, "image/png")
	if err != nil {
		t.Fatalf("GenerateWithImage: %v", err)
	}
	return rec, root, img, got, usage
}

func TestClaudeImageArgs(t *testing.T) {
	const system = "SYSTEM-PROMPT-MARKER"
	const user = "USER-TEXT-MARKER"
	rec, root, img, got, usage := runImageCall(t, system, user)

	if got != "described" {
		t.Errorf("result = %q, want the final result event's text", got)
	}
	if usage == nil || usage.Model != "strong-model" || usage.InputTokens != 11 || usage.OutputTokens != 7 || usage.TotalAPITokens != 13 {
		t.Errorf("usage = %+v, want strong-model 11/7 (13 API tokens)", usage)
	}

	var args []string
	for _, l := range strings.Split(strings.TrimRight(readRec(t, rec, "argv"), "\n"), "\n") {
		args = append(args, strings.TrimSuffix(strings.TrimPrefix(l, "["), "]"))
	}
	pair := func(flag, val string) bool {
		i := slices.Index(args, flag)
		return i >= 0 && i+1 < len(args) && args[i+1] == val
	}
	for flag, val := range map[string]string{
		"--tools": "", "--input-format": "stream-json", "--output-format": "stream-json",
		"--setting-sources": "project,local", "--model": "strong-model",
	} {
		if !pair(flag, val) {
			t.Errorf("argv lacks %s %q: %q", flag, val, args)
		}
	}
	for _, want := range []string{"-p", "--strict-mcp-config", "--verbose", "--no-session-persistence", "--system-prompt-file"} {
		if !slices.Contains(args, want) {
			t.Errorf("argv lacks %s: %q", want, args)
		}
	}
	joined := strings.Join(args, "\x00")
	b64 := base64.StdEncoding.EncodeToString(img)
	for _, banned := range []string{"--mcp-config", system, user, b64, "-synthetic-image-bytes-"} {
		if strings.Contains(joined, banned) {
			t.Errorf("argv carries %q: %q", banned, args)
		}
	}

	pwd := strings.TrimSpace(readRec(t, rec, "pwd"))
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(pwd) != realRoot {
		t.Errorf("cmd.Dir = %q, want a fresh directory directly under %q", pwd, realRoot)
	}
	if mode := strings.TrimSpace(readRec(t, rec, "mode")); mode != "drwx------" {
		t.Errorf("cmd.Dir mode = %q, want drwx------", mode)
	}
	if listing := strings.TrimSpace(readRec(t, rec, "listing")); listing != "" {
		t.Errorf("cmd.Dir was not empty at start: %q", listing)
	}
	if _, err := os.Stat(pwd); !os.IsNotExist(err) {
		t.Errorf("cmd.Dir %q still exists after the call (err=%v)", pwd, err)
	}
}

func TestClaudeGenerateWithImage_StdinLine(t *testing.T) {
	rec, _, img, _, _ := runImageCall(t, "sys", "Describe the image.")
	stdin := readRec(t, rec, "stdin")
	if strings.Count(stdin, "\n") != 1 || !strings.HasSuffix(stdin, "\n") {
		t.Fatalf("stdin is not one JSON line: %q", stdin)
	}
	var env struct {
		Type    string `json:"type"`
		Message struct {
			Role    string `json:"role"`
			Content []struct {
				Type   string `json:"type"`
				Text   string `json:"text"`
				Source struct {
					Type      string `json:"type"`
					MediaType string `json:"media_type"`
					Data      string `json:"data"`
				} `json:"source"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(stdin), &env); err != nil {
		t.Fatalf("stdin line: %v", err)
	}
	if env.Type != "user" || env.Message.Role != "user" || len(env.Message.Content) != 2 {
		t.Fatalf("envelope = %+v, want a user message with two blocks", env)
	}
	im, tx := env.Message.Content[0], env.Message.Content[1]
	if im.Type != "image" || im.Source.Type != "base64" || im.Source.MediaType != "image/png" ||
		im.Source.Data != base64.StdEncoding.EncodeToString(img) {
		t.Errorf("first block = %+v, want the file's base64 image block", im)
	}
	if tx.Type != "text" || tx.Text != "Describe the image." {
		t.Errorf("second block = %+v, want the text block", tx)
	}
}

// Without a work root on the call there is no safe empty directory to run
// claude from: the call fails before starting anything.
func TestClaudeGenerateWithImage_RequiresWorkDir(t *testing.T) {
	gen := NewClaudeGenerator("l", "s", "/nonexistent/claude")
	if _, _, err := gen.GenerateWithImage(context.Background(), "sys", "u", "/nonexistent.png", "image/png"); err == nil {
		t.Fatal("GenerateWithImage without WithWorkDir succeeded, want an error")
	}
}

func TestParseStreamResult(t *testing.T) {
	out := []byte("{\"type\":\"system\"}\n\nnot json\n{\"type\":\"result\",\"result\":\"first\"}\n{\"type\":\"result\",\"result\":\"last\"}\n")
	resp, err := parseStreamResult(out)
	if err != nil || resp.Result != "last" {
		t.Fatalf("parseStreamResult = %+v, %v; want the last result event", resp, err)
	}
	if _, err := parseStreamResult([]byte("{\"type\":\"system\"}\n")); err == nil {
		t.Fatal("a stream without a result event parsed")
	}
}

func TestCheckImageFile(t *testing.T) {
	dir := t.TempDir()
	ok := filepath.Join(dir, "a.png")
	if err := os.WriteFile(ok, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := CheckImageFile(ok); err != nil {
		t.Errorf("regular file: %v", err)
	}
	if CheckImageFile(filepath.Join(dir, "none.png")) == nil {
		t.Error("missing file accepted")
	}
	big := filepath.Join(dir, "big.png")
	f, err := os.Create(big)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(maxImageInput + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if CheckImageFile(big) == nil {
		t.Error("oversized file accepted")
	}
	if CheckImageFile(dir) == nil {
		t.Error("directory accepted")
	}
}
