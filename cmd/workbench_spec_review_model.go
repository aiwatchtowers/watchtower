package cmd

import (
	"context"
	"errors"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/sessionagent"
)

// Session selection is local to this review; config.yaml and other agents stay unchanged.
func specReviewSessionConfig(ctx context.Context, database *db.DB, askID int64, cfg *config.Config) (*config.Config, string, error) {
	sessionCfg := *cfg
	sessionCfg.AI.ConfiguredProvider = cfg.AI.ConfiguredProviderID()
	if sessionCfg.AI.Provider == "" {
		sessionCfg.AI.Provider = "claude"
	}
	_, model := providers.ResolveModelsFor(&sessionCfg, sessionCfg.AI.Provider)
	ask, err := database.GetOwnerAskByID(askID)
	if err != nil {
		return &sessionCfg, model, err
	}
	if !ask.SessionID.Valid {
		return &sessionCfg, model, nil
	}
	session, err := sessionagent.LoadSession(database, ask.SessionID.Int64)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return &sessionCfg, model, nil
	}
	if err != nil {
		return &sessionCfg, model, err
	}
	adapter, ok := sessionagent.Of(session.Kind)
	if !ok {
		return &sessionCfg, model, nil
	}
	sessionCfg.AI.Provider = string(adapter.Kind())
	_, model = providers.ResolveModelsFor(&sessionCfg, sessionCfg.AI.Provider)
	exact, err := adapter.SessionModel(ctx, database, session, sessionagent.Homes{
		Claude: agentsClaudeDir, Codex: terminalCodexHome,
	})
	if exact != "" {
		model = exact // Deliberately bypass retired-model/family normalization.
	}
	return &sessionCfg, model, err
}

// Only the selected main conversation is read, never a neighbouring session or subagent.
func specReviewTranscriptModel(path string, codex bool) (string, error) {
	return specReviewTranscriptModelContext(context.Background(), path, codex)
}

func specReviewTranscriptModelContext(ctx context.Context, path string, codex bool) (string, error) {
	return sessionagent.TranscriptModel(ctx, path, codex)
}
