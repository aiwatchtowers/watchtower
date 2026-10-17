package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

var workbenchSessionFeedCmd = &cobra.Command{
	Use:   "session-feed",
	Short: "Show a workbench session's dialog as a chat: you, the agent, ask answers, subagents",
	Long: "--session S prints the chat of that terminal session, read from the agent's transcript\n" +
		"files (Claude Code only; no AI, nothing stored): your messages, the agent's text, the\n" +
		"answers to its asks, subagent markers, and a separator where the tab started a new\n" +
		"conversation (/clear). --after C returns only what follows cursor C (an entry that\n" +
		"grew keeps its id: upsert by id). --subagent T prints the feed of the subagent started\n" +
		"by tool call T, read whole (its cursor is empty); --after and --subagent exclude each other.\n" +
		"skipped and unknown_records count only what this call read. The database is opened read-only.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchSessionFeed,
}

var (
	workbenchSessionFeedFlagSession  int64
	workbenchSessionFeedFlagAfter    string
	workbenchSessionFeedFlagSubagent string
	workbenchSessionFeedFlagJSON     bool
)

func init() {
	c := workbenchSessionFeedCmd
	fs := c.Flags()
	fs.Int64Var(&workbenchSessionFeedFlagSession, "session", 0, "terminal session id")
	fs.StringVar(&workbenchSessionFeedFlagAfter, "after", "", "cursor from a previous call: print only what follows")
	fs.StringVar(&workbenchSessionFeedFlagSubagent, "subagent", "", "tool_use id of a subagent: print its feed")
	fs.BoolVar(&workbenchSessionFeedFlagJSON, "json", false, "output JSON")
	_ = c.MarkFlagRequired("session")
	c.MarkFlagsMutuallyExclusive("after", "subagent")
	workbenchCmd.AddCommand(c)
}

// sessionFeedJSON is the pinned output of `workbench session-feed --json`.
type sessionFeedJSON struct {
	SessionID      int64                  `json:"session_id"`
	Cursor         string                 `json:"cursor"`
	Entries        []sessionFeedEntryJSON `json:"entries"`
	Subagents      []sessionFeedEntryJSON `json:"subagents"`
	Skipped        int                    `json:"skipped"`
	UnknownRecords map[string]int         `json:"unknown_records"`
}

type sessionFeedEntryJSON struct {
	ID           string                   `json:"id"`
	Kind         sessionfeed.Kind         `json:"kind"`
	At           time.Time                `json:"at"`
	Text         string                   `json:"text"`
	Conversation string                   `json:"conversation"`
	AskID        int64                    `json:"ask_id,omitempty"`
	Title        string                   `json:"title,omitempty"`
	Via          string                   `json:"via,omitempty"`
	Subagent     *sessionfeed.SubagentRef `json:"subagent,omitempty"`
}

func toSessionFeedEntries(es []sessionfeed.Entry) []sessionFeedEntryJSON {
	out := make([]sessionFeedEntryJSON, 0, len(es))
	for _, e := range es {
		out = append(out, sessionFeedEntryJSON{
			ID: e.ID, Kind: e.Kind, At: e.At, Text: e.Text, Conversation: e.Conversation,
			AskID: e.AskID, Title: e.Title, Via: e.Via, Subagent: e.Subagent,
		})
	}
	return out
}

// sessionFeedBusyTimeout is how long the read waits out another process's write lock.
const sessionFeedBusyTimeout = 2 * time.Second

