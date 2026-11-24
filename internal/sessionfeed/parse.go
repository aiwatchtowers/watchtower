package sessionfeed

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"watchtower/internal/agentfiles"
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
	reminderRe    = regexp.MustCompile(`(?s)<system-reminder>.*?</system-reminder>`)
	askRe         = regexp.MustCompile(`^Ask #(\d+) answered `)
	cmdNameRe     = regexp.MustCompile(`(?s)<command-name>(.*?)</command-name>`)
	taskChildRe   = regexp.MustCompile(`(?s)<([A-Za-z][\w-]*)>(.*?)</[A-Za-z][\w-]*>`)
	mateOpenRe    = regexp.MustCompile(`(?s)^<teammate-message\b([^>]*)>`)
	mateSummaryRe = regexp.MustCompile(`summary="([^"]*)"`)
	taskTokensRe  = regexp.MustCompile(`<subagent_tokens>\s*(\d+)\s*</subagent_tokens>`)
	taskUsesRe    = regexp.MustCompile(`<tool_uses>\s*(\d+)\s*</tool_uses>`)
	taskDurRe     = regexp.MustCompile(`<duration_ms>\s*(\d+)\s*</duration_ms>`)
	taskExitRe    = regexp.MustCompile(`\(exit code (-?\d+)\)$`)
	cmdArgsRe     = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
)

// ignoredTypes are record types that are expected and carry no chat.
var ignoredTypes = map[string]bool{
	"attachment": true, "system": true, "mode": true, "permission-mode": true,
	"file-history-snapshot": true, "ai-title": true, "last-prompt": true,
	"cost-state": true, "pr-link": true, "summary": true,
	"atis-latch": true, "frame-link": true, "queue-operation": true, "file-history-delta": true,
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
	IsError   bool            `json:"is_error"`
}

// recordPeerResults hands the tool_results of a user record to the peer tracker.
func (st *state) recordPeerResults(rec record, at time.Time) {
	var blocks []block
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	for _, b := range blocks {
		if b.Type == "tool_result" {
			st.peers.result(b.ToolUseID, resultText(b.Content), b.IsError, at)
		}
	}
}

// state is the mutable parse state of one pass over a transcript file.
type state struct {
	res       *Result
	conv      string
	byMsg     map[string]int // assistant message id -> index in res.Entries
	markers   map[string]int // Agent tool_use id -> index in res.Entries
	peers     peerTracker    // send_to_session / start_session calls and their results
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
	res := &Result{Offset: startOffset, Unknown: map[string]int{}}
	return &state{
		res:  res,
		conv: conv, byMsg: map[string]int{}, markers: map[string]int{}, peers: newPeerTracker(res, conv), sidechain: sidechain,
	}
}

// Lines are decoded in batches: the top-level JSON decode of a record is pure
// and most of a parse's cost, so a batch is decoded in parallel and then
// handled in file order. A batch is bounded in lines and bytes.
const (
	decodeBatchLines = 512
	decodeBatchBytes = 4 << 20
	minParallelLines = 64
)

// pendingLine is one read line: raw is nil for an over-long line.
type pendingLine struct {
	raw []byte
	n   int64
	rec record
	err error
}

func (st *state) run(r io.Reader, limit int) (*Result, error) {
	br := bufio.NewReaderSize(r, 64<<10)
	batch := make([]pendingLine, 0, decodeBatchLines)
	size := 0
	for {
		raw, n, complete, err := agentfiles.NextLine(br, limit)
		if complete {
			batch = append(batch, pendingLine{raw: raw, n: n})
			size += len(raw)
		}
		if !complete || len(batch) == decodeBatchLines || size >= decodeBatchBytes {
			st.handleBatch(batch)
			batch, size = batch[:0], 0
		}
		if !complete {
			if err != nil && !errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("reading transcript: %w", err)
			}
			return st.res, nil
		}
	}
}

// handleBatch decodes the batch's records, in parallel when it is large
// enough to pay for it, then handles them in order.
func (st *state) handleBatch(batch []pendingLine) {
	decode := func(ls []pendingLine) {
		for i := range ls {
			if ls[i].raw != nil {
				ls[i].err = json.Unmarshal(ls[i].raw, &ls[i].rec)
			}
		}
	}
	workers := min(runtime.GOMAXPROCS(0), len(batch)/minParallelLines)
	if workers < 2 {
		decode(batch)
	} else {
		var wg sync.WaitGroup
		per := (len(batch) + workers - 1) / workers
		for lo := 0; lo < len(batch); lo += per {
			part := batch[lo:min(lo+per, len(batch))]
			wg.Go(func() { decode(part) })
		}
		wg.Wait()
	}
	for i := range batch {
		l := &batch[i]
		st.res.Offset += l.n
		if l.raw == nil {
			st.res.Skipped++
		} else {
			st.handle(l.rec, l.err)
		}
		*l = pendingLine{} // drop the line's bytes once handled
	}
}

