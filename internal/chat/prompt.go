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
	WebSearch      bool   // the backend exposes WebSearch (Claude only)
	ClaudeAI       ClaudeAIPrompt
	Now            time.Time
}

// ClaudeAIPromptKind selects the prompt's claude.ai section.
type ClaudeAIPromptKind int

const (
	// ClaudeAIPromptNone renders no claude.ai text: today's prompt (embedded
	// surfaces, decision Q2).
	ClaudeAIPromptNone ClaudeAIPromptKind = iota
	// ClaudeAIPromptOn is a session in claude.ai mode: publishing, and the
	// account's connectors when Connectors is set.
	ClaudeAIPromptOn
	// ClaudeAIPromptOtherProvider is a Codex or Ollama main chat (decision Q4).
	ClaudeAIPromptOtherProvider
	// ClaudeAIPromptUnavailable is a Claude main chat ClaudeAIAvailability
	// turned off; Reason says why.
	ClaudeAIPromptUnavailable
)

// ClaudeAIPrompt is the prompt side of claude.ai mode. Pick Kind from the same
// ClaudeAIAvailability answer that sets ClaudeOptions.ClaudeAI (Connectors
// from the same ClaudeAIMode), so the prompt never promises a tool the
// session lacks. Anything but None needs the main surface; On also needs
// tools.
type ClaudeAIPrompt struct {
	Kind       ClaudeAIPromptKind
	PublishDir string // On: the conversation's publish dir, absolute (required)
	Connectors bool   // On: ClaudeAIMode.Connectors
	Reason     string // Unavailable: ClaudeAIAvailability's reason (required)
}

// BuildSystemPrompt assembles the main chat's system prompt in the spec §4.1
// order: identity/time/owner/language, connected sources + Slack linking
// rules, tools & workflow, the surface's actions contract, the claude.ai
// section, the artifacts and question-card contracts, skills, memory, the
// project block, the app guide and the response style. No DB schema — the
// chat has no SQL tool.
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
	claudeAI, err := claudeAIBlock(o)
	if err != nil {
		return "", err
	}
	sections := []string{identity, sources}
	sections = append(sections, toolSections(o, teams, fallback)...)
	sections = append(sections, claudeAI, ArtifactsContract(), QuestionsContract())
	extra, err := contextSections(d, o)
	if err != nil {
		return "", err
	}
	sections = append(sections, extra...)
	sections = append(sections, appGuideSection(o), responseStyle)
	return joinSections(sections), nil
}

// toolSections is the tools part of the prompt: linking rules, tool list,
// workflow and the surface's actions contract — or the honest no-tools block.
// The data-access rules name every outside resource the session has: none,
// WebSearch, or the claude.ai tools (whose CLAUDE.AI section follows).
func toolSections(o PromptOptions, teams []blocks.SlackTeam, fallback string) []string {
	if !o.ToolsAvailable {
		return []string{noToolsBlock}
	}
	rules := blocks.DataAccessRules
	switch {
	case o.ClaudeAI.Kind == ClaudeAIPromptOn:
		rules = blocks.DataAccessRulesWithClaudeAI
	case o.WebSearch:
		rules = blocks.DataAccessRulesWithWebSearch
	}
	sections := []string{blocks.LinkingRules(teams, fallback), blocks.ToolsList + "\n\n" + rules}
	if o.WebSearch {
		sections = append(sections, blocks.WebSearchRules)
	}
	return append(sections, blocks.Workflow, ActionsContract(o.Surface))
}

// contextSections is the optional context: skills (tools only), memory and
// the project block.
func contextSections(d *db.DB, o PromptOptions) ([]string, error) {
	var sections []string
	if o.ToolsAvailable {
		sk, err := skillsBlock(o.SkillsDir)
		if err != nil {
			return nil, err
		}
		sections = append(sections, sk)
	}
	if o.MemoryChat {
		sections = append(sections, memoryBlock(o.VaultDir))
	}
	if o.ProjectID > 0 {
		pb, err := projectBlock(d, o.ProjectID, o.Provider)
		if err != nil {
			return nil, err
		}
		sections = append(sections, pb)
	}
	return sections, nil
}

// joinSections drops blank sections and joins the rest with blank lines.
func joinSections(sections []string) string {
	var kept []string
	for _, s := range sections {
		if s = strings.TrimSpace(s); s != "" {
			kept = append(kept, s)
		}
	}
	return strings.Join(kept, "\n\n") + "\n"
}