func runWorkbenchSessionFeed(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	id := workbenchSessionFeedFlagSession
	var after *sessionfeed.Cursor
	if workbenchSessionFeedFlagAfter != "" {
		c, err := sessionfeed.ParseCursor(workbenchSessionFeedFlagAfter)
		if err != nil {
			return err
		}
		after = &c
	}
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.OpenExisting(cfg.DBPath(), sessionFeedBusyTimeout)
	if err != nil {
		return err
	}
	defer database.Close()

	sess, err := database.GetTerminalSession(id)
	if errors.Is(err, db.ErrTerminalSessionNotFound) {
		return fmt.Errorf("session %d not found", id)
	}
	if err != nil {
		return err
	}
	if err := requireAgentSession(sess); err != nil {
		return err
	}
	convs, err := sessionFeedConversations(ctx, database, sess)
	if err != nil {
		return err
	}
	lookup := sessionFeedAskLookup(database, sess.WorkbenchID)

	out, err := buildSessionFeedOutput(id, convs, after, lookup, workbenchSessionFeedFlagSubagent)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if workbenchSessionFeedFlagJSON {
		return writeJSON(w, out)
	}
	printSessionFeed(w, out.Entries)
	return nil
}

// requireAgentSession refuses sessions the feed cannot read: shells.
func requireAgentSession(sess *db.TerminalSession) error {
	switch agentkind.Kind(sess.Kind) {
	case agentkind.Claude, agentkind.Codex:
		return nil
	default:
		return fmt.Errorf("session %d is not an agent session", sess.ID)
	}
}

// buildSessionFeedOutput reads either one subagent's feed (sub set) or the
// tab's chat after the cursor.
func buildSessionFeedOutput(id int64, convs []sessionfeed.Conversation, after *sessionfeed.Cursor, lookup sessionfeed.AskLookup, sub string) (sessionFeedJSON, error) {
	out := sessionFeedJSON{SessionID: id, Entries: []sessionFeedEntryJSON{}, Subagents: []sessionFeedEntryJSON{}, UnknownRecords: map[string]int{}}
	if sub != "" {
		res, err := sessionFeedSubagent(convs, sub)
		if err != nil {
			return out, err
		}
		var markers []sessionfeed.Entry
		for _, e := range res.Entries {
			if e.Kind == sessionfeed.KindSubagent {
				markers = append(markers, e)
			}
		}
		out.Entries, out.Subagents = toSessionFeedEntries(res.Entries), toSessionFeedEntries(markers)
		out.Skipped = res.Skipped
		maps.Copy(out.UnknownRecords, res.Unknown)
		return out, nil
	}
	feed, err := sessionfeed.Build(convs, after, lookup)
	if err != nil {
		return out, err
	}
	if feed.Cursor.Conv != "" {
		out.Cursor = feed.Cursor.String()
	}
	out.Entries, out.Subagents = toSessionFeedEntries(feed.Entries), toSessionFeedEntries(feed.Subagents)
	out.Skipped = feed.Skipped
	maps.Copy(out.UnknownRecords, feed.Unknown)
	return out, nil
}

// sessionFeedConversations lists the tab's conversations in ledger order
// whose transcripts exist.
func sessionFeedConversations(ctx context.Context, database *db.DB, sess *db.TerminalSession) ([]sessionfeed.Conversation, error) {
	return sessionfeed.SessionConversations(ctx, database, sess.ID, agentkind.Kind(sess.Kind) == agentkind.Codex,
		sess.FolderPath, sess.TranscriptPath.String,
		sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentsClaudeDir(), "projects"), CodexHome: terminalCodexHome()})
}

// sessionFeedAskLookup resolves asks of the session's own workbench only.
// Reading never marks an ask delivered.
func sessionFeedAskLookup(database *db.DB, workbench sql.NullInt64) sessionfeed.AskLookup {
	if !workbench.Valid {
		return nil
	}
	return func(id int64) (string, string, bool) {
		a, err := database.GetOwnerAsk(workbench.Int64, id)
		if err != nil {
			return "", "", false
		}
		if a.Status != "answered" && a.Status != "delivered" {
			return a.Title, "", true
		}
		var payload asks.Payload
		if json.Unmarshal([]byte(a.Payload), &payload) != nil {
			return a.Title, "", true
		}
		answer, err := asks.ParseAnswer([]byte(a.Answer))
		if err == nil {
			err = asks.ValidateAnswer(a.Kind, payload, answer)
		}
		if err != nil {
			return a.Title, "", true
		}
		return a.Title, asks.Render(a.Kind, payload, answer), true
	}
}

