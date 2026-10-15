package reviewdiff

import (
	"bytes"
	"context"
	"strconv"
	"strings"
)

type Side struct {
	Exists   bool   `json:"exists"`
	Text     string `json:"text"`
	Binary   bool   `json:"binary"`
	TooLarge bool   `json:"too_large"`
}

// File returns path's content in tree (Exists false when the path is not
// there). Over MaxFileBytes → TooLarge, no text; a NUL in the first 8 KB →
// Binary, no text.
func (r *Repo) File(ctx context.Context, tree, path string) (Side, error) {
	spec := tree + ":" + path
	if _, err := r.git(ctx, nil, "cat-file", "-e", spec); err != nil {
		return Side{}, nil //nolint:nilerr // a failing cat-file -e means the path is not in the tree
	}
	sizeOut, err := r.git(ctx, nil, "cat-file", "-s", spec)
	if err != nil {
		return Side{}, err
	}
	size, _ := strconv.Atoi(strings.TrimSpace(string(sizeOut)))
	if size > MaxFileBytes {
		return Side{Exists: true, TooLarge: true}, nil
	}
	blob, err := r.git(ctx, nil, "cat-file", "blob", spec)
	if err != nil {
		return Side{}, err
	}
	head := blob
	if len(head) > 8192 {
		head = head[:8192]
	}
	if bytes.IndexByte(head, 0) >= 0 {
		return Side{Exists: true, Binary: true}, nil
	}
	return Side{Exists: true, Text: string(blob)}, nil
}
