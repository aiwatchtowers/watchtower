package ai

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

// A write that crosses the cap must still report the full length: os/exec
// drains stderr with io.Copy, which turns a short count into
// io.ErrShortWrite and makes cmd.Wait fail a run that exited 0.
func TestLimitedWriter_CrossingCapReportsFullLength(t *testing.T) {
	var buf bytes.Buffer
	lw := &limitedWriter{w: &buf, limit: 8}

	if _, err := io.Copy(lw, strings.NewReader("abc")); err != nil {
		t.Fatalf("first copy: %v", err)
	}
	if _, err := io.Copy(lw, strings.NewReader(strings.Repeat("x", 100))); err != nil {
		t.Fatalf("copy crossing the cap must not fail, got %v", err)
	}
	if _, err := io.Copy(lw, strings.NewReader("tail")); err != nil {
		t.Fatalf("copy past the cap must not fail, got %v", err)
	}
	if got := buf.String(); got != "abcxxxxx" {
		t.Fatalf("buffer = %q, want the first 8 bytes only", got)
	}
}
