// Package devpack ships the Watchtower skill pack: markdown skills that teach
// a developer's coding agent how to use Watchtower's MCP tools. The files are
// embedded in the binary so `watchtower integrate` can install them without a
// network fetch or a second artifact to keep in sync.
package devpack

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"path"
	"sort"
	"strings"
)

//go:embed skills/*/SKILL.md
var skillFS embed.FS

// MarkerKey is the frontmatter key stamped on every shipped skill. The
// installer removes or rewrites ONLY files carrying it (DEV-04), so a file a
// user wrote by hand in the same directory is never touched.
const MarkerKey = "x-watchtower-pack"

// Skill is one shipped skill: its directory name, its full SKILL.md text, and
// the digest the installer compares against to detect user edits.
type Skill struct {
	Name    string
	Content string
	SHA256  string
}

// Skills returns the embedded pack, sorted by name. The result is stable
// across calls — the installer's drift detection depends on it.
func Skills() []Skill {
	entries, err := fs.ReadDir(skillFS, "skills")
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("devpack: reading embedded skills: " + err.Error())
	}
	out := make([]Skill, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := skillFS.ReadFile(path.Join("skills", e.Name(), "SKILL.md"))
		if err != nil {
			panic("devpack: reading " + e.Name() + ": " + err.Error())
		}
		content := string(b)
		sum := sha256.Sum256([]byte(content))
		out = append(out, Skill{
			Name:    e.Name(),
			Content: content,
			SHA256:  hex.EncodeToString(sum[:]),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// HasMarker reports whether content's YAML frontmatter carries the pack
// marker, i.e. whether the installer is allowed to touch the file at all.
// Scoped to the frontmatter block (between the leading "---" and the next
// one) rather than the whole file, so a user's own skill that merely
// mentions the marker string in its body — in prose, a code sample, a
// changelog entry — is never mistaken for one we shipped.
func HasMarker(content string) bool {
	if !strings.HasPrefix(content, "---\n") {
		return false
	}
	rest := content[len("---\n"):]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return false
	}
	frontmatter := rest[:end]
	return strings.Contains(frontmatter, MarkerKey+":")
}
