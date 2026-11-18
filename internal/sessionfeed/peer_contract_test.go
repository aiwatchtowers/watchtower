package sessionfeed_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/sessionmsg"
)

// TestPeerLinesMatchTheDeliverer parses what internal/sessionmsg really
// writes, so a change of its fixed formats fails here.
func TestPeerLinesMatchTheDeliverer(t *testing.T) {
	header := sessionmsg.Header(db.TerminalSession{ID: 7, Title: "API work"}, "acme-api")
	msg := sessionmsg.Body(7, header, "run it")
	fin := sessionmsg.FinishLine(9, "Docs", "acme-docs", "done")
	var in strings.Builder
	for i, text := range []string{msg, fin} {
		content, err := json.Marshal(text)
		require.NoError(t, err)
		in.WriteString(`{"type":"user","uuid":"u` + string(rune('1'+i)) + `","message":{"role":"user","content":` + string(content) + "}}\n")
	}
	res, err := sessionfeed.Parse(strings.NewReader(in.String()), 0, "c")
	require.NoError(t, err)
	require.Len(t, res.Entries, 2)
	assert.Equal(t, &sessionfeed.PeerRef{Direction: "in", Kind: "message", SessionID: 7, Title: "API work", Folder: "acme-api"}, res.Entries[0].Peer)
	assert.Equal(t, "run it", res.Entries[0].Text)
	assert.Equal(t, &sessionfeed.PeerRef{Direction: "in", Kind: "finished", SessionID: 9, Title: "Docs", Folder: "acme-docs"}, res.Entries[1].Peer)
	assert.Equal(t, "done", res.Entries[1].Text)
}
