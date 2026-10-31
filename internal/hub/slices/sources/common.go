package sources

// Helpers of the asks, permission and work alert sources that the other
// sources' helpers (clip.go, workbench.go, target.go) do not already cover.

import (
	"context"
	"errors"
	"strings"
)

// inList is "?,?,…" and its arguments for ids.
func inList(ids []int64) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return strings.TrimSuffix(strings.Repeat("?,", len(ids)), ","), args
}

// errClass names a source error for a log line by its kind, never its text.
func errClass(err error) string {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "canceled"
	}
	return "error"
}

// int64Ptr is a pointer to a copy of v.
func int64Ptr(v int64) *int64 { return &v }
