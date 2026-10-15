package devpack

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// v8CoreSHA256 is the digest of the single-file v8 watchtower-workbench skill
// we shipped (testdata/watchtower-workbench-v8.md, pinned by
// TestV8CoreDigestIsTheShippedFixture). A copy with these exact bytes and no
// sidecar (a crash between the write and the sidecar) is ours: spec
// 2026-10-15 §4.3 "the shipped bytes".
const v8CoreSHA256 = "256a8b31f413d260716c305c677df2681da8a3d7778f3ba93aeb52bd051f9085"

// The exclude lines of the preset in each agent's skills directory.
const (
	flowExcludeLine      = ".claude/skills/" + FlowSkillName + "/"
	codexFlowExcludeLine = ".agents/skills/" + FlowSkillName + "/"
)

// adoptShippedV8 records the v8 digest beside a core skill in skillsDir that
// is byte-identical to the v8 we shipped but has no sidecar, so the upgrade
// takes it as ours.
func adoptShippedV8(skillsDir string) error {
	dir := filepath.Join(skillsDir, WorkbenchSkillName)
	recorded, err := readShippedDigest(dir)
	if err != nil || recorded != "" {
		return err
	}
	b, err := os.ReadFile(filepath.Join(dir, "SKILL.md"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading %s: %w", filepath.Join(dir, "SKILL.md"), err)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) == v8CoreSHA256 {
		return writeShippedDigest(dir, v8CoreSHA256)
	}
	return nil
}

// installSkillPair installs the core skill into skillsDir (adopting a
// sidecar-less shipped v8 first), then syncs the preset beside it. A core
// that could not be installed leaves the preset alone; core is then zero.
func installSkillPair(skillsDir string, presetNone bool) (core, flow SkillStatus, singleFile bool, errs []error) {
	if err := adoptShippedV8(skillsDir); err != nil {
		errs = append(errs, err)
	}
	var err error
	if core, err = installSkill(skillsDir, workbenchSkill()); err != nil {
		return SkillStatus{}, SkillStatus{}, false, append(errs, err)
	}
	if flow, singleFile, err = syncFlowSkill(skillsDir, core, presetNone); err != nil {
		errs = append(errs, err)
	}
	return core, flow, singleFile, errs
}

// syncFlowSkill applies spec §4.3 to the preset beside core: preset none
// removes it when it is ours (an edited or foreign copy is kept and
// reported); otherwise it is installed under the DEV-04 rules — unless core
// is an owner-edited single file from before v9 (singleFile), which carries
// its own methodology: then nothing is written and its status is reported.
func syncFlowSkill(skillsDir string, core SkillStatus, presetNone bool) (flow SkillStatus, singleFile bool, err error) {
	if presetNone {
		flow, err = removeSkill(skillsDir, flowSkill())
		return flow, false, err
	}
	if core.State == StateDrifted {
		if singleFile, err = carriesMethodology(core.Path); err != nil {
			return SkillStatus{}, false, err
		}
		if singleFile {
			flow, err = statusSkill(skillsDir, flowSkill())
			return flow, true, err
		}
	}
	flow, err = installSkill(skillsDir, flowSkill())
	return flow, false, err
}

// carriesMethodology reports whether the core skill file at path is a
// single-file skill from before the split: its marker names a pack version
// below v9.
func carriesMethodology(path string) (bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return false, fmt.Errorf("reading %s: %w", path, err)
	}
	v, ok := packVersion(string(b))
	return ok && v < 9, nil
}

// packVersion is N of the frontmatter's "x-watchtower-pack: vN".
func packVersion(content string) (int, bool) {
	if !HasMarker(content) {
		return 0, false
	}
	rest := strings.TrimPrefix(content, "---\n")
	frontmatter := rest[:strings.Index(rest, "\n---")]
	for _, line := range strings.Split(frontmatter, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), MarkerKey+": v"); ok {
			n, err := strconv.Atoi(strings.TrimSpace(v))
			return n, err == nil
		}
	}
	return 0, false
}

// MethodologyReport is what SyncMethodology did in each skills directory
// holding the core skill; a zero SkillStatus where there is none.
type MethodologyReport struct {
	Claude, Codex    SkillStatus
	SingleFileLayout bool
}

// SyncMethodology writes or removes the preset per o.PresetNone beside each
// core skill copy in the folder (.claude/skills, .agents/skills), touching
// neither the hooks nor the MCP registration: the install a preset change
// runs (spec §8). Each core copy goes through the install first, so a
// pre-v9 core of ours becomes the v9 split before the preset follows it (an
// owner-edited or foreign one is left as it is, DEV-04). A directory without
// the core skill is left alone.
func SyncMethodology(o WorkbenchInstallOptions) (MethodologyReport, error) {
	if err := o.validate(); err != nil {
		return MethodologyReport{}, err
	}
	if !isDir(o.Folder) {
		return MethodologyReport{}, folderGone(o)
	}
	var rep MethodologyReport
	var errs []error
	for _, d := range []struct {
		dir, exclude string
		out          *SkillStatus
	}{
		{o.skillsDir(), flowExcludeLine, &rep.Claude},
		{o.codexSkillsDir(), codexFlowExcludeLine, &rep.Codex},
	} {
		if err := skillDirsInside(o.Folder, d.dir, workbenchSkill(), flowSkill()); err != nil {
			errs = append(errs, err)
			continue
		}
		core, err := statusSkill(d.dir, workbenchSkill())
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if core.State == StateMissing {
			continue
		}
		if !o.PresetNone {
			if _, err := EnsureGitExclude(o.Folder, []string{d.exclude}); err != nil {
				errs = append(errs, err)
			}
		}
		_, flow, single, pairErrs := installSkillPair(d.dir, o.PresetNone)
		errs = append(errs, pairErrs...)
		*d.out = flow
		rep.SingleFileLayout = rep.SingleFileLayout || single
	}
	return rep, errors.Join(errs...)
}

// MethodologyLayout is what a folder's skills directories hold, for the
// brief's preset check (spec §6). Core: a core skill copy of ours or an
// owner-edited one. Flow: our preset, current or a version behind (an edited
// one is the owner's). FlowPresent: any preset copy, an edited or foreign one
// included — resync keeps those, so the preset counts as installed.
// SingleFile: an owner-edited core from before v9.
type MethodologyLayout struct {
	Core, Flow, FlowPresent, SingleFile bool
}

// FolderMethodologyLayout reads both skills directories of folder, writing
// nothing; an unreadable copy counts as absent.
func FolderMethodologyLayout(folder string) MethodologyLayout {
	var l MethodologyLayout
	for _, dir := range []string{filepath.Join(folder, ".claude", "skills"), filepath.Join(folder, ".agents", "skills")} {
		core, err := statusSkill(dir, workbenchSkill())
		if err != nil || core.State == StateMissing || core.State == StateForeign {
			continue
		}
		l.Core = true
		if core.State == StateDrifted {
			if single, err := carriesMethodology(core.Path); err == nil && single {
				l.SingleFile = true
			}
		}
		if flow, err := statusSkill(dir, flowSkill()); err == nil && flow.State != StateMissing {
			l.FlowPresent = true
			l.Flow = l.Flow || flow.State == StateUnchanged || flow.State == StateUpdated
		}
	}
	return l
}
