package terminal

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestOwnerMessages_SkipsMetaCommandsAndToolResults(t *testing.T) {
	in := strings.Join([]string{
		`{"type":"mode","mode":"default"}`,
		`{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}`,
		`{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the login redirect"},{"type":"image"}]}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"secret output"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}`,
		`{"type":"user","message":{"role":"user","content":"and add a test"}}`,
		`not json`,
	}, "\n")
	got, err := OwnerMessages(strings.NewReader(in), 2000)
	if err != nil {
		t.Fatal(err)
	}
	if got != "fix the login redirect\nand add a test" {
		t.Fatalf("got %q", got)
	}
}

func TestOwnerMessages_CapsRunes(t *testing.T) {
	in := `{"type":"user","message":{"role":"user","content":"` + strings.Repeat("я", 50) + `"}}`
	got, err := OwnerMessages(strings.NewReader(in), 10)
	if err != nil {
		t.Fatal(err)
	}
	if utf8.RuneCountInString(got) != 10 {
		t.Fatalf("len %d", utf8.RuneCountInString(got))
	}
}

func TestFindTranscript_RefusesNonUUIDAndEscapes(t *testing.T) {
	dir := t.TempDir()
	if _, err := FindTranscript(dir, "../../etc/passwd"); err == nil {
		t.Fatal("non-uuid accepted")
	}
	id := "3f2a1b4c-0000-4000-8000-000000000001"
	if err := os.MkdirAll(filepath.Join(dir, "projects", "-tmp-acme"), 0o700); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), id+".jsonl")
	if err := os.WriteFile(outside, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "projects", "-tmp-acme", id+".jsonl")); err != nil {
		t.Fatal(err)
	}
	if _, err := FindTranscript(dir, id); err == nil {
		t.Fatal("symlink escape accepted")
	}
}

func TestFindTranscript_FindsRegularFile(t *testing.T) {
	dir := t.TempDir()
	id := "3f2a1b4c-0000-4000-8000-000000000002"
	sub := filepath.Join(dir, "projects", "-tmp-acme")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, id+".jsonl"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := FindTranscript(dir, id); err != nil {
		t.Fatal(err)
	}
}

func TestOwnerMessages_SkipsOversizedLine(t *testing.T) {
	old := maxTranscriptLine
	maxTranscriptLine = 200
	t.Cleanup(func() { maxTranscriptLine = old })
	in := strings.Join([]string{
		`{"type":"user","message":{"role":"user","content":"first"}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"` + strings.Repeat("A", 100000) + `"}]}}`,
		`{"type":"user","message":{"role":"user","content":"last"}}`,
	}, "\n")
	got, err := OwnerMessages(strings.NewReader(in), 2000)
	if err != nil {
		t.Fatal(err)
	}
	if got != "first\nlast" {
		t.Fatalf("got %q", got)
	}
}

func TestFindTranscript_EmptyClaudeDirIsAnErrorNotCwd(t *testing.T) {
	id := "3f2a1b4c-0000-4000-8000-000000000003"
	dir := t.TempDir()
	t.Chdir(dir)
	if err := os.MkdirAll(filepath.Join(dir, "projects", "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "projects", "x", id+".jsonl"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := FindTranscript("", id); err == nil || errors.Is(err, ErrNoTranscript) {
		t.Fatalf("want a hard error, got %v", err)
	}
}
