package terminal

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/agentkind"
)

const codexTestID = "01a10000-0000-7000-8000-000000000101"

// codexOwnerText opens a rollout with the given content through the stored
// path and reads its owner text.
func codexOwnerText(t *testing.T, content []byte) (string, error) {
	t.Helper()
	path := writeRollout(t, t.TempDir(), "2026/10/12", content)
	tr, err := OpenTranscript(agentkind.Codex, codexTestID, path, "")
	if err != nil {
		t.Fatalf("OpenTranscript: %v", err)
	}
	return tr.OwnerText(2000)
}

func writeRollout(t *testing.T, home, dateDir string, content []byte) string {
	t.Helper()
	dir := filepath.Join(home, "sessions", filepath.FromSlash(dateDir))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "rollout-2026-10-12T12-57-00-"+codexTestID+".jsonl")
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "codex", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func assertOwnerText(t *testing.T, content []byte, want string) {
	t.Helper()
	got, err := codexOwnerText(t, content)
	if err != nil {
		t.Fatalf("OwnerText: %v", err)
	}
	if got != want {
		t.Errorf("OwnerText = %q, want %q", got, want)
	}
}

func assertUnsupported(t *testing.T, content []byte) {
	t.Helper()
	got, err := codexOwnerText(t, content)
	if !errors.Is(err, ErrUnsupportedTranscript) {
		t.Fatalf("err = %v, want ErrUnsupportedTranscript", err)
	}
	if got != "" {
		t.Errorf("OwnerText = %q on an unsupported rollout", got)
	}
}

// Injected-context response_item lines and the compacted line (its history
// repeats "example 1") are not owner lines.
func TestCodexRollout_PaginatedOwnerLines(t *testing.T) {
	assertOwnerText(t, fixture(t, "paginated.jsonl"), "example 1\nexample 2\nexample 2b\nexample 3")
}

// The last user_message has no text, only an image.
func TestCodexRollout_LegacyOwnerLines(t *testing.T) {
	assertOwnerText(t, fixture(t, "legacy.jsonl"), "example 1\nexample 2\nexample 2b")
}

// A legacy session resumed by a newer Codex appends paginated lines to the
// same file; each owner message reads once, in file order.
func TestCodexRollout_MixedDialectsInOneFile(t *testing.T) {
	legacy := fixture(t, "legacy.jsonl")
	paginated := bytes.ReplaceAll(fixture(t, "paginated.jsonl"), []byte("example "), []byte("later "))
	mixed := append(append(append([]byte{}, legacy...), '\n'), paginated...)
	assertOwnerText(t, mixed, "example 1\nexample 2\nexample 2b\nlater 1\nlater 2\nlater 2b\nlater 3")
}

func TestCodexRollout_EmptyFileNoLines(t *testing.T) {
	assertOwnerText(t, nil, "")
	assertOwnerText(t, []byte("\n\n"), "")
}

func TestCodexRollout_MetaOnlyNoLines(t *testing.T) {
	assertOwnerText(t, fixture(t, "meta_only.jsonl"), "")
}

func TestCodexRollout_TruncatedLastLineIgnored(t *testing.T) {
	assertOwnerText(t, fixture(t, "truncated_tail.jsonl"), "example 1\nexample 2")
}

func TestCodexRollout_ZstdIsUnsupported(t *testing.T) {
	assertUnsupported(t, fixture(t, "zstd_header.jsonl"))
}

func TestCodexRollout_UnknownFormatIsUnsupported(t *testing.T) {
	for name, content := range map[string]string{
		"plain text":   "example 1\nexample 2\n",
		"binary":       "\x00\x01\x02\x03",
		"one cut line": `{"type":"event_msg","payload":{"type":"user_message","message":"exa`,
	} {
		t.Run(name, func(t *testing.T) { assertUnsupported(t, []byte(content)) })
	}
}

func TestCodexRollout_ImagesOnlyMessageSkipped(t *testing.T) {
	assertOwnerText(t, fixture(t, "images_only.jsonl"), "example 2")
}

