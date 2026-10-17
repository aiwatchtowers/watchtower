package workbenchmethod

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// Template is what "Create workflow.md" writes (spec §8): the preset key
// commented out, so it changes nothing until the owner edits it, a note that
// the checks are personal settings only (board #558), and a two-line body
// hint.
const Template = `---
# Watchtower methodology for agents working this folder (.watchtower/workflow.md).
# Uncomment the key to set it for everyone; each person's setting in the
# Watchtower app wins over this file.
# preset: watchtower-flow    # watchtower-flow | none
# The ask guard and the finish check are set only in each person's Agent
# Settings in the Watchtower app; this file cannot turn them down.
---

Write your team's rules for agents working this folder here, in plain text.
Every session's brief shows them; they win over the watchtower-flow preset.
`

// CreateTemplate writes Template at folder's FileRel unless something is
// there already: it never overwrites (created false), and never writes
// through a symlink — a .watchtower link is an error, a link in the file's
// place counts as something there.
func CreateTemplate(folder string) (created bool, err error) {
	dir := filepath.Join(folder, filepath.Dir(FileRel))
	fi, err := os.Lstat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := os.Mkdir(dir, 0o755); err != nil {
			return false, fmt.Errorf("creating %s: %w", dir, err)
		}
	case err != nil:
		return false, err
	case !fi.IsDir():
		return false, fmt.Errorf("%s: %w", dir, errSpecialFile)
	}
	f, err := os.OpenFile(filepath.Join(folder, FileRel), os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)
	if errors.Is(err, fs.ErrExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("creating %s: %w", FileRel, err)
	}
	if _, err := f.WriteString(Template); err != nil {
		_ = f.Close()
		return false, fmt.Errorf("writing %s: %w", FileRel, err)
	}
	if err := f.Close(); err != nil {
		return false, fmt.Errorf("closing %s: %w", FileRel, err)
	}
	return true, nil
}
