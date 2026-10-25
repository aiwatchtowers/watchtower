package fsutil

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestAttachPayloads_ChildReadsEachFD(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	big := strings.Repeat("x", 1<<20) // past any pipe buffer
	cmd := exec.Command("/bin/sh", "-c", `cat "$0"; cat "$1"`)
	payloads, cleanup, err := AttachPayloads(cmd, "first\n", big)
	if err != nil {
		t.Fatal(err)
	}
	if payloads[0].Path != "/dev/fd/3" || payloads[1].Path != "/dev/fd/4" {
		t.Fatalf("paths = %q, %q", payloads[0].Path, payloads[1].Path)
	}
	cmd.Args = append(cmd.Args, payloads[0].Path, payloads[1].Path)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		cleanup()
		t.Fatal(err)
	}
	cleanup()
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "first\n"+big {
		t.Fatalf("child read %d bytes, want %d", out.Len(), len("first\n")+len(big))
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("temp dir holds %d entries, want none", len(entries))
	}
}

func TestAttachPayloads_FDsFollowExistingExtraFiles(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	cmd := exec.Command("/usr/bin/true")
	cmd.ExtraFiles = []*os.File{r}
	payloads, cleanup, err := AttachPayloads(cmd, "a")
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	if payloads[0].Path != "/dev/fd/4" {
		t.Fatalf("path = %q, want /dev/fd/4", payloads[0].Path)
	}
}

// A child that exits without reading must not leave the writer blocked.
func TestAttachPayloads_UnreadPayloadDoesNotHang(t *testing.T) {
	cmd := exec.Command("/usr/bin/true")
	_, cleanup, err := AttachPayloads(cmd, strings.Repeat("y", 1<<20))
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		cleanup()
		t.Fatal(err)
	}
	cleanup()
	_ = cmd.Wait()
	done := make(chan struct{})
	go func() { waitPayloadWriters(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("payload writer still blocked after the child exited")
	}
}

func TestRemoveOnce_AfterTheChildRead(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	path, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	// A child that reads the path twice (codex stats, then reads) gets the
	// content both times; the file goes at its first stdout output.
	var out bytes.Buffer
	cmd := exec.Command("/bin/sh", "-c", `c=$(cat "$0"; cat "$0"); printf %s "$c"`, path)
	cmd.Stdout = OnFirstWrite(&out, RemoveOnce(path))
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "bodybody" {
		t.Fatalf("child read %q", out.String())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file still there: %v", err)
	}
	RemoveOnce("")() // no-op
}
