package sessionfeed

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlog"
)

const (
	maxLineBytes = 8 << 20
	handbackTool = "SubagentHandback"
)

const (
	reviewPrefix   = "Review round #"
	handoffPrefix  = "From a Watchtower code question:"
	briefPrefix    = "Watchtower workbench #"
	interruptStart = "[Request interrupted"
)

var (
	reminderRe = regexp.MustCompile(`(?s)<system-reminder>.*?</system-reminder>`)
	askRe      = regexp.MustCompile(`^Ask #(\d+) answered `)
	cmdNameRe  = regexp.MustCompile(`(?s)<command-name>(.*?)</command-name>`)
	cmdArgsRe  = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
)

// ignoredTypes are record types that are expected and carry no chat.
var ignoredTypes = map[string]bool{
	"attachment": true, "system": true, "mode": true, "permission-mode": true,
	"file-history-snapshot": true, "ai-title": true, "last-prompt": true,
	"cost-state": true, "pr-link": true, "summary": true,
}

type record struct {
	Type        string          `json:"type"`
	UUID        string          `json:"uuid"`
	Timestamp   string          `json:"timestamp"`
	IsMeta      bool            `json:"isMeta"`
	IsSidechain bool            `json:"isSidechain"`
	IsCompact   bool            `json:"isCompactSummary"`
	Attachment  json.RawMessage `json:"attachment"`
	Message     struct {
		ID      string          `json:"id"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type block struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
}

// state is the mutable parse state of one pass over a transcript file.
type state struct {
	res       *Result
	conv      string
	byMsg     map[string]int // assistant message id -> index in res.Entries
	markers   map[string]int // Agent tool_use id -> index in res.Entries
	sidechain bool           // reading a subagent file: its records are the feed
	hasTask   bool
	handback  string
}

// Parse reads complete lines from r (positioned at startOffset) and returns
// the chat entries they produce. A final line without '\n' is left for the
// next call; a bad line never fails the parse. conv is stamped on every entry.
func Parse(r io.Reader, startOffset int64, conv string) (*Result, error) {
	return parse(r, startOffset, conv, maxLineBytes)
}

func parse(r io.Reader, startOffset int64, conv string, limit int) (*Result, error) {
	st := newState(conv, startOffset, false)
	return st.run(r, limit)
}

func newState(conv string, startOffset int64, sidechain bool) *state {
	return &state{
		res:  &Result{Offset: startOffset, Unknown: map[string]int{}},
		conv: conv, byMsg: map[string]int{}, markers: map[string]int{}, sidechain: sidechain,
	}
}

func (st *state) run(r io.Reader, limit int) (*Result, error) {
	res := st.res
	br := bufio.NewReaderSize(r, 64<<10)
	for {
		raw, n, complete, err := agentlog.NextLine(br, limit)
		if !complete {
			if err != nil && !errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("reading transcript: %w", err)
			}
			break
		}
		res.Offset += n
		if raw == nil {
			res.Skipped++
		} else {
			st.handle(raw)
		}
	}
	return res, nil
}

func (st *state) handle(raw []byte) {
	res, conv := st.res, st.conv
	var rec record
	if err := json.Unmarshal(raw, &rec); err != nil {
		res.Unknown["<invalid>"]++
		return
	}
	at, _ := time.Parse(time.RFC3339Nano, rec.Timestamp)
	switch rec.Type {
	case "user":
		if rec.IsMeta || rec.IsCompact || rec.IsSidechain != st.sidechain {
			return
		}
		st.recordParentReport(rec)
		if st.sidechain {
			// only the first plain-string record is the task
			var task string
			if st.hasTask || json.Unmarshal(rec.Message.Content, &task) != nil {
				return
			}
			st.hasTask = true
		}
		if e, ok := userEntry(rec); ok {
			e.At, e.Conversation = at, conv
			res.Entries = append(res.Entries, e)
		}
	case "assistant":
		if rec.IsSidechain != st.sidechain {
			return
		}
		st.assistant(rec, at)
	case "attachment":
		if text, ok := briefText(rec.Attachment); ok {
			res.Entries = append(res.Entries, Entry{ID: rec.UUID, Kind: KindBrief, At: at, Text: text, Conversation: conv})
		}
	default:
		if !ignoredTypes[rec.Type] && !strings.HasPrefix(rec.Type, "api-request") {
			res.Unknown[rec.Type]++
		}
	}
}

func userEntry(rec record) (Entry, bool) {
	var text string
	if err := json.Unmarshal(rec.Message.Content, &text); err != nil {
		var blocks []block
		if json.Unmarshal(rec.Message.Content, &blocks) != nil {
			return Entry{}, false
		}
		var parts []string
		for _, b := range blocks {
			switch b.Type {
			case "tool_result":
				return Entry{}, false
			case "text":
				parts = append(parts, b.Text)
			case "image":
				parts = append(parts, "[image]")
			}
		}
		text = strings.Join(parts, "\n")
	}
	text = strings.TrimSpace(reminderRe.ReplaceAllString(text, ""))
	if text == "" {
		return Entry{}, false
	}
	e := Entry{ID: rec.UUID, Kind: KindOwner, Text: text}
	switch {
	case strings.HasPrefix(text, "<command-name>"):
		name := firstGroup(cmdNameRe, text)
		if name == "" {
			return Entry{}, false
		}
		e.Text = strings.TrimSpace(name + " " + firstGroup(cmdArgsRe, text))
	case strings.HasPrefix(text, "<local-command"), strings.HasPrefix(text, interruptStart):
		return Entry{}, false
	case askRe.MatchString(text):
		id, _ := strconv.ParseInt(askRe.FindStringSubmatch(text)[1], 10, 64)
		e.Kind, e.AskID = KindAskAnswer, id
	case strings.HasPrefix(text, reviewPrefix):
		e.Kind, e.Via = KindWatchtower, ViaReview
	case strings.HasPrefix(text, handoffPrefix):
		e.Kind, e.Via = KindWatchtower, ViaHandoff
	}
	return e, true
}

func firstGroup(re *regexp.Regexp, s string) string {
	if m := re.FindStringSubmatch(s); m != nil {
		return strings.TrimSpace(m[1])
	}
	return ""
}

func (st *state) assistant(rec record, at time.Time) {
	res, conv := st.res, st.conv
	var blocks []block
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	var parts []string
	var calls []block
	for _, b := range blocks {
		switch {
		case b.Type == "text" && strings.TrimSpace(b.Text) != "":
			parts = append(parts, strings.TrimSpace(b.Text))
		case b.Type == "tool_use" && b.Name == "Agent":
			calls = append(calls, b)
		case b.Type == "tool_use" && b.Name == handbackTool && st.sidechain:
			var in struct {
				Message string `json:"message"`
			}
			if json.Unmarshal(b.Input, &in) == nil {
				st.handback = in.Message
			}
		}
	}
	if len(parts) > 0 {
		text := strings.Join(parts, "\n\n")
		id := rec.Message.ID
		if id == "" {
			id = rec.UUID
		}
		if i, ok := st.byMsg[id]; ok {
			res.Entries[i].Text = text
		} else {
			st.byMsg[id] = len(res.Entries)
			res.Entries = append(res.Entries, Entry{ID: id, Kind: KindAgent, At: at, Text: text, Conversation: conv})
		}
	}
	for _, b := range calls {
		st.marker(b, at)
	}
}

func briefText(raw json.RawMessage) (string, bool) {
	var a struct {
		Type      string `json:"type"`
		HookEvent string `json:"hookEvent"`
		Stdout    string `json:"stdout"`
	}
	if json.Unmarshal(raw, &a) != nil || a.Type != "hook_success" || a.HookEvent != "SessionStart" {
		return "", false
	}
	if !strings.HasPrefix(a.Stdout, briefPrefix) {
		return "", false
	}
	return strings.TrimSpace(a.Stdout), true
}
