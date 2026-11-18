package sessionfeed

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The fixed first lines internal/sessionmsg writes into a receiver's prompt.
// Only a line that STARTS with one is a peer line: a sender's own text that
// starts with a prefix was quoted with "> " by the sender's tool, so a quoted
// forgery never matches here.
var (
	peerMessageRe  = regexp.MustCompile(`^\[Message from #(\d+) “(.*)” · ([^\n]*?) — another agent of this workbench, not the owner\]\n?`)
	peerFinishedRe = regexp.MustCompile(`^\[Sub-session #(\d+) “(.*)” finished · ([^\n]*?)\] ?`)
	peerReplyRe    = regexp.MustCompile(`\n?\(Reply with send_to_session\(\d+, …\)\)\s*$`)
)

// parsePeerLine reports whether an owner-side text is another agent's
// message or a finished sub-session's summary, and returns its body.
func parsePeerLine(text string) (*PeerRef, string, bool) {
	if m := peerMessageRe.FindStringSubmatch(text); m != nil {
		body := strings.TrimSpace(peerReplyRe.ReplaceAllString(text[len(m[0]):], ""))
		return peerRef(PeerIn, PeerMessage, m), body, true
	}
	if m := peerFinishedRe.FindStringSubmatch(text); m != nil {
		return peerRef(PeerIn, PeerFinished, m), strings.TrimSpace(text[len(m[0]):]), true
	}
	return nil, "", false
}

func peerRef(dir, kind string, m []string) *PeerRef {
	id, _ := strconv.ParseInt(m[1], 10, 64)
	return &PeerRef{Direction: dir, Kind: kind, SessionID: id, Title: m[2], Folder: m[3]}
}

const (
	sendToSessionTool = "send_to_session"
	startSessionTool  = "start_session"
)

// isPeerTool matches the MCP tools by their bare name, whatever server
// prefix the agent registered them under.
func isPeerTool(name string) bool {
	return toolBase(name) == sendToSessionTool || toolBase(name) == startSessionTool
}

func toolBase(name string) string {
	if i := strings.LastIndex(name, "__"); i >= 0 {
		return name[i+2:]
	}
	return name
}

// maxPeerErrorRunes caps the reason a refused call shows.
const maxPeerErrorRunes = 200

// peerTracker turns the send_to_session / start_session calls of one pass
// into outgoing peer entries, and their results into the entry's outcome. A
// call is emitted at once under its tool-use id; its result updates the same
// entry in place, or — when the result is read in a later pass than the call —
// is emitted as an entry with that same id, which the store upserts.
type peerTracker struct {
	res   *Result
	conv  string
	calls map[string]int // tool-use id -> index in res.Entries
}

func newPeerTracker(res *Result, conv string) peerTracker {
	return peerTracker{res: res, conv: conv, calls: map[string]int{}}
}

// call adds the outgoing bubble of a peer tool call (once per id).
func (t *peerTracker) call(id, name string, input json.RawMessage, at time.Time) {
	if _, seen := t.calls[id]; seen || id == "" {
		return
	}
	e := Entry{ID: id, Kind: KindPeer, At: at, Conversation: t.conv}
	switch toolBase(name) {
	case sendToSessionTool:
		var in struct {
			SessionID int64  `json:"session_id"`
			Text      string `json:"text"`
		}
		if json.Unmarshal(input, &in) != nil || in.SessionID <= 0 {
			return
		}
		e.Text = strings.TrimSpace(in.Text)
		e.Peer = &PeerRef{Direction: PeerOut, Kind: PeerMessage, SessionID: in.SessionID}
	case startSessionTool:
		var in struct {
			Folder string `json:"folder"`
			Title  string `json:"title"`
		}
		if json.Unmarshal(input, &in) != nil {
			return
		}
		e.Peer = &PeerRef{Direction: PeerOut, Kind: PeerStarted, Title: strings.TrimSpace(in.Title), Folder: strings.TrimSpace(in.Folder)}
	default:
		return
	}
	t.calls[id] = len(t.res.Entries)
	t.res.Entries = append(t.res.Entries, e)
}

// result records the outcome of the call id: a refusal (isError) marks the
// bubble failed with the reason; a start_session answer fills the session id,
// folder and worktree. A start answer whose call was read in an earlier pass
// becomes its own entry under the call's id (title unknown: the reader that
// has the database names it).
func (t *peerTracker) result(id, text string, isError bool, at time.Time) {
	i, known := t.calls[id]
	if !known {
		var out startResult
		if isError || id == "" || !out.parse(text) {
			return
		}
		e := Entry{ID: id, Kind: KindPeer, At: at, Conversation: t.conv,
			Peer: &PeerRef{Direction: PeerOut, Kind: PeerStarted}}
		out.fill(e.Peer)
		t.calls[id] = len(t.res.Entries)
		t.res.Entries = append(t.res.Entries, e)
		return
	}
	p := t.res.Entries[i].Peer
	// Both tools answer with a JSON object; any other text is a refusal.
	if !strings.HasPrefix(strings.TrimSpace(text), "{") {
		isError = true
	}
	if isError {
		p.Error = peerReason(text)
		return
	}
	if p.Kind == PeerStarted {
		var out startResult
		if out.parse(text) {
			out.fill(p)
		}
	}
}

// startResult is start_session's JSON answer.
type startResult struct {
	SessionID int64  `json:"session_id"`
	Folder    string `json:"folder"`
	Place     string `json:"place"`
	Worktree  string `json:"worktree"`
}

// parse reads text as the answer; false when it is not one.
func (r *startResult) parse(text string) bool {
	return json.Unmarshal([]byte(text), r) == nil && r.SessionID > 0 && r.Place != ""
}

func (r startResult) fill(p *PeerRef) {
	p.SessionID, p.Worktree = r.SessionID, r.Worktree
	if r.Folder != "" {
		p.Folder = r.Folder
	}
}

// peerReason is the first line of a refusal, capped.
func peerReason(text string) string {
	text = strings.TrimSpace(text)
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = strings.TrimSpace(text[:i])
	}
	if text == "" {
		return "refused"
	}
	if r := []rune(text); len(r) > maxPeerErrorRunes {
		text = string(r[:maxPeerErrorRunes])
	}
	return text
}

// codexLine feeds a Codex rollout response_item payload (a function call or
// its output) to the tracker.
func (t *peerTracker) codexLine(raw json.RawMessage, at time.Time) {
	var p struct {
		Type      string          `json:"type"`
		Name      string          `json:"name"`
		Arguments string          `json:"arguments"`
		CallID    string          `json:"call_id"`
		Output    json.RawMessage `json:"output"`
	}
	if json.Unmarshal(raw, &p) != nil {
		return
	}
	switch p.Type {
	case "function_call":
		if isPeerTool(p.Name) {
			t.call(p.CallID, p.Name, json.RawMessage(p.Arguments), at)
		}
	case "function_call_output":
		text, isErr := codexOutputText(p.Output)
		t.result(p.CallID, text, isErr, at)
	}
}

// codexOutputText reads a function_call_output's output: a plain string, or an
// MCP result object {content:[{text}], isError}.
func codexOutputText(raw json.RawMessage) (string, bool) {
	var s string
	if json.Unmarshal(raw, &s) != nil {
		s = string(raw)
	}
	var obj struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal([]byte(s), &obj) == nil && len(obj.Content) > 0 {
		parts := make([]string, 0, len(obj.Content))
		for _, c := range obj.Content {
			parts = append(parts, c.Text)
		}
		return strings.Join(parts, "\n"), obj.IsError
	}
	return s, false
}
