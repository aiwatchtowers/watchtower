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
	"watchtower/internal/sessionagent"
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
		"--tail N prints only the last N entries (--before ID: the N before entry ID; the output\n" +
		"carries before for the next older page); the cursor and the subagents list stay those of a\n" +
		"full read; --tail excludes --after and --subagent.\n" +
		"skipped and unknown_records count only what this call read. The database is opened read-only.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchSessionFeed,
}

var (
	workbenchSessionFeedFlagSession  int64
	workbenchSessionFeedFlagAfter    string
	workbenchSessionFeedFlagSubagent string
	workbenchSessionFeedFlagTail     int
	workbenchSessionFeedFlagBefore   string
	workbenchSessionFeedFlagJSON     bool
)

func init() {
	c := workbenchSessionFeedCmd
	fs := c.Flags()
	fs.Int64Var(&workbenchSessionFeedFlagSession, "session", 0, "terminal session id")
	fs.StringVar(&workbenchSessionFeedFlagAfter, "after", "", "cursor from a previous call: print only what follows")
	fs.StringVar(&workbenchSessionFeedFlagSubagent, "subagent", "", "tool_use id of a subagent: print its feed")
	fs.IntVar(&workbenchSessionFeedFlagTail, "tail", 0, "print only the last N entries (N >= 1)")
	fs.StringVar(&workbenchSessionFeedFlagBefore, "before", "", "with --tail: the page before this entry id")
	fs.BoolVar(&workbenchSessionFeedFlagJSON, "json", false, "output JSON")
	_ = c.MarkFlagRequired("session")
	c.MarkFlagsMutuallyExclusive("after", "subagent")
	c.MarkFlagsMutuallyExclusive("tail", "after")
	c.MarkFlagsMutuallyExclusive("tail", "subagent")
	workbenchCmd.AddCommand(c)
}

// sessionFeedJSON is the pinned output of `workbench session-feed --json`.
type sessionFeedJSON struct {
	SessionID      int64                         `json:"session_id"`
	Cursor         string                        `json:"cursor"`
	Entries        []sessionFeedEntryJSON        `json:"entries"`
	Activity       *sessionfeed.Activity         `json:"activity"` // the agent's open tool call, or null
	Live           *sessionfeed.Live             `json:"live"`
	LiveOK         bool                          `json:"live_ok"`
	LiveError      string                        `json:"live_error,omitempty"`
	Before         string                        `json:"before,omitempty"` // with --tail: id of the page's first entry, omitted at entry 0
	Subagents      []sessionFeedSubagentItemJSON `json:"subagents"`
	Skipped        int                           `json:"skipped"`
	UnknownRecords map[string]int                `json:"unknown_records"`
	// TranscriptDirs maps a Claude Code conversation to the directory of the
	// transcript read for it (the folder's or a worktree's project): Open
	// output reads an agent's output only from that project. Codex
	// conversations are absent; omitted when there are none and on a
	// --subagent read.
	TranscriptDirs map[string]string `json:"transcript_dirs,omitempty"`
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
	Peer         *sessionfeed.PeerRef     `json:"peer,omitempty"`
	Task         *sessionfeed.TaskRef     `json:"task,omitempty"`
}

func toSessionFeedEntries(es []sessionfeed.Entry) []sessionFeedEntryJSON {
	out := make([]sessionFeedEntryJSON, 0, len(es))
	for _, e := range es {
		out = append(out, sessionFeedEntryJSON{
			ID: e.ID, Kind: e.Kind, At: e.At, Text: e.Text, Conversation: e.Conversation,
			AskID: e.AskID, Title: e.Title, Via: e.Via, EventType: e.EventType, Subagent: e.Subagent, Peer: e.Peer, Task: e.Task,
		})
	}
	return out
}

// sessionFeedSubagentRefJSON is an entry's subagent object plus started_at;
// only `subagents` list items carry it (entries keep the five pinned keys).
type sessionFeedSubagentRefJSON struct {
	ToolUseID   string    `json:"tool_use_id"`
	AgentID     string    `json:"agent_id"`
	Type        string    `json:"type"`
	Description string    `json:"description"`
	Status      string    `json:"status"`
	StartedAt   time.Time `json:"started_at"`
}

// sessionFeedSubagentItemJSON is a `subagents` list item: the entry fields
// with the richer subagent object.
type sessionFeedSubagentItemJSON struct {
	sessionFeedEntryJSON
	Subagent *sessionFeedSubagentRefJSON `json:"subagent,omitempty"`
}

