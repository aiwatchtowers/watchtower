package sessionagent

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/agentfiles"
	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

// SessionModel reads only the selected session's main conversation. Discovery
// and transcript syntax belong to the adapter, not to review consumers.
func (claudeAdapter) SessionModel(ctx context.Context, database *db.DB, session *db.TerminalSession, homes Homes) (string, error) {
	path, err := claudeMainTranscript(ctx, database, session, homes.Claude())
	if err != nil || path == "" {
		return "", err
	}
	return TranscriptModel(ctx, path, false)
}

func (a codexAdapter) SessionModel(ctx context.Context, database *db.DB, session *db.TerminalSession, homes Homes) (string, error) {
	if session.TranscriptPath.Valid && session.TranscriptPath.String != "" {
		return TranscriptModel(ctx, session.TranscriptPath.String, true)
	}
	conversations, err := a.Conversations(ctx, database, session.ID, session.FolderPath, session.TranscriptPath.String,
		sessionfeed.Dirs{CodexHome: homes.Codex()})
	if err != nil || len(conversations) == 0 {
		return "", err
	}
	return TranscriptModel(ctx, conversations[len(conversations)-1].Path, true)
}

// TranscriptModel scans a bounded-record snapshot, retaining the most recent
// actual model and excluding subagents and synthetic assistant messages.
func TranscriptModel(ctx context.Context, path string, codex bool) (string, error) {
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
func claudeMainTranscript(ctx context.Context, database *db.DB, session *db.TerminalSession, home string) (string, error) {
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
	roots := append([]string{session.FolderPath}, agentfiles.WorktreeRoots(ctx, session.FolderPath)...)
	dirs, err := agentfiles.CandidateDirs(filepath.Join(home, "projects"), roots)
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
