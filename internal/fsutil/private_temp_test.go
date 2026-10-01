package fsutil

import (
	"os"
	"testing"
)

func TestWritePrivateTemp(t *testing.T) {
	path, err := WritePrivateTemp("fsutil-test-*.txt", "payload")
	if err != nil {
		t.Fatalf("WritePrivateTemp: %v", err)
	}
	t.Cleanup(func() { os.Remove(path) })

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(data) != "payload" {
		t.Errorf("content = %q, want %q", data, "payload")
	}
}
