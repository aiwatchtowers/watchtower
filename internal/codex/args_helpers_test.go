package codex

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// clientArgsT is Client.buildArgs for tests: the system-prompt file a call
// writes is removed when the test ends.
func clientArgsT(t *testing.T, c *Client, systemPrompt, userMessage, workDir string) ([]string, string) {
	t.Helper()
	args, stdin, promptFile, err := c.buildArgs(systemPrompt, userMessage, workDir)
	if err != nil {
		t.Fatalf("buildArgs: %v", err)
	}
	if promptFile != "" {
		t.Cleanup(func() { _ = os.Remove(promptFile) })
	}
	return args, stdin
}

// genArgsT is the generator's buildArgs for tests, with the same cleanup.
func genArgsT(t *testing.T, model, systemPrompt, userMessage string) ([]string, string) {
	t.Helper()
	args, stdin, promptFile, err := buildArgs("codex", model, systemPrompt, userMessage)
	if err != nil {
		t.Fatalf("buildArgs: %v", err)
	}
	if promptFile != "" {
		t.Cleanup(func() { _ = os.Remove(promptFile) })
	}
	return args, stdin
}

// instructionsFileOf returns the path args hand codex as
// model_instructions_file ("" when there is none).
func instructionsFileOf(t *testing.T, args []string) string {
	t.Helper()
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-c" && strings.HasPrefix(args[i+1], "model_instructions_file=") {
			path, err := strconv.Unquote(strings.TrimPrefix(args[i+1], "model_instructions_file="))
			if err != nil {
				t.Fatalf("model_instructions_file value %q: %v", args[i+1], err)
			}
			return path
		}
	}
	return ""
}

// readInstructions returns the system prompt args hand codex through its
// 0600 model_instructions_file, failing when there is none.
func readInstructions(t *testing.T, args []string) string {
	t.Helper()
	path := instructionsFileOf(t, args)
	if path == "" {
		t.Fatalf("args %v carry no model_instructions_file", args)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat instructions file: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("instructions file mode = %v, want 0600", info.Mode().Perm())
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read instructions file: %v", err)
	}
	return string(b)
}

// argvCarries reports whether any argv token contains s.
func argvCarries(args []string, s string) bool {
	return strings.Contains(strings.Join(args, "\x00"), s)
}
