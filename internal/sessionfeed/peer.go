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

// peerCall adds the outgoing bubble of a send_to_session or start_session
// tool_use (once per tool_use id).
func (st *state) peerCall(b block, at time.Time) {
	if b.ID == "" {
		return
	}
	for _, e := range st.res.Entries {
		if e.ID == b.ID {
			return
		}
	}
	e := Entry{ID: b.ID, Kind: KindPeer, At: at, Conversation: st.conv}
	switch toolBase(b.Name) {
	case sendToSessionTool:
		var in struct {
			SessionID int64  `json:"session_id"`
			Text      string `json:"text"`
		}
		if json.Unmarshal(b.Input, &in) != nil || in.SessionID <= 0 {
			return
		}
		e.Text = strings.TrimSpace(in.Text)
		e.Peer = &PeerRef{Direction: PeerOut, Kind: PeerMessage, SessionID: in.SessionID}
	default:
		var in struct {
			Folder string `json:"folder"`
			Title  string `json:"title"`
		}
		if json.Unmarshal(b.Input, &in) != nil {
			return
		}
		e.Peer = &PeerRef{Direction: PeerOut, Kind: PeerStarted, Title: strings.TrimSpace(in.Title), Folder: strings.TrimSpace(in.Folder)}
		st.peerCalls[b.ID] = len(st.res.Entries)
	}
	st.res.Entries = append(st.res.Entries, e)
}

// recordPeerResult fills a start_session bubble from its tool_result: the
// started session's id, the folder's stored name and its worktree. A result
// that is not the tool's JSON answer (an error) leaves the bubble as it was.
func (st *state) recordPeerResult(rec record) {
	var blocks []block
	if len(st.peerCalls) == 0 || json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return
	}
	for _, b := range blocks {
		i, ok := st.peerCalls[b.ToolUseID]
		if b.Type != "tool_result" || !ok {
			continue
		}
		var out struct {
			SessionID int64  `json:"session_id"`
			Folder    string `json:"folder"`
			Worktree  string `json:"worktree"`
		}
		if json.Unmarshal([]byte(resultText(b.Content)), &out) != nil || out.SessionID <= 0 {
			continue
		}
		p := st.res.Entries[i].Peer
		p.SessionID, p.Worktree = out.SessionID, out.Worktree
		if out.Folder != "" {
			p.Folder = out.Folder
		}
	}
}