func toSessionFeedSubagentItems(es []sessionfeed.Entry) []sessionFeedSubagentItemJSON {
	out := make([]sessionFeedSubagentItemJSON, 0, len(es))
	for _, e := range es {
		item := sessionFeedSubagentItemJSON{sessionFeedEntryJSON: toSessionFeedEntries([]sessionfeed.Entry{e})[0]}
		item.sessionFeedEntryJSON.Subagent = nil
		if r := e.Subagent; r != nil {
			item.Subagent = &sessionFeedSubagentRefJSON{ToolUseID: r.ToolUseID, AgentID: r.AgentID, Type: r.Type,
				Description: r.Description, Status: r.Status, StartedAt: r.StartedAt}
		}
		out = append(out, item)
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
	tail := workbenchSessionFeedFlagTail
	if cmd.Flags().Changed("tail") && tail < 1 {
		return errors.New("--tail must be at least 1")
	}
	if workbenchSessionFeedFlagBefore != "" && !cmd.Flags().Changed("tail") {
		return errors.New("--before needs --tail")
	}
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

	sess, err := sessionagent.LoadSession(database, id)
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

	out, err := buildSessionFeedOutput(id, convs, after, lookup, workbenchSessionFeedFlagSubagent, tail, workbenchSessionFeedFlagBefore)
	if err != nil {
		return err
	}
	namePeers(ctx, database, out.Entries)
	w := cmd.OutOrStdout()
	if workbenchSessionFeedFlagJSON {
		return writeJSON(w, out)
	}
	printSessionFeed(w, out.Entries)
	return nil
}

// namePeers fills the title and folder of the outgoing peer entries that
// carry only the receiver's id (a send_to_session call): the receiver's row
// names them. A receiver that is gone, or a read that fails, leaves them
// empty and the entry renders with the id.
func namePeers(ctx context.Context, database *db.DB, entries []sessionFeedEntryJSON) {
	for _, e := range entries {
		p := e.Peer
		if p == nil || p.Direction != sessionfeed.PeerOut || p.SessionID <= 0 {
			continue
		}
		// A started sub-session read from its result alone has no title yet.
		if p.Kind == sessionfeed.PeerStarted && p.Title != "" {
			continue
		}
		if s, err := sessionagent.LoadSession(database, p.SessionID); err == nil {
			p.Title = s.Title
		}
		if p.Kind == sessionfeed.PeerStarted {
			continue
		}
		if fid, err := database.SessionFolderID(ctx, p.SessionID); err == nil {
			if f, err := database.WorkbenchFolderByID(ctx, fid); err == nil {
				p.Folder = f.Name
			}
		}
	}
}

// requireAgentSession refuses sessions the feed cannot read: shells.
func requireAgentSession(sess *db.TerminalSession) error {
	if !agentkind.IsAgent(sess.Kind) {
		return fmt.Errorf("session %d is not an agent session", sess.ID)
	}
	return nil
}

// buildSessionFeedOutput reads either one subagent's feed (sub set) or the
// tab's chat after the cursor.
func buildSessionFeedOutput(id int64, convs []sessionfeed.Conversation, after *sessionfeed.Cursor, lookup sessionfeed.AskLookup, sub string, tail int, before string) (sessionFeedJSON, error) {
	out := sessionFeedJSON{SessionID: id, Entries: []sessionFeedEntryJSON{}, Subagents: []sessionFeedSubagentItemJSON{}, UnknownRecords: map[string]int{}}
	if sub != "" {
		res, path, err := sessionfeed.FindSubagent(convs, sub)
		if err != nil {
			return out, err
		}
		codex := strings.HasPrefix(sub, "codex:")
		out.Activity = sessionFeedActivity(path, codex, !codex)
		setSessionFeedLive(&out, sessionfeed.Conversation{Path: path, Codex: codex, AgentSessionID: strings.TrimPrefix(sub, "codex:")}, !codex)
		var markers []sessionfeed.Entry
		for _, e := range res.Entries {
			if e.Kind == sessionfeed.KindSubagent {
				markers = append(markers, e)
			}
		}
		out.Entries, out.Subagents = toSessionFeedEntries(res.Entries), toSessionFeedSubagentItems(markers)
		out.Skipped = res.Skipped
		maps.Copy(out.UnknownRecords, res.Unknown)
		return out, nil
	}
	var feed *sessionfeed.Feed
	var err error
	if tail > 0 {
		feed, out.Before, err = sessionfeed.BuildTail(convs, after, lookup, before, tail)
	} else {
		feed, err = sessionfeed.Build(convs, after, lookup)
	}
	if err != nil {
		return out, err
	}
	out.TranscriptDirs = transcriptDirs(convs)
	if feed.Cursor.Conv != "" {
		out.Cursor = feed.Cursor.String()
	}
	if len(convs) > 0 {
		last := convs[len(convs)-1]
		out.Activity = sessionFeedActivity(last.Path, last.Codex, false)
		setSessionFeedLive(&out, last, false)
	}
	out.Entries, out.Subagents = toSessionFeedEntries(feed.Entries), toSessionFeedSubagentItems(feed.Subagents)
	out.Skipped = feed.Skipped
	maps.Copy(out.UnknownRecords, feed.Unknown)
	return out, nil
}

// transcriptDirs is the directory of each Claude Code conversation's
// transcript; nil when there is none.
func transcriptDirs(convs []sessionfeed.Conversation) map[string]string {
	var dirs map[string]string
	for _, c := range convs {
		if c.Codex || c.AgentSessionID == "" || c.Path == "" {
			continue
		}
		if dirs == nil {
			dirs = map[string]string{}
		}
		dirs[c.AgentSessionID] = filepath.Dir(c.Path)
	}
	return dirs
}

// The live hint has its own failure envelope: exit-0 feed reads must not
// silently leave a previous tool looking current when the hint failed.
func setSessionFeedLive(out *sessionFeedJSON, c sessionfeed.Conversation, sidechain bool) {
	live, err := sessionfeed.LiveOf(c, sidechain, time.Now())
	if err != nil {
		out.LiveError = "Activity unavailable"
		return
	}
	out.Live, out.LiveOK = live, true
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
	a, ok := sessionagent.Of(sess.Kind)
	if !ok {
		return nil, fmt.Errorf("session %d is not an agent session", sess.ID)
	}
	return a.Conversations(ctx, database, sess.ID, sess.FolderPath, sess.TranscriptPath.String,
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
		case sessionfeed.KindPeer:
			if p := e.Peer; p != nil {
				fmt.Fprintf(w, "%s  Peer %s %s #%d %s\n", at, p.Direction, p.Kind, p.SessionID, p.Title)
				if e.Text != "" {
					fmt.Fprintln(w, indentFeedText(e.Text))
				}
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
