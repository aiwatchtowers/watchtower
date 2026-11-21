package sessionfeed

import (
	"path/filepath"
	"strings"
	"time"
)

// ReadOptions selects what ReadChat reads.
type ReadOptions struct {
	// After is the tab chat's cursor (nil reads it whole); a subagent is
	// always read whole.
	After *Cursor
	// Asks resolves the tab chat's ask answers (nil = none).
	Asks AskLookup
	// Subagent, when set, reads that subagent (its tool_use id, or
	// "codex:<id>") instead of the tab's chat.
	Subagent string
	// Now stamps the live snapshot.
	Now time.Time
	// LiveOf takes the live snapshot (nil = LiveOf); a caller bounds it
	// with its own deadline through this.
	LiveOf func(c Conversation, sidechain bool, now time.Time) (*Live, error)
}

// ChatRead is one read of a session's chat with its live snapshot: what
// `workbench session-feed --json` prints and the hub's session_chat slice
// publishes.
type ChatRead struct {
	// Feed is the tab's chat (no Subagent); Subagent the subagent's feed.
	Feed     *Feed
	Subagent *Result
	// LiveConv is the conversation the live snapshot reads (the tab's last
	// conversation, or the subagent's transcript), nil when there is none;
	// Sidechain says it is a Claude subagent's sidechain.
	LiveConv  *Conversation
	Sidechain bool
	// Live is the snapshot of LiveConv, nil with LiveErr when it failed.
	Live    *Live
	LiveErr error
	// Paths lists every file and directory read for the output (Feed.Paths'
	// meaning), live snapshot included: absolute, in first-read order,
	// without repeats, never nil.
	Paths []string
}

// ReadChat reads the tab's chat of convs, or one subagent's, and the live
// snapshot of the conversation it belongs to. Only the feed read fails it;
// a failed snapshot is LiveErr.
func ReadChat(convs []Conversation, o ReadOptions) (*ChatRead, error) {
	liveOf := o.LiveOf
	if liveOf == nil {
		liveOf = LiveOf
	}
	out := &ChatRead{}
	if o.Subagent != "" {
		res, path, reads, err := FindSubagentReads(convs, o.Subagent)
		if err != nil {
			return nil, err
		}
		codex := strings.HasPrefix(o.Subagent, "codex:")
		out.Subagent, out.Sidechain = res, !codex
		out.LiveConv = &Conversation{Path: path, Codex: codex, AgentSessionID: strings.TrimPrefix(o.Subagent, "codex:")}
		out.Live, out.LiveErr = liveOf(*out.LiveConv, out.Sidechain, o.Now)
		out.Paths = joinPaths([]string{path}, out.Live.Paths(), reads)
		return out, nil
	}
	feed, err := Build(convs, o.After, o.Asks)
	if err != nil {
		return nil, err
	}
	out.Feed = feed
	if len(convs) > 0 {
		last := convs[len(convs)-1]
		out.LiveConv = &last
		out.Live, out.LiveErr = liveOf(last, false, o.Now)
	}
	out.Paths = joinPaths(feed.Paths, out.Live.Paths())
	return out, nil
}

// joinPaths joins read lists in order, absolute and without repeats; never
// nil.
func joinPaths(lists ...[]string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, l := range lists {
		for _, p := range l {
			if abs, err := filepath.Abs(p); err == nil {
				p = abs
			}
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out
}
