package db

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ErrWorkbenchFolderNotAllowed is returned for a folder a project must never be
// bound to: the agent working it would roam the whole disk, the whole home
// directory, or a protected directory (Watchtower's own data — the caller
// knows where that lives; db stays a leaf and never imports config).
var ErrWorkbenchFolderNotAllowed = errors.New("folder cannot be a project")

// checkWorkbenchFolderAllowed refuses resolved when it contains a line break
// (checkFolderLineBreaks), is the filesystem root, the home directory or an
// ancestor of it, or is equal to, inside, or an ancestor of a protected dir.
func checkWorkbenchFolderAllowed(resolved string, protected []string) error {
	if err := checkFolderLineBreaks(resolved); err != nil {
		return err
	}
	if resolved == string(filepath.Separator) {
		return fmt.Errorf("%s is the filesystem root: %w", resolved, ErrWorkbenchFolderNotAllowed)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("checking folder %s: %w", resolved, err)
	}
	if pathWithin(resolveIfExists(home), resolved) {
		return fmt.Errorf("%s is the home directory or contains it: %w", resolved, ErrWorkbenchFolderNotAllowed)
	}
	for _, dir := range protected {
		dir = resolveIfExists(dir)
		if pathWithin(resolved, dir) || pathWithin(dir, resolved) {
			return fmt.Errorf("%s overlaps Watchtower's own data at %s: %w", resolved, dir, ErrWorkbenchFolderNotAllowed)
		}
	}
	return nil
}

func resolveIfExists(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

// pathWithin reports whether child is parent or lies inside it, comparing
// whole path components and ignoring case (APFS is case-insensitive).
func pathWithin(child, parent string) bool {
	c, p := strings.ToLower(filepath.Clean(child)), strings.ToLower(filepath.Clean(parent))
	return c == p || strings.HasPrefix(c, strings.TrimSuffix(p, string(filepath.Separator))+string(filepath.Separator))
}

// checkFolderLineBreaks refuses a folder path holding \n or \r: the path is
// written verbatim into .git/info/exclude lines by the project install, where
// a line break would smuggle in an extra pattern.
func checkFolderLineBreaks(folder string) error {
	if strings.ContainsAny(folder, "\n\r") {
		return fmt.Errorf("%q contains a line break: %w", folder, ErrWorkbenchFolderNotAllowed)
	}
	return nil
}
