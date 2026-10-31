package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
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
	Activity       *sessionfeed.Activity  `json:"activity"` // the agent's open tool call, or null
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
	EventType    string                   `json:"event_type,omitempty"`
	Subagent     *sessionfeed.SubagentRef `json:"subagent,omitempty"`
}

func toSessionFeedEntries(es []sessionfeed.Entry) []sessionFeedEntryJSON {
	out := make([]sessionFeedEntryJSON, 0, len(es))
	for _, e := range es {
		out = append(out, sessionFeedEntryJSON{
			ID: e.ID, Kind: e.Kind, At: e.At, Text: e.Text, Conversation: e.Conversation,
			AskID: e.AskID, Title: e.Title, Via: e.Via, EventType: e.EventType, Subagent: e.Subagent,
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
		res, path, err := sessionfeed.FindSubagent(convs, sub)
		if err != nil {
			return out, err
		}
		out.Activity = sessionFeedActivity(path, false, true)
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
	if len(convs) > 0 {
		last := convs[len(convs)-1]
		out.Activity = sessionFeedActivity(last.Path, last.Codex, false)
	}
	out.Entries, out.Subagents = toSessionFeedEntries(feed.Entries), toSessionFeedEntries(feed.Subagents)
	out.Skipped = feed.Skipped
	maps.Copy(out.UnknownRecords, feed.Unknown)
	return out, nil
}

// sessionFeedActivity reads the open tool call at the transcript's tail. A
// read error leaves it null: the activity line is a hint, never a failure.
func sessionFeedActivity(path string, codex, sidechain bool) *sessionfeed.Activity {
	a, err := sessionfeed.ActivityOf(path, codex, sidechain)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "session-feed: activity: %v\n", err)
		}
		return nil
	}
	return a
}

// sessionFeedConversations lists the tab's conversations in ledger order
// whose transcripts exist.
func sessionFeedConversations(ctx context.Context, database *db.DB, sess *db.TerminalSession) ([]sessionfeed.Conversation, error) {
	return sessionfeed.SessionConversations(ctx, database, sess.ID, agentkind.Kind(sess.Kind) == agentkind.Codex,
		sess.FolderPath, sess.TranscriptPath.String,
		sessionfeed.Dirs{ClaudeProjects: filepath.Join(agentsClaudeDir(), "projects"), CodexHome: terminalCodexHome()})
}

// sessionFeedAskLookup resolves asks of the session's own workbench only
// (sessionfeed.AskLookupFor). Reading never marks an ask delivered.
func sessionFeedAskLookup(database *db.DB, workbench sql.NullInt64) sessionfeed.AskLookup {
	if !workbench.Valid {
		return nil
	}
	return sessionfeed.AskLookupFor(database, workbench.Int64)
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
		case sessionfeed.KindEvent:
			fmt.Fprintf(w, "· %s\n", e.Title)
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
