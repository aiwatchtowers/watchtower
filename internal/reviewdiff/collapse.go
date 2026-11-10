package reviewdiff

import (
	"path"
	"slices"
	"strings"
)

var lockfiles = []string{"go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved",
	"Cargo.lock", "Gemfile.lock", "poetry.lock", "composer.lock"}

// CollapsedReason names why a path is folded by default ("lockfile" or
// "generated"), or "" for a path that is shown.
func CollapsedReason(p string) string {
	base := path.Base(p)
	switch {
	case slices.Contains(lockfiles, base):
		return "lockfile"
	case strings.HasSuffix(base, ".pb.go"), strings.HasSuffix(base, "_generated.go"),
		strings.HasSuffix(base, ".generated.swift"), strings.Contains(p, "/generated/"),
		strings.HasSuffix(base, ".golden"):
		return "generated"
	}
	return ""
}
