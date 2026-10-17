package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
	"watchtower/internal/ollama"
	"watchtower/internal/planusage"
	"watchtower/internal/providers"
	"watchtower/internal/sessionfeed"
)

// instructionGeneratorFactory is the seam tests override. The miner's user
// message is the owner's own typed text, so the CLI generators are switched
// to their stdin-only mode (CHAT-04: owner text is never on argv; the
// cmd.terminalTitleGeneratorFactory precedent, which the daemon cannot import).
var instructionGeneratorFactory = func(cfg *config.Config) digest.Generator {
	light, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	var gen digest.Generator
	switch cfg.AI.Provider {
	case "codex":
		gen = codex.NewCodexGenerator(light, strong, cfg.CodexPath)
	case "ollama":
		gen = ollama.NewGenerator(light, strong, cfg.AI.OllamaURL)
	default:
		gen = digest.NewClaudeGenerator(light, strong, cfg.ClaudePath)
	}
	if s, ok := gen.(interface{ SetStdinOnly(bool) }); ok {
		s.SetStdinOnly(true)
	}
	return digest.WithCallTimeout(gen, digest.DaemonAICallTimeout)
}

// instructionSuggestionsDirs is the test seam for the transcript directories
// (the same rules as the cmd terminal seams: Claude Code's dir is always
// ~/.claude; Codex's is an absolute $CODEX_HOME, else ~/.codex).
var instructionSuggestionsDirs = func() sessionfeed.Dirs {
	dirs := sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentlog.DefaultClaudeDir(), "projects")}
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		dirs.CodexHome = dir
	} else if home, err := os.UserHomeDir(); err == nil {
		dirs.CodexHome = filepath.Join(home, ".codex")
	}
	return dirs
}

// runInstructionMiner is the seam tests replace to script the miner's outcome.
var runInstructionMiner = func(ctx context.Context, m *instructions.Miner) (int, *digest.Usage, error) {
	return m.Run(ctx)
}

func (d *Daemon) lastInstructionSuggestionsPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_instruction_suggestions.txt")
}

func (d *Daemon) loadLastInstructionSuggestions() {
	data, err := os.ReadFile(d.lastInstructionSuggestionsPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastInstructionSuggestions = time.Unix(unix, 0)
}

func (d *Daemon) saveLastInstructionSuggestions() {
	data := strconv.FormatInt(d.lastInstructionSuggestions.Unix(), 10)
	if err := os.WriteFile(d.lastInstructionSuggestionsPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("instruction suggestions: failed to save stamp: %v", err)
	}
}

// phaseInstructionSuggestions runs the suggestion miner once a calendar day.
// The stamp is written after a run that returned without error (including
// "nothing to do"); a failed run leaves it so the next cycle retries.
func (d *Daemon) phaseInstructionSuggestions(ctx context.Context) {
	if d.db == nil {
		return
	}
	now := time.Now()
	if sameCalendarDay(d.lastInstructionSuggestions, now) {
		return
	}
	st, err := d.db.GetPlanUsageStatus()
	if err != nil {
		d.logger.Printf("instruction suggestions: plan usage status: %v", err) // unreadable: does not block
	} else if planusage.NearLimit(st) {
		d.logger.Printf("instruction suggestions: Claude plan limit near, skipped")
		return
	}
	miner := &instructions.Miner{
		DB:     d.db,
		Gen:    instructionGeneratorFactory(d.config),
		Read:   instructions.NewFeedReader(ctx, d.db, instructionSuggestionsDirs()),
		Now:    time.Now,
		Logger: d.logger,
	}
	d.trackedPipelineRun("instruction-suggestions", func() pipelineRunStats {
		n, usage, err := runInstructionMiner(ctx, miner)
		stats := pipelineRunStats{items: n, err: err}
		if usage != nil {
			stats.inTok, stats.outTok, stats.totalAPI = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
		}
		if err != nil {
			d.logger.Printf("instruction suggestions: %v", err)
			return stats
		}
		d.lastInstructionSuggestions = now
		d.saveLastInstructionSuggestions()
		d.logger.Printf("instruction suggestions: %d written", n)
		return stats
	})
}
