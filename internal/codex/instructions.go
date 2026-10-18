package codex

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"watchtower/internal/fsutil"
)

// minInstructionsFileVersion is the first codex-cli version Watchtower hands
// a system prompt through `-c model_instructions_file` (the version it was
// verified on; older releases may lack or name the key differently).
var minInstructionsFileVersion = [3]int{0, 145, 0}

// Stdin section headers of the fallback layout (codexStdinContent), so
// codex can still tell the system instructions apart from the owner's turn.
const (
	codexStdinSystemHeader = "SYSTEM INSTRUCTIONS:\n"
	codexStdinUserHeader   = "USER MESSAGE:\n"
)

// promptArgs lays out a codex exec call's prompts for the codex binary bin,
// never on argv — the owner's data there would be readable by every local
// process through `ps`, and a large prompt would hit ARG_MAX. The user
// message always goes on stdin. A non-empty system prompt goes to a 0600
// file named by `-c model_instructions_file="<path>"` (only the path on
// argv; it replaces codex's built-in base instructions) when bin is new
// enough (instructionsFileSupported); on an older or unknown codex it rides
// ahead of the user message on stdin (codexStdinContent). path is the file
// the caller removes once the child has exited ("" when none).
func promptArgs(bin, systemPrompt, userMessage string) (args []string, stdin, path string, err error) {
	if systemPrompt == "" {
		return nil, userMessage, "", nil
	}
	if !instructionsFileSupported(bin) {
		return nil, codexStdinContent(systemPrompt, userMessage), "", nil
	}
	path, err = fsutil.WritePrivateTemp(fsutil.SystemPromptTempPrefix+"*.txt", systemPrompt)
	if err != nil {
		return nil, "", "", fmt.Errorf("writing system prompt file: %w", err)
	}
	quoted, err := tomlBasicString(path)
	if err != nil {
		_ = os.Remove(path)
		return nil, "", "", fmt.Errorf("system prompt file path: %w", err)
	}
	return []string{"-c", "model_instructions_file=" + quoted}, userMessage, path, nil
}

// codexStdinContent renders the whole turn (system prompt + user message,
// which for the chat session already carries the replayed history — see
// chat.ReplayFromDB) as one delimited stdin payload: the layout for a codex
// without model_instructions_file.
func codexStdinContent(systemPrompt, userMessage string) string {
	var b strings.Builder
	if systemPrompt != "" {
		b.WriteString(codexStdinSystemHeader)
		b.WriteString(systemPrompt)
		b.WriteString("\n\n")
	}
	b.WriteString(codexStdinUserHeader)
	b.WriteString(userMessage)
	return b.String()
}

// tomlBasicString quotes s as a TOML basic string ("…" with \ and "
// escaped), the form a `-c key=value` override parses. A control character
// or invalid UTF-8 has no place in a temp file path and is refused rather
// than escaped.
func tomlBasicString(s string) (string, error) {
	if !utf8.ValidString(s) {
		return "", errors.New("not valid UTF-8")
	}
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r < 0x20 || r == 0x7f:
			return "", fmt.Errorf("control character %U", r)
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String(), nil
}

// probeCodexVersion runs `bin --version`; tests replace it.
var probeCodexVersion = codexVersion

// instructionsSupport caches instructionsFileSupported per binary path, so
// the version probe runs once per process.
var instructionsSupport sync.Map // string → bool

// instructionsFileSupported reports whether the codex at bin takes
// `-c model_instructions_file` (version ≥ minInstructionsFileVersion). An
// unknown version counts as too old; the fallback is logged once per binary.
func instructionsFileSupported(bin string) bool {
	if v, ok := instructionsSupport.Load(bin); ok {
		return v.(bool)
	}
	v, err := probeCodexVersion(bin)
	ok := err == nil && !versionLess(v, minInstructionsFileVersion)
	if actual, loaded := instructionsSupport.LoadOrStore(bin, ok); loaded {
		return actual.(bool)
	}
	if !ok {
		reason := fmt.Sprintf("version %d.%d.%d", v[0], v[1], v[2])
		if err != nil {
			reason = err.Error()
		}
		log.Printf("codex: %s (%s) predates model_instructions_file %d.%d.%d; the system prompt rides on stdin instead",
			bin, reason, minInstructionsFileVersion[0], minInstructionsFileVersion[1], minInstructionsFileVersion[2])
	}
	return ok
}

// codexVersion runs `bin --version` (e.g. "codex-cli 0.145.0") and parses
// its last field as major.minor.patch.
func codexVersion(bin string) ([3]int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--version")
	cmd.Dir = os.TempDir()
	var env []string
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "PATH=") {
			env = append(env, e)
		}
	}
	cmd.Env = append(env, "PATH="+RichPATH())
	out, err := cmd.Output()
	if err != nil {
		return [3]int{}, fmt.Errorf("codex --version: %w", err)
	}
	return parseCodexVersion(string(out))
}

// parseCodexVersion reads "codex-cli 0.145.0" (or a bare "0.145.0", with an
// optional "v" and pre-release suffix) as [major, minor, patch].
func parseCodexVersion(out string) ([3]int, error) {
	fields := strings.Fields(out)
	if len(fields) == 0 {
		return [3]int{}, errors.New("codex --version printed nothing")
	}
	s := strings.TrimPrefix(fields[len(fields)-1], "v")
	parts := strings.SplitN(s, ".", 3)
	if len(parts) != 3 {
		return [3]int{}, fmt.Errorf("unrecognised codex version %q", s)
	}
	var v [3]int
	for i, p := range parts {
		end := 0
		for end < len(p) && p[end] >= '0' && p[end] <= '9' {
			end++
		}
		n, err := strconv.Atoi(p[:end])
		if err != nil {
			return [3]int{}, fmt.Errorf("unrecognised codex version %q", s)
		}
		v[i] = n
	}
	return v, nil
}

// versionLess reports a < b.
func versionLess(a, b [3]int) bool {
	return slices.Compare(a[:], b[:]) < 0
}
