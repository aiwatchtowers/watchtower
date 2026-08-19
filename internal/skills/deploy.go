package skills

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// DeployState is what happened (or would have happened) to one shipped file.
type DeployState string

const (
	StateInstalled DeployState = "installed" // written fresh
	StateUpdated   DeployState = "updated"   // replaced a previously shipped version
	StateUnchanged DeployState = "unchanged" // already byte-identical to what we ship
	StateDrifted   DeployState = "drifted"   // owner-edited a file we shipped: left alone
	StateForeign   DeployState = "foreign"   // a file we never shipped: never touched
)

// DeployStatus is one shipped skill's outcome, always with the path so a
// caller can report exactly which file it touched.
type DeployStatus struct {
	Name  string
	State DeployState
	Path  string
}

// sidecarFile records the digest of every shipped file we last wrote, keyed by
// skill name. It is what tells a pack upgrade apart from an owner edit, and it
// is the only reason a foreign file with a name we also ship is safe: we never
// wrote it, so it has no entry, so we never touch it.
//
// This is a deliberately separate, smaller implementation of the devpack
// installer's mechanics (internal/devpack/install.go) — a dual path, not a
// shared one: devpack owns one digest per skill directory for an external
// client's file layout, this owns one flat map for the workspace's skills
// directory, and neither should be able to break the other by changing shape.
const sidecarFile = ".watchtower-shipped.json"

// Deploy writes the embedded pack into dir, upgrading in place. A file the
// owner edited, and a file we never shipped, are both left untouched and
// reported. Deploy is safe to run on every daemon start.
//
// On a per-file failure the statuses gathered so far are returned alongside
// the error, so a caller can report what actually happened rather than losing
// that information because one later file failed.
func Deploy(dir string) ([]DeployStatus, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", dir, err)
	}
	recorded, err := readSidecar(dir)
	if err != nil {
		return nil, err
	}

	shipped := Shipped()
	out := make([]DeployStatus, 0, len(shipped))
	dirty := false
	for _, s := range shipped {
		file := filepath.Join(dir, s.Name+fileExt)
		state, err := planFor(file, s, recorded)
		if err != nil {
			return out, err
		}
		switch state {
		case StateInstalled, StateUpdated:
			if err := os.WriteFile(file, []byte(s.Content), 0o644); err != nil {
				return out, fmt.Errorf("writing %s: %w", file, err)
			}
			recorded[s.Name] = s.SHA256
			dirty = true
		case StateUnchanged:
			// The file on disk is already byte-identical to what we ship, so
			// recording its digest here is always safe. This repairs the
			// sidecar whenever it is missing or stale — most notably after a
			// previous Deploy wrote the file but crashed before writing the
			// sidecar. Left unrepaired, the NEXT upgrade would find no
			// matching entry and mislabel this untouched file as owner-drifted
			// forever; this closes that window on the very next ordinary
			// Deploy, well before another upgrade can land.
			if recorded[s.Name] != s.SHA256 {
				recorded[s.Name] = s.SHA256
				dirty = true
			}
		default:
			// Drifted/Foreign: someone else's content now. Nothing to write —
			// and deliberately no sidecar update, so the file stays theirs
			// across every future Deploy.
		}
		out = append(out, DeployStatus{Name: s.Name, State: state, Path: file})
	}

	if dirty {
		if err := writeSidecar(dir, recorded); err != nil {
			return out, err
		}
	}
	return out, nil
}

// digestOf is the one hash used for both the shipped bytes and what is on
// disk, so the two are always compared the same way.
func digestOf(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// planFor decides what Deploy would do to one file, without writing.
func planFor(file string, s ShippedSkill, recorded map[string]string) (DeployState, error) {
	existing, err := os.ReadFile(file)
	if os.IsNotExist(err) {
		return StateInstalled, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", file, err)
	}
	current := digestOf(string(existing))
	if current == s.SHA256 {
		return StateUnchanged, nil
	}
	prior, ours := recorded[s.Name]
	if !ours {
		// A file living under a name we also ship, which we never wrote.
		return StateForeign, nil
	}
	if prior == current {
		// It still matches the version we last wrote, so the difference is
		// ours (a new pack version) and we may replace it.
		return StateUpdated, nil
	}
	return StateDrifted, nil
}

// readSidecar loads the digest map; a missing or unreadable-as-JSON sidecar
// yields an empty map rather than an error — the worst case is that every
// shipped file we already wrote is treated as foreign and left alone, which is
// the safe direction, and the Unchanged self-repair above rebuilds it.
func readSidecar(dir string) (map[string]string, error) {
	b, err := os.ReadFile(filepath.Join(dir, sidecarFile))
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", sidecarFile, err)
	}
	m := map[string]string{}
	if err := json.Unmarshal(b, &m); err != nil {
		return map[string]string{}, nil //nolint:nilerr // a corrupt sidecar degrades to "we shipped nothing", never to an error
	}
	return m, nil
}

func writeSidecar(dir string, m map[string]string) error {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding %s: %w", sidecarFile, err)
	}
	p := filepath.Join(dir, sidecarFile)
	if err := os.WriteFile(p, append(b, '\n'), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", p, err)
	}
	return nil
}
