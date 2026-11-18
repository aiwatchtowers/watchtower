package devpack

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// RenderedSkillNames are the skill folders the workbench install writes,
// under .claude/skills (Claude Code) and .agents/skills (Codex).
var RenderedSkillNames = []string{WorkbenchSkillName, FlowSkillName}

// RenderWorkbenchFiles returns the files a workbench install writes into a
// fresh folder for o, keyed by their slash path relative to the folder: the
// skill pair under .claude/skills and .agents/skills and
// .claude/settings.local.json (the hooks and the cleanup allow rule). It
// runs the install's own steps (installSkillPair, installWorkbenchHooks)
// into a scratch folder, so the bytes are what an install would write, and
// it never touches o.Folder: no registration, exclude line or codex trust
// (the session cleanup tells these files from the agent's work, #1878).
func RenderWorkbenchFiles(o WorkbenchInstallOptions) (map[string][]byte, error) {
	scratch, err := os.MkdirTemp("", "watchtower-render-")
	if err != nil {
		return nil, fmt.Errorf("rendering the workbench files: %w", err)
	}
	defer func() { _ = os.RemoveAll(scratch) }()
	o.Folder = scratch
	if o.WorkbenchID <= 0 || o.Bin == "" {
		return nil, errors.New("rendering the workbench files: no workbench id or binary path")
	}
	_, _, _, errs := installSkillPair(o.skillsDir(), o)
	_, _, _, codexErrs := installSkillPair(o.codexSkillsDir(), o)
	_, _, hookErr := installWorkbenchHooks(o)
	if err := errors.Join(append(append(errs, codexErrs...), hookErr)...); err != nil {
		return nil, fmt.Errorf("rendering the workbench files: %w", err)
	}
	files := map[string][]byte{}
	err = filepath.WalkDir(scratch, func(p string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		b, err := os.ReadFile(p) //nolint:gosec // a file of our own scratch folder
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(scratch, p)
		if err != nil {
			return err
		}
		files[filepath.ToSlash(rel)] = b
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("rendering the workbench files: %w", err)
	}
	return files, nil
}