const sessionFeedMaxSubagentDepth = 8

// sessionFeedSubagent finds the subagent started by tool call toolUseID in
// any conversation of the tab (or nested in another subagent) and returns
// its feed, nested markers resolved. A one-off drill-in: it parses every
// subagent on the way, correctness over speed.
func sessionFeedSubagent(convs []sessionfeed.Conversation, toolUseID string) (*sessionfeed.Result, error) {
	for _, c := range convs {
		feed, err := sessionfeed.Build([]sessionfeed.Conversation{c}, nil, nil)
		if err != nil {
			return nil, err
		}
		dir := strings.TrimSuffix(c.Path, ".jsonl")
		res, err := findSubagent(dir, feed.Entries, toolUseID, 0)
		if err != nil {
			return nil, err
		}
		if res != nil {
			return res, nil
		}
	}
	return nil, fmt.Errorf("subagent %s not found", toolUseID)
}

func findSubagent(sessionDir string, entries []sessionfeed.Entry, toolUseID string, depth int) (*sessionfeed.Result, error) {
	for _, e := range entries {
		ref := e.Subagent
		if e.Kind != sessionfeed.KindSubagent || ref == nil || ref.AgentID == "" {
			continue
		}
		match := ref.ToolUseID == toolUseID
		if !match && depth >= sessionFeedMaxSubagentDepth {
			continue
		}
		res, err := sessionfeed.ParseSubagent(filepath.Join(sessionDir, "subagents", "agent-"+ref.AgentID+".jsonl"), ref.ParentReport)
		if err != nil {
			if match {
				return nil, err
			}
			continue // an unreadable subagent file hides only its own nesting
		}
		sessionfeed.ResolveSubagents(sessionDir, res.Entries)
		if match {
			return res, nil
		}
		if found, err := findSubagent(sessionDir, res.Entries, toolUseID, depth+1); err != nil || found != nil {
			return found, err
		}
	}
	return nil, nil
}

func printSessionFeed(w io.Writer, entries []sessionFeedEntryJSON) {
	for _, e := range entries {
		at := "--:--"
		if !e.At.IsZero() {
			at = e.At.Local().Format("15:04")
		}
		switch e.Kind {
		case sessionfeed.KindSeparator:
			fmt.Fprintln(w, "── new conversation ──")
		case sessionfeed.KindBrief:
			fmt.Fprintf(w, "%s  Watchtower: brief\n", at)
		case sessionfeed.KindOwner:
			fmt.Fprintf(w, "%s  You:\n%s\n", at, indentFeedText(e.Text))
		case sessionfeed.KindAgent:
			fmt.Fprintf(w, "%s  Agent:\n%s\n", at, indentFeedText(e.Text))
		case sessionfeed.KindWatchtower:
			label := "Watchtower"
			if e.Via != "" {
				label += " (" + e.Via + ")"
			}
			fmt.Fprintf(w, "%s  %s:\n%s\n", at, label, indentFeedText(e.Text))
		case sessionfeed.KindAskAnswer:
			head := fmt.Sprintf("%s  Ask #%d answered", at, e.AskID)
			if e.Title != "" {
				head += " — " + e.Title
			}
			fmt.Fprintln(w, head)
			if e.Text != "" {
				fmt.Fprintln(w, indentFeedText(e.Text))
			}
		case sessionfeed.KindSubagent:
			if r := e.Subagent; r != nil {
				fmt.Fprintf(w, "%s  Subagent %s: %s [%s]\n", at, r.Type, r.Description, r.Status)
			}
		}
	}
}

func indentFeedText(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = "    " + l
		}
	}
	return strings.Join(lines, "\n")
}
