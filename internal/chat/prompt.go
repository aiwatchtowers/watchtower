package chat

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/chat/blocks"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// PromptBudgetChars is the prompt target without project files (spec §4.2).
const PromptBudgetChars = 40000

// ProjectFilesCapChars caps the text project files inlined into the prompt.
const ProjectFilesCapChars = 120000

// PromptOptions selects what BuildSystemPrompt includes.
type PromptOptions struct {
	Surface        string // main | target
	ProjectID      int64  // 0 = no project
	ToolsAvailable bool   // false = a provider session without tools
	Provider       string // "" = claude; decides how project binaries are described
	SkillsDir      string // skills.Dir(workspace); "" = no skills block
	VaultDir       string // memory vault root; "" = no memory block
	MemoryChat     bool   // memory.enabled && memory.surfaces.chat
	Now            time.Time
}

// BuildSystemPrompt assembles the main chat's system prompt in the spec §4.1
// order: identity/time/owner/language, connected sources + Slack linking
// rules, tools & workflow, the surface's actions contract, the artifacts
// contract, skills, memory, the project block, the app guide and the response
// style. No DB schema — the chat has no SQL tool.
func BuildSystemPrompt(ctx context.Context, d *db.DB, cfg *config.Config, o PromptOptions) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if o.Surface != "main" && o.Surface != "target" {
		return "", fmt.Errorf("chat surface %q has no system prompt here (main|target)", o.Surface)
	}
	now := o.Now
	if now.IsZero() {
		now = time.Now()
	}

	identity, err := identityBlock(d, cfg, now)
	if err != nil {
		return "", err
	}
	sources, teams, fallback, err := sourcesBlock(d)
	if err != nil {
		return "", err
	}
	sections := []string{identity, sources}

	if o.ToolsAvailable {
		sections = append(sections,
			blocks.LinkingRules(teams, fallback),
			blocks.ToolsList+"\n\n"+blocks.DataAccessRules,
			blocks.Workflow,
			ActionsContract(o.Surface),
		)
	} else {
		sections = append(sections, noToolsBlock)
	}
	sections = append(sections, ArtifactsContract())

	if o.ToolsAvailable {
		sk, err := skillsBlock(o.SkillsDir)
		if err != nil {
			return "", err
		}
		sections = append(sections, sk)
	}
	if o.MemoryChat {
		sections = append(sections, memoryBlock(o.VaultDir))
	}
	if o.ProjectID > 0 {
		pb, err := projectBlock(d, o.ProjectID, o.Provider)
		if err != nil {
			return "", err
		}
		sections = append(sections, pb)
	}
	sections = append(sections, appGuide, responseStyle)

	var kept []string
	for _, s := range sections {
		if s = strings.TrimSpace(s); s != "" {
			kept = append(kept, s)
		}
	}
	return strings.Join(kept, "\n\n") + "\n", nil
}