func (st *state) handle(rec record, decodeErr error) {
	res, conv := st.res, st.conv
	if decodeErr != nil {
		res.Unknown["<invalid>"]++
		return
	}
	at, _ := time.Parse(time.RFC3339Nano, rec.Timestamp)
	switch rec.Type {
	case "user":
		st.handleUser(rec, at)
	case "assistant":
		if rec.IsSidechain != st.sidechain {
			return
		}
		st.assistant(rec, at)
	case "attachment":
		if e, ok := st.queuedOwnerEntry(rec); ok {
			e.At, e.Conversation = at, conv
			res.Entries = append(res.Entries, e)
			return
		}
		if text, ok := briefText(rec.Attachment); ok {
			res.Entries = append(res.Entries, Entry{ID: rec.UUID, Kind: KindBrief, At: at, Text: text, Conversation: conv})
		}
	default:
		if !ignoredTypes[rec.Type] && !strings.HasPrefix(rec.Type, "api-request") && !strings.HasPrefix(rec.Type, "artifact-") {
			res.Unknown[rec.Type]++
		}
	}
}

// handleUser appends the owner-side entry of a user record, if it has one.
func (st *state) handleUser(rec record, at time.Time) {
	if rec.IsMeta || rec.IsCompact || rec.IsSidechain != st.sidechain {
		return
	}
	st.recordParentReport(rec)
	if !st.sidechain {
		st.recordPeerResults(rec, at)
	}
	if st.sidechain {
		// only the first plain-string record is the task
		var task string
		if st.hasTask || json.Unmarshal(rec.Message.Content, &task) != nil {
			return
		}
		st.hasTask = true
	}
	if e, ok := userEntry(rec); ok {
		e.At, e.Conversation = at, st.conv
		st.res.Entries = append(st.res.Entries, e)
	}
}

// queuedOwnerEntry turns a queued_command attachment (an owner line Claude
// Code took mid-turn; no user record is written for it) into the owner entry
// a user record would have produced. Other origins and meta records are not
// owner lines.
func (st *state) queuedOwnerEntry(rec record) (Entry, bool) {
	if rec.IsMeta || rec.IsSidechain != st.sidechain {
		return Entry{}, false
	}
	var att struct {
		Type        string `json:"type"`
		CommandMode string `json:"commandMode"`
		Origin      *struct {
			Kind string `json:"kind"`
		} `json:"origin"`
		IsMeta bool            `json:"isMeta"`
		Prompt json.RawMessage `json:"prompt"`
	}
	if json.Unmarshal(rec.Attachment, &att) != nil || att.Type != "queued_command" ||
		att.CommandMode != "prompt" || att.IsMeta || (att.Origin != nil && att.Origin.Kind != "human") {
		return Entry{}, false
	}
	text, ok := userText(att.Prompt)
	if !ok {
		return Entry{}, false
	}
	return classifyUserText(rec.UUID, text)
}

func userEntry(rec record) (Entry, bool) {
	text, ok := userText(rec.Message.Content)
	if !ok {
		return Entry{}, false
	}
	return classifyUserText(rec.UUID, text)
}

// userText flattens a user message's content; ok is false for tool results
// and undecodable content.
func userText(content json.RawMessage) (string, bool) {
	var text string
	if err := json.Unmarshal(content, &text); err == nil {
		return text, true
	}
	var blocks []block
	if json.Unmarshal(content, &blocks) != nil {
		return "", false
	}
	var parts []string
	hasImage := false
	for _, b := range blocks {
		switch b.Type {
		case "tool_result":
			return "", false
		case "text":
			parts = append(parts, b.Text)
		case "image":
			hasImage = true
		}
	}
	text = strings.Join(parts, "\n")
	if hasImage && !strings.Contains(text, "[Image #") {
		text += "\n[image]"
	}
	return text, true
}

func classifyUserText(uuid, text string) (Entry, bool) {
	text = strings.TrimSpace(reminderRe.ReplaceAllString(text, ""))
	if text == "" {
		return Entry{}, false
	}
	if strings.HasPrefix(text, "<task-notification>") || strings.HasPrefix(text, "<teammate-message") {
		return noticeEntry(uuid, text), true
	}
	e := Entry{ID: uuid, Kind: KindOwner, Text: text}
	if peer, body, ok := parsePeerLine(text); ok {
		e.Kind, e.Peer, e.Text = KindPeer, peer, body
		return e, true
	}
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

// maxEventTitleRunes caps an event title.
const maxEventTitleRunes = 200

// noticeEntry turns a Claude Code notice wrapper (a task notification or a
// teammate message) into an event entry.
func noticeEntry(uuid, text string) Entry {
	e := Entry{ID: uuid, Kind: KindEvent}
	if strings.HasPrefix(text, "<task-notification>") {
		e.EventType = EventTask
		var lines []string
		inner := strings.TrimSuffix(strings.TrimPrefix(text, "<task-notification>"), "</task-notification>")
		for _, m := range taskChildRe.FindAllStringSubmatch(inner, -1) {
			v := strings.TrimSpace(m[2])
			lines = append(lines, m[1]+": "+v)
			if m[1] == "summary" && e.Title == "" {
				e.Title = v
			}
		}
		e.Text = strings.Join(lines, "\n")
		e.Task = parseTaskNotification(text)
	} else {
		e.EventType = EventTeammate
		body := strings.TrimPrefix(text, "<teammate-message")
		if m := mateOpenRe.FindStringSubmatch(text); m != nil {
			e.Title = firstGroup(mateSummaryRe, m[1])
			body = text[len(m[0]):]
		}
		e.Text = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(body), "</teammate-message>"))
	}
	if e.Title == "" {
		e.Title = "Notice"
		for _, l := range strings.Split(e.Text, "\n") {
			if l = strings.TrimSpace(l); l != "" {
				e.Title = l
				break
			}
		}
	}
	if r := []rune(e.Title); len(r) > maxEventTitleRunes {
		e.Title = string(r[:maxEventTitleRunes])
	}
	return e
}

