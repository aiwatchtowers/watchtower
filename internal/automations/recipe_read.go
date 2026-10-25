package automations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
)

// ReadRecipe is ReadRecipeFile for a stream (the Desktop pipes the editor's
// text on stdin, #604 S6): the first MaxRecipeBytes+1 bytes — enough for
// ParseRecipe to refuse an oversized recipe — and the ContentHash of the
// whole stream, read to its end.
func ReadRecipe(r io.Reader) ([]byte, string, error) {
	h := sha256.New()
	var head bytes.Buffer
	if _, err := io.Copy(h, io.TeeReader(io.LimitReader(r, MaxRecipeBytes+1), &head)); err != nil {
		return nil, "", fmt.Errorf("reading recipe: %w", err)
	}
	if _, err := io.Copy(h, r); err != nil {
		return nil, "", fmt.Errorf("reading recipe: %w", err)
	}
	return head.Bytes(), hex.EncodeToString(h.Sum(nil)), nil
}
