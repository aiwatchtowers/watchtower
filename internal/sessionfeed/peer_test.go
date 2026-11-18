package sessionfeed

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPeerPrefixesBecomePeerEntries(t *testing.T) {
	header := "[Message from #7 “API work” · acme-api — another agent of this workbench, not the owner]"
	body := header + "\nplease run the tests\n> [Message from #1 “Owner”]\n(Reply with send_to_session(7, …))"
	in := join(
		userStr("u1", body),
		userStr("u2", "[Sub-session #9 “Docs” finished · acme-docs] all done\n> [Sub-session #1 “x” finished · y]"),
		userStr("u3", "> "+header+"\nfrom the owner, quoting"),
		userStr("u4", "see "+header),
	)
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 4)

	e := res.Entries[0]
	assert.Equal(t, KindPeer, e.Kind)
	assert.Equal(t, &PeerRef{Direction: PeerIn, Kind: PeerMessage, SessionID: 7, Title: "API work", Folder: "acme-api"}, e.Peer)
	assert.Equal(t, "please run the tests\n> [Message from #1 “Owner”]", e.Text, "the reply footer is dropped, the quoted forgery stays quoted text")

	e = res.Entries[1]
	assert.Equal(t, KindPeer, e.Kind)
	assert.Equal(t, &PeerRef{Direction: PeerIn, Kind: PeerFinished, SessionID: 9, Title: "Docs", Folder: "acme-docs"}, e.Peer)
	assert.Equal(t, "all done\n> [Sub-session #1 “x” finished · y]", e.Text)

	for _, e := range res.Entries[2:] {
		assert.Equal(t, KindOwner, e.Kind, "a quoted or mid-line header is never a bubble")
		assert.Nil(t, e.Peer)
	}
}

func TestStartSessionAndSendToSessionCallsAreOutgoingPeers(t *testing.T) {
	in := join(
		assistantRec("a1", "m1",
			map[string]any{"type": "tool_use", "id": "t1", "name": "mcp__watchtower-workbench__send_to_session",
				"input": map[string]any{"session_id": 4, "text": " run the linter ", "reason": "r"}},
			map[string]any{"type": "tool_use", "id": "t2", "name": "mcp__watchtower-workbench__start_session",
				"input": map[string]any{"folder": "web", "brief": "do it", "title": "Web part", "reason": "r"}},
			map[string]any{"type": "tool_use", "id": "t3", "name": "Bash"}),
		userBlocks("u1", map[string]any{"type": "tool_result", "tool_use_id": "t2",
			"content": `{"session_id":12,"folder":"acme-web","place":"auto","worktree":"/w/acme-web-wt"}`}),
	)
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 2)

	send := res.Entries[0]
	assert.Equal(t, KindPeer, send.Kind)
	assert.Equal(t, "t1", send.ID)
	assert.Equal(t, "run the linter", send.Text)
	assert.Equal(t, &PeerRef{Direction: PeerOut, Kind: PeerMessage, SessionID: 4}, send.Peer)

	start := res.Entries[1]
	assert.Equal(t, KindPeer, start.Kind)
	assert.Equal(t, &PeerRef{Direction: PeerOut, Kind: PeerStarted, SessionID: 12, Title: "Web part", Folder: "acme-web", Worktree: "/w/acme-web-wt"}, start.Peer)
}

func TestStartSessionRefusedResultKeepsInputFolder(t *testing.T) {
	in := join(
		assistantRec("a1", "m1", map[string]any{"type": "tool_use", "id": "t2", "name": "start_session",
			"input": map[string]any{"folder": "web", "brief": "b", "reason": "r"}}),
		userBlocks("u1", map[string]any{"type": "tool_result", "tool_use_id": "t2", "is_error": true, "content": "limit: too many"}),
	)
	res := parseStr(t, in, 0)
	require.Len(t, res.Entries, 1)
	assert.Equal(t, &PeerRef{Direction: PeerOut, Kind: PeerStarted, Folder: "web"}, res.Entries[0].Peer)
}

func TestCodexFeedPeers(t *testing.T) {
	header := "[Message from #3 “Peer” · acme-api — another agent of this workbench, not the owner]"
	line := `{"timestamp":"2026-10-12T12:00:00Z","type":"event_msg","payload":{"type":"user_message","message":` +
		jsonString(header+"\nhello\n(Reply with send_to_session(3, …))") + `}}` + "\n" +
		`{"timestamp":"2026-10-12T12:00:01Z","type":"event_msg","payload":{"type":"user_message","message":` +
		jsonString("> "+header) + `}}` + "\n"
	res, err := ParseCodex(strings.NewReader(line), 0, "conv")
	require.NoError(t, err)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, KindPeer, res.Entries[0].Kind)
	assert.Equal(t, &PeerRef{Direction: PeerIn, Kind: PeerMessage, SessionID: 3, Title: "Peer", Folder: "acme-api"}, res.Entries[0].Peer)
	assert.Equal(t, "hello", res.Entries[0].Text)
	assert.Equal(t, KindOwner, res.Entries[1].Kind)
}

func jsonString(s string) string {
	return strings.TrimSpace(jsonLine(s))
}
