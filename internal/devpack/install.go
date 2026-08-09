package devpack

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// State is what happened (or would happen) to one skill file.
type State string

const (
	StateInstalled State = "installed" // written fresh
	StateUpdated   State = "updated"   // replaced a previously shipped version
	StateUnchanged State = "unchanged" // already byte-identical to what we ship
	StateDrifted   State = "drifted"   // user-edited: left alone (DEV-04)
	StateMissing   State = "missing"   // not present (status only)
	StateForeign   State = "foreign"   // present without our marker: never touched
	StateRemoved   State = "removed"   // deleted by Remove
)

// SkillStatus is one skill's outcome, always with the path so the CLI can
// report exactly which file it touched.
type SkillStatus struct {
	Name  string
	State State
	Path  string
}

// Install writes the pack into skillsDir, one directory per skill. A file we
// did not ship — or one a user has edited since we shipped it — is left
// untouched and reported (DEV-04). Every shipped version's digest is recorded
// in a sidecar so a later run can tell "user edited it" from "we changed it".
func Install(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		dir := filepath.Join(skillsDir, s.Name)
		file := filepath.Join(dir, "SKILL.md")

		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateInstalled || state == StateUpdated {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, fmt.Errorf("creating %s: %w", dir, err)
			}
			if err := os.WriteFile(file, []byte(s.Content), 0o644); err != nil {
				return nil, fmt.Errorf("writing %s: %w", file, err)
			}
			if err := writeShippedDigest(dir, s.SHA256); err != nil {
				return nil, err
			}
		}
		out = append(out, SkillStatus{Name: s.Name, State: state, Path: file})
	}
	return out, nil
}

// planFor decides what Install would do to one file, without writing.
func planFor(file string, s Skill) (State, error) {
	existing, err := os.ReadFile(file)
	if os.IsNotExist(err) {
		return StateInstalled, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", file, err)
	}
	content := string(existing)
	if !HasMarker(content) {
		// Someone else's file living under a name we also use.
		return StateForeign, nil
	}
	sum := sha256.Sum256(existing)
	current := hex.EncodeToString(sum[:])
	if current == s.SHA256 {
		return StateUnchanged, nil
	}
	// The file differs from what we ship. If it still matches the digest we
	// recorded when we last wrote it, the difference is ours (a new pack
	// version) and we may update. Otherwise the user edited it.
	shipped, err := readShippedDigest(filepath.Dir(file))
	if err != nil {
		return "", err
	}
	if shipped != "" && shipped == current {
		return StateUpdated, nil
	}
	return StateDrifted, nil
}

// Status reports what Install would do, writing nothing.
func Status(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		file := filepath.Join(skillsDir, s.Name, "SKILL.md")
		if _, err := os.Stat(file); os.IsNotExist(err) {
			out = append(out, SkillStatus{Name: s.Name, State: StateMissing, Path: file})
			continue
		}
		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateInstalled {
			state = StateMissing
		}
		out = append(out, SkillStatus{Name: s.Name, State: state, Path: file})
	}
	return out, nil
}

// Remove deletes only the skills we shipped and still own: the file must
// carry our marker. A user-edited copy is kept (it is theirs now) and
// reported as drifted; anything without the marker is left as foreign.
func Remove(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		dir := filepath.Join(skillsDir, s.Name)
		file := filepath.Join(dir, "SKILL.md")

		existing, err := os.ReadFile(file)
		if os.IsNotExist(err) {
			out = append(out, SkillStatus{Name: s.Name, State: StateMissing, Path: file})
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", file, err)
		}
		if !HasMarker(string(existing)) {
			out = append(out, SkillStatus{Name: s.Name, State: StateForeign, Path: file})
			continue
		}
		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateDrifted {
			out = append(out, SkillStatus{Name: s.Name, State: StateDrifted, Path: file})
			continue
		}
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("removing %s: %w", dir, err)
		}
		out = append(out, SkillStatus{Name: s.Name, State: StateRemoved, Path: file})
	}
	return out, nil
}

// The sidecar records the digest of what WE last wrote, which is how a pack
// upgrade is told apart from a user edit. It lives next to the skill so
// removing the directory removes it too.
const shippedDigestFile = ".watchtower-shipped"

func writeShippedDigest(dir, digest string) error {
	p := filepath.Join(dir, shippedDigestFile)
	if err := os.WriteFile(p, []byte(digest+"\n"), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", p, err)
	}
	return nil
}

func readShippedDigest(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, shippedDigestFile))
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading shipped digest: %w", err)
	}
	return string(trimNewline(b)), nil
}

func trimNewline(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}
