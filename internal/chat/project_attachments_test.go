package chat

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/db"
)

func writeProjectFile(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestProjectAttachments_NilAndEmpty(t *testing.T) {
	var warn bytes.Buffer
	if got := ProjectAttachments(nil, &warn); got != nil {
		t.Fatalf("nil context: want nil, got %v", got)
	}
	if got := ProjectAttachments(&db.ChatProjectContext{Name: "p"}, &warn); got != nil {
		t.Fatalf("no binary files: want nil, got %v", got)
	}
	if warn.Len() != 0 {
		t.Fatalf("no warnings expected, got %q", warn.String())
	}
}

func TestProjectAttachments_MapsBinaryFilesInOrder(t *testing.T) {
	dir := t.TempDir()
	png := writeProjectFile(t, dir, "a.png")
	pdf := writeProjectFile(t, dir, "b.pdf")
	pc := &db.ChatProjectContext{BinaryFiles: []db.ChatProjectFile{
		{Name: "diagram.png", Mime: "image/png", Path: png, Size: 1},
		{Name: "spec.pdf", Mime: "application/pdf", Path: pdf, Size: 1},
	}}
	var warn bytes.Buffer
	got := ProjectAttachments(pc, &warn)
	want := []Attachment{
		{Path: png, Mime: "image/png", Name: "diagram.png"},
		{Path: pdf, Mime: "application/pdf", Name: "spec.pdf"},
	}
	if len(got) != len(want) {
		t.Fatalf("want %d attachments, got %d: %v", len(want), len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("attachment %d: want %+v, got %+v", i, want[i], got[i])
		}
	}
}

// A file removed from disk behind the app's back must not fail every turn of
// every chat in the project: it is skipped and named on the warn writer.
func TestProjectAttachments_SkipsMissingFile(t *testing.T) {
	dir := t.TempDir()
	png := writeProjectFile(t, dir, "a.png")
	pc := &db.ChatProjectContext{BinaryFiles: []db.ChatProjectFile{
		{Name: "gone.pdf", Mime: "application/pdf", Path: filepath.Join(dir, "gone.pdf")},
		{Name: "diagram.png", Mime: "image/png", Path: png},
	}}
	var warn bytes.Buffer
	got := ProjectAttachments(pc, &warn)
	if len(got) != 1 || got[0].Name != "diagram.png" {
		t.Fatalf("want only diagram.png, got %v", got)
	}
	if !strings.Contains(warn.String(), "gone.pdf") {
		t.Fatalf("warning must name the skipped file, got %q", warn.String())
	}
}

// Every project file missing is the degenerate clean case: nothing to attach,
// a warning naming the file, no error.
func TestProjectAttachments_AllMissingIsNil(t *testing.T) {
	dir := t.TempDir()
	pc := &db.ChatProjectContext{BinaryFiles: []db.ChatProjectFile{
		{Name: "gone.pdf", Mime: "application/pdf", Path: filepath.Join(dir, "gone.pdf")},
	}}
	var warn bytes.Buffer
	if got := ProjectAttachments(pc, &warn); got != nil {
		t.Fatalf("want nil, got %v", got)
	}
	if !strings.Contains(warn.String(), "gone.pdf") {
		t.Fatalf("warning must name the skipped file, got %q", warn.String())
	}
}
