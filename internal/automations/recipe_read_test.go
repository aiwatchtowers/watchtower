package automations

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ReadRecipe reads a recipe from a stream (the Desktop pipes the editor's
// text, #604 S6) with ReadRecipeFile's cap: the head it returns is at most
// MaxRecipeBytes+1 bytes, so ParseRecipe refuses an oversized recipe, and the
// hash is the whole text's.
func TestReadRecipe_SizeCap(t *testing.T) {
	big := strings.Repeat("x", MaxRecipeBytes+500)
	data, hash, err := ReadRecipe(strings.NewReader(big))
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != MaxRecipeBytes+1 {
		t.Fatalf("head = %d bytes, want %d", len(data), MaxRecipeBytes+1)
	}
	if hash != ContentHash([]byte(big)) {
		t.Fatalf("hash is not the whole text's")
	}

	path := filepath.Join(t.TempDir(), "r.md")
	small := []byte("---\nname: x\n---\n")
	if err := os.WriteFile(path, small, 0o600); err != nil {
		t.Fatal(err)
	}
	fromFile, fileHash, err := ReadRecipeFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fromStream, streamHash, err := ReadRecipe(bytes.NewReader(small))
	if err != nil || !bytes.Equal(fromFile, fromStream) || fileHash != streamHash {
		t.Fatalf("stream read differs from the file read: %v", err)
	}
}
