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
// conversations read so far with fresh status, even those before the cursor.
type Feed struct {
	Entries   []Entry
	Subagents []Entry
	Cursor    Cursor
	Skipped   int
	Unknown   map[string]int
}

// Build assembles the chat of the conversations in ledger order. With after,
// conversations before after.Conv are not emitted and that one starts at
// after.Offset; entries that changed since (a streamed message that grew)
// are re-emitted with their original ID, callers upsert by ID.
func Build(convs []Conversation, after *Cursor, asks AskLookup) (*Feed, error) {
	feed := &Feed{Unknown: map[string]int{}}
	if after != nil {
		feed.Cursor = *after
	}
	afterIdx := -1
	if after != nil {
		for i, c := range convs {
			if c.AgentSessionID == after.Conv {
				afterIdx = i
			}
		}
	}
	read := false // an earlier conversation was readable
	for i, c := range convs {
		full, err := parseFile(c, -1)
		if err != nil {
			return nil, err
		}
		if full == nil {
			continue
		}
		ResolveSubagents(strings.TrimSuffix(c.Path, ".jsonl"), full.Entries)
		for _, e := range full.Entries {
			if e.Kind == KindSubagent {
				feed.Subagents = append(feed.Subagents, e)
			}
		}
		start := int64(0)
		switch {
		case afterIdx >= 0 && i < afterIdx:
			read = true
			continue
		case afterIdx >= 0 && i == afterIdx:
			start = after.Offset
		}
		emit := full.Entries
		if start > 0 {
			prefix, err := parseFile(c, start)
			if err != nil {
				return nil, err
			}
			emit = changedSince(full.Entries, prefix.Entries)
		}
		if read && start == 0 {
			sep := Entry{ID: c.AgentSessionID + ":sep", Kind: KindSeparator, Conversation: c.AgentSessionID}
			if len(full.Entries) > 0 {
				sep.At = full.Entries[0].At
			}
			feed.Entries = append(feed.Entries, sep)
		}
		read = true
		feed.Entries = append(feed.Entries, emit...)
		feed.Cursor = Cursor{Conv: c.AgentSessionID, Offset: full.Offset}
		feed.Skipped += full.Skipped
		for k, n := range full.Unknown {
			feed.Unknown[k] += n
		}
	}
	if asks != nil {
		for i := range feed.Entries {
			e := &feed.Entries[i]
			if e.Kind != KindAskAnswer {
				continue
			}
			if title, text, ok := asks(e.AskID); ok {
				e.Title, e.Text = title, text
			}
		}
	}
	return feed, nil
}

// parseFile parses a conversation's transcript, up to limit bytes when
// limit >= 0. A missing or non-regular file yields nil, not an error.
func parseFile(c Conversation, limit int64) (*Result, error) {
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
	var r io.Reader = f
	if limit >= 0 {
		r = io.LimitReader(f, limit)
	}
	return Parse(r, 0, c.AgentSessionID)
}

// changedSince keeps the entries that are new or whose text differs from the
// same-ID entry parsed from the part the caller already has.
func changedSince(full, prefix []Entry) []Entry {
	seen := make(map[string]string, len(prefix))
	for _, e := range prefix {
		seen[e.ID] = e.Text
	}
	var out []Entry
	for _, e := range full {
		if text, ok := seen[e.ID]; !ok || text != e.Text {
			out = append(out, e)
		}
	}
	return out
}

// Locate finds the main transcript of agentSessionID under the Claude
// projects directory, searching the directories of folderRoots.
func Locate(projectsDir string, folderRoots []string, agentSessionID string) (string, bool) {
	dirs, err := agentlog.CandidateDirs(projectsDir, folderRoots)
	if err != nil {
		return "", false
	}
	files, err := agentlog.ListTranscripts(dirs)
	if err != nil {
		return "", false
	}
	for _, f := range files {
		if !f.Subagent && f.SessionUUID == agentSessionID {
			return f.Path, true
		}
	}
	return "", false
}
