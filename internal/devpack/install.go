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
//
// On a per-skill failure the statuses gathered for every skill processed so
// far are still returned alongside the error, so a caller (e.g. the CLI) can
// report what actually happened rather than losing that information because
// one later skill failed.
func Install(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		status, err := installSkill(skillsDir, s)
		if err != nil {
			return out, err
		}
		out = append(out, status)
	}
	return out, nil
}

// installSkill applies Install's decision for exactly one skill and returns
// its resulting status. Kept separate from Install's loop so the crash-window
// self-heal below can be exercised directly against a synthetic Skill in
// tests, without needing the embedded pack to have multiple real versions.
func installSkill(skillsDir string, s Skill) (SkillStatus, error) {
	dir := filepath.Join(skillsDir, s.Name)
	file := filepath.Join(dir, "SKILL.md")

	state, err := planFor(file, s)
	if err != nil {
		return SkillStatus{}, err
	}
	switch state {
	case StateInstalled, StateUpdated:
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return SkillStatus{}, fmt.Errorf("creating %s: %w", dir, err)
		}
		if err := os.WriteFile(file, []byte(s.Content), 0o644); err != nil {
			return SkillStatus{}, fmt.Errorf("writing %s: %w", file, err)
		}
		if err := writeShippedDigest(dir, s.SHA256); err != nil {
			return SkillStatus{}, err
		}
	case StateUnchanged:
		// The file on disk is already byte-identical to what we ship, so
		// recording its digest here is always safe. This repairs the sidecar
		// whenever it is missing or stale — most notably after a previous
		// Install wrote SKILL.md but crashed before writing the sidecar.
		// Left unrepaired, the NEXT pack upgrade would find no matching
		// sidecar and mislabel this untouched file as user-drifted forever;
		// this closes that window on the very next ordinary Install call,
		// well before another upgrade can land.
		if err := writeShippedDigest(dir, s.SHA256); err != nil {
			return SkillStatus{}, err
		}
	}
	return SkillStatus{Name: s.Name, State: state, Path: file}, nil
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
		//
		// This check decides the REPORTED label, not the safety verdict: a
		// foreign file's bytes can never equal a digest we ever shipped or
		// recorded, because every version we ship carries the marker, so a
		// byte-for-byte match would carry it too. The digest comparison
		// below would already reach the same "leave it alone" outcome
		// (Drifted, not Unchanged/Updated) on its own. Kept anyway because
		// it gives the CLI a truthful label — Foreign vs. Drifted mean
		// different things to a user reading a report — and because it is
		// the cheaper check to fail on.
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
			return out, err
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
//
// It deletes exactly the two files we ourselves ever write — SKILL.md and
// its shipped-digest sidecar — by name, never the directory as a whole.
// Claude skill directories conventionally hold companion resources
// (scripts/, references/, a user's own notes); those must survive even when
// SKILL.md next to them is ours to remove. The directory itself is dropped
// only as a best-effort tidy-up once it is empty.
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
			return out, fmt.Errorf("reading %s: %w", file, err)
		}
		if !HasMarker(string(existing)) {
			out = append(out, SkillStatus{Name: s.Name, State: StateForeign, Path: file})
			continue
		}
		state, err := planFor(file, s)
		if err != nil {
			return out, err
		}
		if state == StateDrifted {
			out = append(out, SkillStatus{Name: s.Name, State: StateDrifted, Path: file})
			continue
		}

		if err := os.Remove(file); err != nil && !os.IsNotExist(err) {
			return out, fmt.Errorf("removing %s: %w", file, err)
		}
		if err := os.Remove(filepath.Join(dir, shippedDigestFile)); err != nil && !os.IsNotExist(err) {
			return out, fmt.Errorf("removing sidecar in %s: %w", dir, err)
		}
		// Best-effort: only an empty directory is dropped. Any companion
		// file left inside — ours or the user's — keeps the directory alive.
		if entries, err := os.ReadDir(dir); err == nil && len(entries) == 0 {
			_ = os.Remove(dir)
		}

		out = append(out, SkillStatus{Name: s.Name, State: StateRemoved, Path: file})
	}
	return out, nil
}

// The sidecar records the digest of what WE last wrote, which is how a pack
// upgrade is told apart from a user edit. It lives next to the skill file and
// is deleted alongside it, by name, in Remove.
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
