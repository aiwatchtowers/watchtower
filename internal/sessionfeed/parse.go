package sessionfeed

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"runtime"
	"slices"
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
	mateOpenRe    = regexp.MustCompile(`(?s)^<teammate-message\b([^>]*)>`)
	mateSummaryRe = regexp.MustCompile(`summary="([^"]*)"`)
	taskTokensRe  = regexp.MustCompile(`<subagent_tokens>\s*(\d+)\s*</subagent_tokens>`)
	taskUsesRe    = regexp.MustCompile(`<tool_uses>\s*(\d+)\s*</tool_uses>`)
	taskDurRe     = regexp.MustCompile(`<duration_ms>\s*(\d+)\s*</duration_ms>`)
	taskExitRe    = regexp.MustCompile(`\(exit code (-?\d+)\)$`)
	cmdArgsRe     = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
	pastedOpenRe  = regexp.MustCompile(`<pasted_content id="([^"<>]*)">`)
)

// unwrapPasted replaces each <pasted_content id="X">…</pasted_content id="X">
// (Claude Code 2.1.312+ records a long paste so) with the pasted text, dropping
// the newline that follows the opening tag and the one before the closing tag,
// so the owner entry is the text the owner sent (a Workchat line finds its
// echo). The closing tag must carry the same id: pasted text that itself holds
// a closing tag stays whole. From an opening tag with no matching close on, the
// text is kept as is (a malformed record costs one scan, not one per tag).
func unwrapPasted(text string) string {
	var b strings.Builder
	for {
		loc := pastedOpenRe.FindStringSubmatchIndex(text)
		if loc == nil {
			break
		}
		closeTag := `</pasted_content id="` + text[loc[2]:loc[3]] + `">`
		end := strings.Index(text[loc[1]:], closeTag)
		if end < 0 {
			break
		}
		body := text[loc[1] : loc[1]+end]
		body = strings.TrimSuffix(strings.TrimPrefix(body, "\n"), "\n")
		b.WriteString(text[:loc[0]])
		b.WriteString(body)
		text = text[loc[1]+end+len(closeTag):]
	}
	b.WriteString(text)
	return b.String()
}

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

