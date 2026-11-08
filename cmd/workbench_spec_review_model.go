package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/agentlog"
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
	if session.Kind != "claude" && session.Kind != "codex" {
		return &sessionCfg, model, nil
	}
	sessionCfg.AI.Provider = session.Kind
	_, model = providers.ResolveModelsFor(&sessionCfg, session.Kind)
	if session.Kind == "codex" && session.TranscriptPath.Valid && session.TranscriptPath.String != "" {
		exact, err := specReviewTranscriptModelContext(ctx, session.TranscriptPath.String, true)
		if exact != "" {
			model = exact
		}
		return &sessionCfg, model, err
	}
	if session.Kind == "claude" {
		path, err := specReviewClaudeTranscript(ctx, database, session)
		if err != nil || path == "" {
			return &sessionCfg, model, err
		}
		exact, err := specReviewTranscriptModelContext(ctx, path, false)
		if exact != "" {
			model = exact
		}
		return &sessionCfg, model, err
	}
	conversations, err := sessionFeedConversations(ctx, database, session)
	if err != nil {
		return &sessionCfg, model, err
	}
	if len(conversations) == 0 {
		return &sessionCfg, model, nil
	}
	latest := conversations[len(conversations)-1]
	exact, err := specReviewTranscriptModelContext(ctx, latest.Path, latest.Codex)
	if err != nil {
		return &sessionCfg, model, err
	}
	if exact != "" {
		model = exact
	} // Deliberately bypass retired-model/family normalization.
	return &sessionCfg, model, nil
}

// Only the selected main conversation is read, never a neighbouring session or subagent.
func specReviewTranscriptModel(path string, codex bool) (string, error) {
	return specReviewTranscriptModelContext(context.Background(), path, codex)
}

func specReviewTranscriptModelContext(ctx context.Context, path string, codex bool) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", err
	}
	// Read the whole snapshot: a long tool turn may have its sole model record
	// arbitrarily far before EOF. Buffer size remains bounded per JSONL record.
	scanner := bufio.NewScanner(io.LimitReader(f, info.Size()))
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	var model, fallback string
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		var record struct {
			Type        string `json:"type"`
			IsSidechain bool   `json:"isSidechain"`
			Model       string `json:"model"`
			Payload     struct {
				Model string `json:"model"`
			} `json:"payload"`
			Message struct {
				Model string `json:"model"`
			} `json:"message"`
		}
		if json.Unmarshal(scanner.Bytes(), &record) != nil || record.IsSidechain {
			continue
		}
		if codex {
			if record.Type == "turn_context" && strings.TrimSpace(record.Payload.Model) != "" {
				model = record.Payload.Model
			}
			if record.Type == "session_meta" {
				fallback = record.Payload.Model
				if fallback == "" {
					fallback = record.Model
				}
			}
		} else if record.Type == "assistant" && record.Message.Model != "" && record.Message.Model != "<synthetic>" {
			model = record.Message.Model
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if model == "" {
		model = fallback
	}
	return strings.TrimSpace(model), nil
}

// Locate only this session's main transcript; discovery errors must fail the
// review rather than silently selecting the default model.
func specReviewClaudeTranscript(ctx context.Context, database *db.DB, session *db.TerminalSession) (string, error) {
	id := session.ClaudeSessionID.String
	if id == "" {
		ledger, err := database.ListTerminalAgentSessions(session.ID)
		if err != nil {
			return "", err
		}
		if len(ledger) == 0 {
			return "", nil
		}
		id = ledger[len(ledger)-1].AgentSessionID
	}
	if filepath.Base(id) != id {
		return "", fmt.Errorf("invalid main conversation id")
	}
	roots := append([]string{session.FolderPath}, agentlog.WorktreeRoots(ctx, session.FolderPath)...)
	dirs, err := agentlog.CandidateDirs(filepath.Join(agentsClaudeDir(), "projects"), roots)
	if err != nil {
		return "", err
	}
	for _, dir := range dirs {
		path := filepath.Join(dir, id+".jsonl")
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		return path, nil
	}
	return "", nil
}
