package devpack

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Overlays maps a pack skill's name to the owner's approved lines, in order
// (the skill_pack_overlays rows, spec 2026-11-03 §4.3). A nil map is none.
type Overlays map[string][]string

// OverlayHeading opens the owner's block in a rendered skill.
const OverlayHeading = "## Owner additions (approved by the owner)"

// Render is s with the owner's lines in a block right after the frontmatter
// (fixed position): the frontmatter through its closing "---\n", then
// "\n" + OverlayHeading + "\n\n" + the lines + "\n", then the rest of the
// shipped body unchanged. SHA256 is the rendered bytes' digest, so the
// installer's sidecar records what it wrote and a rendered copy is never
// mistaken for an owner edit (DEV-04). Blank lines are dropped; no lines (or
// a skill without a frontmatter, which the pack never ships) leave s as it is.
func Render(s Skill, lines []string) Skill {
	var kept []string
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			kept = append(kept, l)
		}
	}
	if len(kept) == 0 || !strings.HasPrefix(s.Content, "---\n") {
		return s
	}
	end := strings.Index(s.Content[len("---\n"):], "\n---\n")
	if end < 0 {
		return s
	}
	cut := len("---\n") + end + len("\n---\n")
	content := s.Content[:cut] + "\n" + OverlayHeading + "\n\n" + strings.Join(kept, "\n") + "\n" + s.Content[cut:]
	sum := sha256.Sum256([]byte(content))
	return Skill{Name: s.Name, Content: content, SHA256: hex.EncodeToString(sum[:])}
}

// PackSkillNames is every skill an overlay may target: the pack (Skills)
// and the workbench core and preset, sorted.
func PackSkillNames() []string {
	names := []string{WorkbenchSkillName, FlowSkillName}
	for _, s := range Skills() {
		names = append(names, s.Name)
	}
	sort.Strings(names)
	return names
}

// PackSkill is the shipped skill named name, unrendered.
func PackSkill(name string) (Skill, bool) {
	switch name {
	case WorkbenchSkillName:
		return workbenchSkill(), true
	case FlowSkillName:
		return flowSkill(), true
	}
	for _, s := range Skills() {
		if s.Name == name {
			return s, true
		}
	}
	return Skill{}, false
}

// RerenderSkill brings an existing copy of pack skill name in skillsDir to
// the shipped skill rendered with lines, under the DEV-04 rules: a copy that
// is ours (StateUpdated) is rewritten with its sidecar; StateUnchanged writes
// nothing; a missing, owner-edited (StateDrifted) or foreign copy is left as
// it is and its state returned; a pre-v10 single-file workbench core is
// left for the workbench install and reported StateDrifted. It never
// creates a copy. The caller checks
// that skillsDir stays inside its folder (skillDirsInside): a symlinked
// skills directory is not guarded here.
func RerenderSkill(skillsDir, name string, lines []string) (State, error) {
	s, ok := PackSkill(name)
	if !ok {
		return "", fmt.Errorf("%s is not a Watchtower pack skill", name)
	}
	if name == WorkbenchSkillName {
		// A sidecar-less shipped core is ours, as for a resync.
		if err := adoptShippedSingleFile(skillsDir); err != nil {
			return "", err
		}
		// A pre-v10 core carries the methodology itself: rewriting it
		// alone would drop the methodology without the preset beside it.
		// The workbench install splits it (installSkillPair); here it is
		// left as it is and reported as not rendered (StateDrifted).
		file := filepath.Join(skillsDir, name, "SKILL.md")
		if single, err := carriesMethodology(file); err == nil && single {
			return StateDrifted, nil
		}
	}
	if err := adoptPlainCopy(skillsDir, s); err != nil {
		return "", err
	}
	s = Render(s, lines)
	dir := filepath.Join(skillsDir, name)
	file := filepath.Join(dir, "SKILL.md")
	state, err := planFor(file, s)
	if err != nil {
		return "", err
	}
	switch state {
	case StateInstalled:
		return StateMissing, nil
	case StateUpdated:
		if err := writeFileNoFollow(file, []byte(s.Content)); err != nil {
			return "", err
		}
		if err := writeShippedDigest(dir, s.SHA256); err != nil {
			return "", err
		}
	case StateUnchanged:
		// Current already; repair the sidecar as installSkill does, so the
		// next overlay change does not read this copy as drift.
		if err := writeShippedDigest(dir, s.SHA256); err != nil {
			return "", err
		}
	case StateDrifted, StateForeign, StateMissing, StateRemoved:
		// Not ours to touch (DEV-04).
	}
	return state, nil
}

// overlaid is s rendered with ov's lines for it.
func (ov Overlays) overlaid(s Skill) Skill {
	return Render(s, ov[s.Name])
}

// coreSkill and flowSkill are the workbench core and preset rendered with
// the options' overlays.
func (o WorkbenchInstallOptions) coreSkill() Skill { return o.Overlays.overlaid(workbenchSkill()) }
func (o WorkbenchInstallOptions) flowSkill() Skill { return o.Overlays.overlaid(flowSkill()) }

// keptState is how a copy reads when the overlays could not be read and it
// was not written: one that matches our sidecar (possibly rendered with the
// owner's lines) is reported current, not "updated" — nothing was updated,
// and no Repair is due for it.
func keptState(st SkillStatus) SkillStatus {
	if st.State == StateUpdated {
		st.State = StateUnchanged
	}
	return st
}

// adoptPlainCopy records base's digest beside a copy that is byte-identical
// to the shipped skill unrendered but has no sidecar (a crash between the
// write and the sidecar): it is ours, so a first overlay may render into it
// instead of reading it as an owner edit. Any other copy is left as it is.
func adoptPlainCopy(skillsDir string, base Skill) error {
	dir := filepath.Join(skillsDir, base.Name)
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
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) == base.SHA256 {
		return writeShippedDigest(dir, base.SHA256)
	}
	return nil
}