// recordPeerResults hands the tool_results of a user record's content blocks
// to the peer tracker.
func (st *state) recordPeerResults(blocks []block, at time.Time) {
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
	// one decode of the content for all three readers
	c, blocks, ok := decodeUserContent(rec.Message.Content)
	st.recordParentReport(blocks)
	if !st.sidechain {
		st.recordPeerResults(blocks, at)
	}
	if st.sidechain {
		// only the first plain-string record is the task
		var task string
		if st.hasTask || json.Unmarshal(rec.Message.Content, &task) != nil {
			return
		}
		st.hasTask = true
	}
	if !ok {
		return
	}
	for _, e := range contentEntries(rec.UUID, c) {
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
	if es := userEntries(rec); len(es) > 0 {
		return es[0], true
	}
	return Entry{}, false
}

// userEntries is the entries of a user record (contentEntries of its content).
func userEntries(rec record) []Entry {
	c, _, ok := decodeUserContent(rec.Message.Content)
	if !ok {
		return nil
	}
	return contentEntries(rec.UUID, c)
}

// contentEntries is the entries of a user message: one, except for a message
// whose text blocks are all notices (Claude Code delivers several task
// notifications or teammate messages as sibling blocks of one message), which
// gives one event per notice. The first keeps the record's uuid as its id, the
// others add `#<index of the content block>`, so each is stable across reads.
//
// A message that starts with a notice is an event of the notice alone (no
// image marker). Its blocks are read apart only when no system reminder
// crosses a block boundary (dropping reminders per block then gives the same
// text as dropping them from the joined message) and every notice is complete
// in its own block; otherwise it is the one notice read from the joined text.
func contentEntries(uuid string, c userContent) []Entry {
	joined := strings.Join(c.texts, "\n")
	if strings.Contains(joined, taskOpen) || strings.Contains(joined, mateOpen) {
		stripped := reminderRe.ReplaceAllString(joined, "")
		if text := strings.TrimSpace(stripped); isNotice(text) {
			if len(c.texts) > 1 {
				clean := make([]string, len(c.texts))
				for i, t := range c.texts {
					clean[i] = reminderRe.ReplaceAllString(t, "")
				}
				if strings.Join(clean, "\n") == stripped {
					if es := blockEntries(uuid, c.index, clean); len(es) > 0 {
						if c.image {
							es = es[:1] // an image beside the notices: one entry
						}
						return es
					}
				}
			}
			return []Entry{noticeEntry(uuid, text)}
		}
	}
	if e, ok := classifyUserText(uuid, c.marked(joined)); ok {
		return []Entry{e}
	}
	return nil
}

// blockEntries reads a message's text blocks (reminders already dropped, index
// = each one's place in the content) apart: every notice when all the non-empty
// blocks are notices, the leading notice alone when other text follows it, and
// nothing when the message does not start with a notice or a notice is not
// complete in its block (it may continue in the next one).
func blockEntries(uuid string, index []int, clean []string) []Entry {
	var out []Entry
	for i, text := range clean {
		text = strings.TrimSpace(text)
		switch {
		case text == "":
		case isNotice(text):
			kids, ok := noticeComplete(text)
			if !ok {
				return nil
			}
			id := uuid
			if len(out) > 0 {
				id = uuid + "#" + strconv.Itoa(index[i])
			}
			out = append(out, parsedNoticeEntry(id, text, kids, true))
		case len(out) > 0:
			return out[:1] // a notice beside other text: one entry
		default:
			return nil
		}
	}
	return out
}

const (
	mateOpen  = "<teammate-message"
	mateClose = "</teammate-message>"
)

func isNotice(text string) bool {
	return strings.HasPrefix(text, taskOpen) || strings.HasPrefix(text, mateOpen)
}

// noticeComplete reports whether a notice (trimmed) is whole within text: a
// task notification whose children parse (returned, so they are read once), a
// teammate message ending in its close tag (one quoted inside it is text).
func noticeComplete(text string) ([]taskChild, bool) {
	if strings.HasPrefix(text, taskOpen) {
		return parseTaskChildren(text)
	}
	return nil, strings.HasSuffix(text, mateClose)
}

// userContent is a user message's content decoded once: its text blocks with
// each one's index in the content (a plain string is one block), and whether
// an image block came with them.
type userContent struct {
	texts []string
	index []int
	image bool
}

// decodeUserContent decodes a user message's content once: its text content
// and its blocks (nil for a plain string). ok is false for tool results and
// undecodable content; the blocks decoded are returned either way.
func decodeUserContent(content json.RawMessage) (userContent, []block, bool) {
	if len(content) > 0 && content[0] == '"' {
		var text string
		if json.Unmarshal(content, &text) != nil {
			return userContent{}, nil, false
		}
		return userContent{texts: []string{text}, index: []int{0}}, nil, true
	}
	var blocks []block
	if json.Unmarshal(content, &blocks) != nil {
		return userContent{}, nil, false
	}
	var c userContent
	for i, b := range blocks {
		switch b.Type {
		case "tool_result":
			return userContent{}, blocks, false
		case "text":
			c.texts = append(c.texts, b.Text)
			c.index = append(c.index, i)
		case "image":
			c.image = true
		}
	}
	return c, blocks, true
}

// marked adds the image marker to the content's joined text when an image
// came with it and the text names none.
func (c userContent) marked(joined string) string {
	if c.image && !strings.Contains(joined, "[Image #") {
		joined += "\n[image]"
	}
	return joined
}

// userText flattens a user message's content; ok is false for tool results
// and undecodable content.
func userText(content json.RawMessage) (string, bool) {
	c, _, ok := decodeUserContent(content)
	if !ok {
		return "", false
	}
	return c.marked(strings.Join(c.texts, "\n")), true
}

func classifyUserText(uuid, text string) (Entry, bool) {
	text = strings.TrimSpace(reminderRe.ReplaceAllString(text, ""))
	if text == "" {
		return Entry{}, false
	}
	if isNotice(text) {
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
	default:
		// Unwrapped only now: a paste is the owner's text, never a notice or a command record.
		if e.Text = strings.TrimSpace(unwrapPasted(text)); e.Text == "" {
			return Entry{}, false
		}
	}
	return e, true
}

// maxEventTitleRunes caps an event title.
const maxEventTitleRunes = 200

// noticeEntry turns a Claude Code notice wrapper (a task notification or a
// teammate message) into an event entry.
func noticeEntry(uuid, text string) Entry {
	var kids []taskChild
	ok := false
	if strings.HasPrefix(text, taskOpen) {
		kids, ok = parseTaskChildren(text)
	}
	return parsedNoticeEntry(uuid, text, kids, ok)
}

// parsedNoticeEntry is noticeEntry with a task notification's children already
// read (ok: they parse); a teammate message ignores them.
func parsedNoticeEntry(uuid, text string, kids []taskChild, ok bool) Entry {
	e := Entry{ID: uuid, Kind: KindEvent}
	if strings.HasPrefix(text, taskOpen) {
		e.EventType = EventTask
		// The same element-name-matched children as the task: a child
		// quoting a close tag keeps its whole text. One that does not parse
		// keeps its own text, titled by a summary among its leading
		// complete children.
		if ok {
			lines := make([]string, 0, len(kids))
			for _, k := range kids {
				lines = append(lines, k.name+": "+k.value)
			}
			e.Text = strings.Join(lines, "\n")
			e.Task = taskRef(taskFields(kids))
		} else {
			kids = leadingTaskChildren(text[len(taskOpen):])
			e.Text = strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(text, taskOpen), taskClose))
		}
		e.Title = taskFields(kids)["summary"]
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

// taskChild is one child element of a notification.
type taskChild struct{ name, value string }

// taskChildren consumes the children of a notification from rest up to its
// closing tag, which it takes after the last child (a result may quote a whole
// notification, so a child's close is tried at each occurrence until the rest
// parses). The children come in document order. strict takes the
// notification's close only where closeEndsNotification says it ends it.
// Ambiguity: the first close accepted wins, so where several readings parse
// (a child quoting close tags) the shortest earlier child is taken —
// parseTaskChildren tries the strict reading first.
func taskChildren(rest string, kids []taskChild, budget *int, strict bool) ([]taskChild, bool) {
	rest = strings.TrimSpace(rest)
	if strings.HasPrefix(rest, taskClose) && (!strict || closeEndsNotification(rest[len(taskClose):])) {
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
		next := append(slices.Clip(kids), taskChild{name, strings.TrimSpace(body[:i])})
		if got, ok := taskChildren(body[i+len(closeTag):], next, budget, strict); ok {
			return got, true
		}
		off = i + len(closeTag)
	}
}

const (
	taskOpen  = "<task-notification>"
	taskClose = "</task-notification>"
)

// taskFields maps a notification's children by name, the first of a repeated
// name winning.
func taskFields(kids []taskChild) map[string]string {
	out := make(map[string]string, len(kids))
	for _, k := range kids {
		if _, dup := out[k.name]; !dup {
			out[k.name] = k.value
		}
	}
	return out
}

// hasTaskField reports whether a notification carries a child the agent-
// finished row shows; one with only unknown children is not a task.
func hasTaskField(kids map[string]string) bool {
	for _, k := range []string{"task-id", "tool-use-id", "status", "summary", "result", "output-file"} {
		if _, ok := kids[k]; ok {
			return true
		}
	}
	usage := kids["usage"] // only with a number in it
	return taskTokensRe.MatchString(usage) || taskUsesRe.MatchString(usage) || taskDurRe.MatchString(usage)
}

// closeEndsNotification reports whether a `</task-notification>` followed by
// after ends the notification: nothing follows, or the text after has no
// close of its own (a trailing "read the output file" line). A close followed
// by a later close is one quoted inside a child. It is used only on a text
// holding one top-level notification (oneTopLevelNotice); sibling
// notifications read as one text take the first close that parses.
func closeEndsNotification(after string) bool {
	after = strings.TrimSpace(after)
	return after == "" || !strings.Contains(after, taskClose)
}

// parseTaskChildren reads the children of the notification at the start of
// text, up to its closing tag (text after it, such as a "read the output
// file" line, is ignored). Every child must close
// with its own element name; a truncated or mismatched notification does not
// parse. The strict reading (closeEndsNotification: a result quoting a whole
// notification keeps the outer fields after it) is preferred, then the first
// that parses; each try is bounded by maxTaskCloseAttempts. A text holding
// sibling notifications (two complete ones joined, as main read them) skips the
// strict reading, so the first one's result does not run to the last close.
func parseTaskChildren(text string) ([]taskChild, bool) {
	readings := []bool{true, false}
	if !oneTopLevelNotice(text) {
		readings = readings[1:]
	}
	for _, strict := range readings {
		budget := maxTaskCloseAttempts
		if kids, ok := taskChildren(text[len(taskOpen):], nil, &budget, strict); ok {
			return kids, true
		}
	}
	return nil, false
}

// oneTopLevelNotice reports whether text holds one top-level notification:
// counting `<task-notification>` and `</task-notification>` as a nesting
// depth, no open follows a point where the depth is back to zero. A result
// quoting whole notifications nests them (the depth returns to zero only at
// the end); a sibling after the first close opens at depth zero. One pass.
func oneTopLevelNotice(text string) bool {
	depth, tops := 0, 0
	o := strings.Index(text, taskOpen)
	c := strings.Index(text, taskClose)
	for o >= 0 {
		if c >= 0 && c < o {
			depth--
			next := strings.Index(text[c+len(taskClose):], taskClose)
			if next < 0 {
				c = -1
			} else {
				c += len(taskClose) + next
			}
			continue
		}
		if depth <= 0 {
			if tops++; tops > 1 {
				return false
			}
			depth = 0
		}
		depth++
		next := strings.Index(text[o+len(taskOpen):], taskOpen)
		if next < 0 {
			o = -1
		} else {
			o += len(taskOpen) + next
		}
	}
	return true
}

// leadingTaskChildren is the complete children at the start of a notification
// that does not parse, stopping at the first one that is not. A child closes
// at the first of its close tags followed by markup or the end (a close tag
// quoted before prose is text), else at its first; at most
// maxTaskCloseAttempts close tags are tried in all.
func leadingTaskChildren(rest string) []taskChild {
	var kids []taskChild
	budget := maxTaskCloseAttempts
	for budget > 0 {
		rest = strings.TrimSpace(rest)
		gt := strings.IndexByte(rest, '>')
		if rest == "" || rest[0] != '<' || gt < 2 || rest[1] == '/' {
			break
		}
		closeTag := "</" + rest[1:gt] + ">"
		body := rest[gt+1:]
		end := -1
		for off := 0; budget > 0; {
			budget--
			i := strings.Index(body[off:], closeTag)
			if i < 0 {
				break
			}
			i += off
			if end < 0 {
				end = i // the first, unless a later one is followed by markup
			}
			if after := strings.TrimSpace(body[i+len(closeTag):]); after == "" || after[0] == '<' {
				end = i
				break
			}
			off = i + len(closeTag)
		}
		if end < 0 {
			break
		}
		kids = append(kids, taskChild{rest[1:gt], strings.TrimSpace(body[:end])})
		rest = body[end+len(closeTag):]
	}
	return kids
}

// taskRef is the task a notification's children describe, nil when none of
// them is a field the agent-finished row reads.
func taskRef(kids map[string]string) *TaskRef {
	if !hasTaskField(kids) {
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
