package devpack

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"path"
)

// The project skill is embedded apart from the generic pack: it only makes
// sense inside a folder bound to a Watchtower project, so the plain
// `integrate claude-code` (which installs Skills() into ~/.claude/skills)
// must never pick it up.
//
//go:embed projectskill/*/SKILL.md
var projectSkillFS embed.FS

// ProjectSkillName is the skill's directory name inside the project folder's
// .claude/skills and the frontmatter name it carries.
const ProjectSkillName = "watchtower-project"

// ProjectSkill returns the embedded watchtower-project skill.
func ProjectSkill() (name string, body []byte) {
	b, err := projectSkillFS.ReadFile(path.Join("projectskill", ProjectSkillName, "SKILL.md"))
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("devpack: reading embedded project skill: " + err.Error())
	}
	return ProjectSkillName, b
}

// projectSkill wraps ProjectSkill in the pack's Skill shape, so the project
// install reuses the same DEV-04 decision (installSkill/planFor) as the pack.
func projectSkill() Skill {
	name, body := ProjectSkill()
	sum := sha256.Sum256(body)
	return Skill{Name: name, Content: string(body), SHA256: hex.EncodeToString(sum[:])}
}
