package sessionfeed

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"watchtower/internal/agentlog"
)

// Conversation is one Claude Code conversation of a tab, in ledger order.
type Conversation struct {
	AgentSessionID, Path string
}

// Cursor marks how far a caller has read: a conversation and a byte offset
// into its transcript. Encoded "conv:offset".
type Cursor struct {
	Conv   string
	Offset int64
}

// ParseCursor decodes "conv:offset".
func ParseCursor(s string) (Cursor, error) {
	i := strings.LastIndex(s, ":")
	if i <= 0 {
		return Cursor{}, fmt.Errorf("bad cursor %q: want conv:offset", s)
	}
	off, err := strconv.ParseInt(s[i+1:], 10, 64)
	if err != nil || off < 0 {
		return Cursor{}, fmt.Errorf("bad cursor %q: offset must be a non-negative integer", s)
	}
	return Cursor{Conv: s[:i], Offset: off}, nil
}

func (c Cursor) String() string { return c.Conv + ":" + strconv.FormatInt(c.Offset, 10) }

// AskLookup resolves an owner ask of the session's own workbench to its title
// and rendered answer; ok is false when the ask is unknown.
type AskLookup func(id int64) (title, answerText string, ok bool)

// Feed is the result of Build. Subagents lists every subagent marker of all
// conversations given, with fresh status from the sidecar meta files, even
// those before the cursor. Skipped and Unknown count only what this call read.
type Feed struct {
	Entries   []Entry
	Subagents []Entry
	Cursor    Cursor
	Skipped   int
	Unknown   map[string]int
}

// Build assembles the chat of the conversations in ledger order. With after,
// conversations before after.Conv are not read, that one is read from
// after.Offset and later ones from 0. An entry whose record lies after the
// cursor is emitted with its original ID (a streamed message that grew);
// callers upsert by ID.
func Build(convs []Conversation, after *Cursor, asks AskLookup) (*Feed, error) {
	feed := &Feed{Unknown: map[string]int{}}
	if after != nil {
		feed.Cursor = *after
	}
	afterIdx := cursorIndex(convs, after)
	subIdx := map[string]int{} // marker id -> index in feed.Subagents
	addSubagents := func(es []Entry, parsed bool) {
		for _, e := range es {
			if e.Kind != KindSubagent {
				continue
			}
			if i, ok := subIdx[e.ID]; ok {
				if parsed {
					feed.Subagents[i] = e
				}
				continue
			}
			subIdx[e.ID] = len(feed.Subagents)
			feed.Subagents = append(feed.Subagents, e)
		}
	}
	read := false // an earlier conversation counts as read
	for i, c := range convs {
		sessionDir := strings.TrimSuffix(c.Path, ".jsonl")
		if afterIdx >= 0 && i < afterIdx {
			addSubagents(metaMarkers(sessionDir, c.AgentSessionID), false)
			read = true
			continue
		}
		start := int64(0)
		if i == afterIdx {
			start = after.Offset
		}
		res, err := parseFile(c, start)
		if err != nil {
			return nil, err
		}
		if res == nil {
			addSubagents(metaMarkers(sessionDir, c.AgentSessionID), false)
			continue
		}
		ResolveSubagents(sessionDir, res.Entries)
		addSubagents(res.Entries, true)
		addSubagents(metaMarkers(sessionDir, c.AgentSessionID), false)
		if read && start == 0 {
			feed.Entries = append(feed.Entries, separatorEntry(c.AgentSessionID, res.Entries))
		}
		read = true
		feed.Entries = append(feed.Entries, res.Entries...)
		feed.Cursor = Cursor{Conv: c.AgentSessionID, Offset: res.Offset}
		feed.Skipped += res.Skipped
		addCounts(feed.Unknown, res.Unknown)
	}
	fillAskAnswers(feed.Entries, asks)
	return feed, nil
}

// cursorIndex is the index of the conversation the cursor points into, or -1.
func cursorIndex(convs []Conversation, after *Cursor) int {
	if after == nil {
		return -1
	}
	idx := -1
	for i, c := range convs {
		if c.AgentSessionID == after.Conv {
			idx = i
		}
	}
	return idx
}

// fillAskAnswers replaces the title and text of ask-answer entries with the
// looked-up values, when the lookup knows the ask.
func fillAskAnswers(entries []Entry, asks AskLookup) {
	if asks == nil {
		return
	}
	for i := range entries {
		e := &entries[i]
		if e.Kind != KindAskAnswer {
			continue
		}
		if title, text, ok := asks(e.AskID); ok {
			e.Title, e.Text = title, text
		}
	}
}

// parseFile parses a conversation's transcript from byte offset start. A
// missing or non-regular file yields nil, not an error.
func parseFile(c Conversation, start int64) (*Result, error) {
	fi, err := os.Lstat(c.Path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && !fi.Mode().IsRegular()) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("transcript %s: %w", filepath.Base(c.Path), err)
	}
	f, err := os.Open(c.Path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("transcript %s: %w", filepath.Base(c.Path), err)
	}
	defer func() { _ = f.Close() }()
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil, fmt.Errorf("transcript %s: %w", filepath.Base(c.Path), err)
	}
	return Parse(f, start, c.AgentSessionID)
}

// LocateAll finds the main transcripts of agentSessionIDs under the Claude
// projects directory, searching the directories of folderRoots once. Ids
// without a transcript are absent from the result.
func LocateAll(projectsDir string, folderRoots []string, agentSessionIDs []string) map[string]string {
	found := map[string]string{}
	dirs, err := agentlog.CandidateDirs(projectsDir, folderRoots)
	if err != nil {
		return found
	}
	files, err := agentlog.ListTranscripts(dirs)
	if err != nil {
		return found
	}
	want := map[string]bool{}
	for _, id := range agentSessionIDs {
		want[id] = true
	}
	for _, f := range files {
		if _, dup := found[f.SessionUUID]; !f.Subagent && want[f.SessionUUID] && !dup {
			found[f.SessionUUID] = f.Path
		}
	}
	return found
}

// separatorEntry marks the start of a later conversation, timed by its first entry.
func separatorEntry(conv string, entries []Entry) Entry {
	sep := Entry{ID: conv + ":sep", Kind: KindSeparator, Conversation: conv}
	if len(entries) > 0 {
		sep.At = entries[0].At
	}
	return sep
}

func addCounts(dst, src map[string]int) {
	for k, n := range src {
		dst[k] += n
	}
}