// taskReportBoilerplate starts the result of a notification whose agent
// report was delivered as a separate message; it says nothing itself.
var taskReportBoilerplate = []string{
	"This agent's report was delivered to you as a message",
	"This agent\u2019s report was delivered to you as a message",
}

// maxTaskCloseAttempts bounds the close tags one notification may try, so
// untrusted text with many repeated close tags parses in linear time.
const maxTaskCloseAttempts = 64

// taskChildren consumes the children of a notification from rest up to its
// closing tag, which it takes after the last child (a result may quote a whole
// notification, so a child's close is tried at each occurrence until the rest
// parses).
func taskChildren(rest string, kids map[string]string, budget *int) (map[string]string, bool) {
	rest = strings.TrimSpace(rest)
	if strings.HasPrefix(rest, taskClose) {
		return kids, true
	}
	if rest == "" || rest[0] != '<' {
		return nil, false
	}
	gt := strings.IndexByte(rest, '>')
	if gt < 2 {
		return nil, false
	}
	name := rest[1:gt]
	closeTag := "</" + name + ">"
	body := rest[gt+1:]
	for off := 0; ; {
		i := strings.Index(body[off:], closeTag)
		if i < 0 {
			return nil, false
		}
		i += off
		if *budget--; *budget < 0 {
			return nil, false // crafted text with many close tags: give up
		}
		next := maps.Clone(kids)
		if _, dup := next[name]; !dup {
			next[name] = strings.TrimSpace(body[:i])
		}
		if got, ok := taskChildren(body[i+len(closeTag):], next, budget); ok {
			return got, true
		}
		off = i + len(closeTag)
	}
}

const (
	taskOpen  = "<task-notification>"
	taskClose = "</task-notification>"
)

// hasTaskField reports whether a notification carries a child the agent-
// finished row shows; one with only unknown children is not a task.
func hasTaskField(kids map[string]string) bool {
	for _, k := range []string{"task-id", "tool-use-id", "status", "summary", "result"} {
		if _, ok := kids[k]; ok {
			return true
		}
	}
	return false
}

// parseTaskNotification reads the structured task from the notification at
// the start of text, up to its first closing tag (text after it, such as a
// "read the output file" line, is ignored). Every child must close with its
// own element name; a truncated or mismatched notification yields nil.
func parseTaskNotification(text string) *TaskRef {
	budget := maxTaskCloseAttempts
	kids, ok := taskChildren(text[len(taskOpen):], map[string]string{}, &budget)
	if !ok || !hasTaskField(kids) {
		return nil // nothing recognised: the title-only notice line
	}
	usage := kids["usage"]
	t := &TaskRef{
		TaskID: kids["task-id"], ToolUseID: kids["tool-use-id"], Status: kids["status"],
		Summary: kids["summary"], Result: kids["result"], OutputFile: kids["output-file"],
		Kind:       "agent",
		Tokens:     firstInt(taskTokensRe, usage),
		ToolUses:   firstInt(taskUsesRe, usage),
		DurationMS: firstInt(taskDurRe, usage),
	}
	for _, b := range taskReportBoilerplate {
		if strings.HasPrefix(t.Result, b) {
			t.Result = ""
		}
	}
	if strings.HasPrefix(t.Summary, "Background command") {
		t.Kind = "command"
		if m := taskExitRe.FindStringSubmatch(t.Summary); m != nil {
			if n, err := strconv.Atoi(m[1]); err == nil {
				t.ExitCode = &n
			}
		}
	}
	return t
}

func firstInt(re *regexp.Regexp, s string) int {
	if m := re.FindStringSubmatch(s); m != nil {
		if n, err := strconv.Atoi(m[1]); err == nil {
			return n
		}
	}
	return 0
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
	var peers []block
	for _, b := range blocks {
		switch {
		case b.Type == "text" && strings.TrimSpace(b.Text) != "":
			parts = append(parts, strings.TrimSpace(b.Text))
		case b.Type == "tool_use" && b.Name == "Agent":
			calls = append(calls, b)
		case b.Type == "tool_use" && !st.sidechain && isPeerTool(b.Name):
			peers = append(peers, b)
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
	for _, b := range peers {
		st.peers.call(b.ID, b.Name, b.Input, at)
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
