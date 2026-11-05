package sessionfeed

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/rollout"
)

// maxSubagentDepth bounds FindSubagent's descent into nested subagents.
const maxSubagentDepth = 8

// ReadSession is the entries of `workbench session-feed --session S --json`
// read whole (no cursor), or with toolUseID set those of `--subagent T`: the
// one reader the CLI and the hub's session_chat slice share. A missing
// session wraps db.ErrTerminalSessionNotFound; a shell session is refused.
func ReadSession(ctx context.Context, d *db.DB, sessionID int64, toolUseID string, dirs Dirs) ([]Entry, error) {
	sess, err := d.GetTerminalSession(sessionID)
	if err != nil {
		return nil, fmt.Errorf("session %d: %w", sessionID, err)
	}
	kind := agentkind.Kind(sess.Kind)
	if kind != agentkind.Claude && kind != agentkind.Codex {
		return nil, fmt.Errorf("session %d is not an agent session", sessionID)
	}
	convs, err := SessionConversations(ctx, d, sessionID, kind == agentkind.Codex, sess.FolderPath, sess.TranscriptPath.String, dirs)
	if err != nil {
		return nil, err
	}
	if toolUseID != "" {
		res, _, err := FindSubagent(convs, toolUseID)
		if err != nil {
			return nil, err
		}
		return res.Entries, nil
	}
	var lookup AskLookup
	if sess.WorkbenchID.Valid {
		lookup = AskLookupFor(d, sess.WorkbenchID.Int64)
	}
	feed, err := Build(convs, nil, lookup)
	if err != nil {
		return nil, err
	}
	return feed.Entries, nil
}

// AskLookupFor resolves the asks of workbench workbenchID only, with the
// answer rendered as the owner gave it. Reading never marks an ask
// delivered.
func AskLookupFor(d *db.DB, workbenchID int64) AskLookup {
	return func(id int64) (string, string, bool) {
		a, err := d.GetOwnerAsk(workbenchID, id)
		if err != nil {
			return "", "", false
		}
		if a.Status != "answered" && a.Status != "delivered" {
			return a.Title, "", true
		}
		text, _, err := asks.RenderStored(a.Kind, a.Payload, a.Answer)
		if err != nil {
			return a.Title, "", true
		}
		return a.Title, text, true
	}
}

// FindSubagent finds the subagent started by tool call toolUseID in any
// conversation of the tab (or nested in another subagent) and returns its
// feed, nested markers resolved, with the path of its transcript file. A
// one-off drill-in: it parses every subagent on the way, correctness over
// speed.
func FindSubagent(convs []Conversation, toolUseID string) (*Result, string, error) {
	for _, c := range convs {
		if c.Codex {
			res, path, err := findCodexSubagent(c, toolUseID, 0)
			if err != nil {
				return nil, "", err
			}
			if res != nil {
				return res, path, nil
			}
			continue
		}
		feed, err := Build([]Conversation{c}, nil, nil)
		if err != nil {
			return nil, "", err
		}
		dir := strings.TrimSuffix(c.Path, ".jsonl")
		res, path, err := findSubagent(dir, feed.Entries, toolUseID, 0)
		if err != nil {
			return nil, "", err
		}
		if res != nil {
			return res, path, nil
		}
	}
	return nil, "", fmt.Errorf("subagent %s not found", toolUseID)
}

func findSubagent(sessionDir string, entries []Entry, toolUseID string, depth int) (*Result, string, error) {
	for _, e := range entries {
		ref := e.Subagent
		if e.Kind != KindSubagent || ref == nil || ref.AgentID == "" {
			continue
		}
		match := ref.ToolUseID == toolUseID
		if !match && depth >= maxSubagentDepth {
			continue
		}
		path := filepath.Join(sessionDir, "subagents", "agent-"+ref.AgentID+".jsonl")
		res, err := ParseSubagent(path, ref.ParentReport)
		if err != nil {
			if match {
				return nil, "", err
			}
			continue // an unreadable subagent file hides only its own nesting
		}
		ResolveSubagents(sessionDir, res.Entries)
		if match {
			return res, path, nil
		}
		if found, foundPath, err := findSubagent(sessionDir, res.Entries, toolUseID, depth+1); err != nil || found != nil {
			return found, foundPath, err
		}
	}
	return nil, "", nil
}

func findCodexSubagent(c Conversation, selector string, depth int) (*Result, string, error) {
	if depth >= maxSubagentDepth || !strings.HasPrefix(selector, "codex:") {
		return nil, "", nil
	}
	live, err := LiveOf(c, false, time.Now())
	if err != nil {
		return nil, "", err
	}
	// A broken sibling is irrelevant to a direct selection. Resolve all
	// direct matches before descending into unrelated child branches.
	for _, a := range live.Agents {
		if a.Ref.ToolUseID != selector {
			continue
		}
		path, ok := codexChildPath(c.Path, c.AgentSessionID, a.Ref.AgentID)
		if !ok {
			return nil, "", &selectedCodexSubagentError{fmt.Errorf("subagent transcript unavailable")}
		}
		child := Conversation{Path: path, AgentSessionID: a.Ref.AgentID, Codex: true}
		nested, err := LiveOf(child, false, time.Now())
		if err != nil {
			return nil, "", &selectedCodexSubagentError{err}
		}
		f, _, err := rollout.Open(path)
		if err != nil {
			return nil, "", &selectedCodexSubagentError{err}
		}
		defer f.Close()
		res, err := ParseCodex(f, 0, child.AgentSessionID)
		if err != nil {
			return nil, "", &selectedCodexSubagentError{err}
		}
		res.Entries = append(res.Entries, liveMarkers(nested, child.AgentSessionID)...)
		return res, path, nil
	}
	for _, a := range live.Agents {
		path, ok := codexChildPath(c.Path, c.AgentSessionID, a.Ref.AgentID)
		if !ok {
			continue
		}
		child := Conversation{Path: path, AgentSessionID: a.Ref.AgentID, Codex: true}
		res, path, err := findCodexSubagent(child, selector, depth+1)
		if res != nil {
			return res, path, err
		}
		var selected *selectedCodexSubagentError
		if errors.As(err, &selected) {
			return nil, "", err
		}
		// Only this unrelated branch failed. A direct selected target's
		// error is returned by its direct pass rather than poisoning siblings.
	}
	return nil, "", nil
}

// This error belongs to the requested target, rather than an unrelated
// branch encountered while looking for it.
type selectedCodexSubagentError struct{ error }