func TestCodexRollout_CapsRunes(t *testing.T) {
	path := writeRollout(t, t.TempDir(), "2026/10/12", fixture(t, "paginated.jsonl"))
	tr, err := OpenTranscript(agentkind.Codex, codexTestID, path, "")
	if err != nil {
		t.Fatal(err)
	}
	got, err := tr.OwnerText(12)
	if err != nil || got != "example 1\nex" {
		t.Errorf("OwnerText(12) = %q, %v", got, err)
	}
}

func TestCodexRollout_LocateByStoredPathThenGlob(t *testing.T) {
	home := t.TempDir()
	globbed := writeRollout(t, home, "2026/10/11", fixture(t, "legacy.jsonl"))
	stored := writeRollout(t, t.TempDir(), "2026/10/12", fixture(t, "images_only.jsonl"))

	read := func(storedPath string) string {
		t.Helper()
		tr, err := OpenTranscript(agentkind.Codex, codexTestID, storedPath, home)
		if err != nil {
			t.Fatalf("OpenTranscript(%q): %v", storedPath, err)
		}
		got, err := tr.OwnerText(2000)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	if got := read(stored); got != "example 2" {
		t.Errorf("stored path: got %q", got)
	}
	// A stale, relative or foreign stored path falls back to the glob.
	foreign := filepath.Join(t.TempDir(), "notes.jsonl")
	if err := os.WriteFile(foreign, fixture(t, "images_only.jsonl"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"", filepath.Join(home, "gone", filepath.Base(stored)), "rollout-x-" + codexTestID + ".jsonl", foreign} {
		if got := read(p); got != "example 1\nexample 2\nexample 2b" {
			t.Errorf("stored %q: got %q, want the globbed %s", p, got, globbed)
		}
	}
}

func TestCodexRollout_MissingIsErrNoTranscript(t *testing.T) {
	home := t.TempDir()
	if _, err := OpenTranscript(agentkind.Codex, codexTestID, "", home); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("no sessions dir: err = %v", err)
	}
	if err := os.MkdirAll(filepath.Join(home, "sessions", "2026", "10", "12"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenTranscript(agentkind.Codex, codexTestID, "", home); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("no rollout: err = %v", err)
	}
	// Removed between locate and read.
	path := writeRollout(t, home, "2026/10/12", fixture(t, "paginated.jsonl"))
	tr, err := OpenTranscript(agentkind.Codex, codexTestID, path, home)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := tr.OwnerText(2000); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("removed rollout: err = %v", err)
	}
}

func TestCodexRollout_EmptyHomeIsAnErrorNotCwd(t *testing.T) {
	if _, err := OpenTranscript(agentkind.Codex, codexTestID, "", ""); err == nil || errors.Is(err, ErrNoTranscript) {
		t.Errorf("empty home: err = %v, want a hard error", err)
	}
}

func TestCodexRollout_NonUUIDRejected(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, "2026/10/12", fixture(t, "paginated.jsonl"))
	for _, id := range []string{"", "*", "../../etc/passwd", strings.ToUpper(codexTestID), codexTestID + "x"} {
		_, err := OpenTranscript(agentkind.Codex, id, "", home)
		if err == nil || errors.Is(err, ErrNoTranscript) {
			t.Errorf("id %q: err = %v, want a rejection", id, err)
		}
	}
}

func TestOpenTranscript_ClaudeAndUnknownKind(t *testing.T) {
	dir := t.TempDir()
	id := "3f2a1b4c-0000-4000-8000-0000000000aa"
	sub := filepath.Join(dir, "projects", "-tmp-acme")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	line := `{"type":"user","message":{"role":"user","content":"fix the login redirect"}}`
	if err := os.WriteFile(filepath.Join(sub, id+".jsonl"), []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	tr, err := OpenTranscript(agentkind.Claude, id, "/ignored/for/claude", dir)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := tr.OwnerText(2000); err != nil || got != "fix the login redirect" {
		t.Errorf("claude OwnerText = %q, %v", got, err)
	}
	if _, err := OpenTranscript("shell", id, "", dir); err == nil {
		t.Error("a shell kind opened a transcript")
	}
}
