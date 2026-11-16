//go:build !race

package chatengine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// pageRig is an engine over a conversation of n messages, served on a real
// chat.sock with a connected app client, and chat_page's params for the
// page before its last message.
func pageRig(tb testing.TB, n int) (e *Engine, c *client, params json.RawMessage) {
	tb.Helper()
	d, err := db.Open(filepath.Join(tb.TempDir(), "w.db"))
	require.NoError(tb, err)
	tb.Cleanup(func() { _ = d.Close() })
	e = New(Config{Exe: "/opt/watchtower", DBPath: "/data/watchtower.db", Dir: tb.TempDir(), DB: d,
		Start: (&fakeStarter{}).start})
	tb.Cleanup(func() { _ = e.Close(context.Background()) })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(tb, err)
	conv, _ := res.LastInsertId()
	var parent any
	for i := range n {
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, parent_id, status)
			VALUES (?, 'user', ?, ?, ?, 'complete')`, conv, "message "+strconv.Itoa(i), i+1, parent)
		require.NoError(tb, err)
		parent, _ = res.LastInsertId()
	}
	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, parent, conv)
	require.NoError(tb, err)
	c = dialSocket(tb, serveSocket(tb, e, appOnly))
	c.hello()
	return e, c, json.RawMessage(fmt.Sprintf(`{"conversation_id":%d,"before_message_id":%d}`, conv, parent))
}

func pageInProcess(tb testing.TB, e *Engine, params json.RawMessage) {
	if _, err := e.Do(context.Background(), "chat_page", params, Client{Kind: "mac"}); err != nil {
		tb.Fatal(err)
	}
}

// pageOverSocket sends chat_page and reads its answer line; the answer is
// checked by its head only, so the timing is the transport and the
// server's framing, not this client's JSON decoder.
func pageOverSocket(tb testing.TB, c *client, id int, params json.RawMessage) {
	c.send(strconv.Itoa(id), "chat_page", params)
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		tb.Fatal(err)
	}
	if head := `{"id":"` + strconv.Itoa(id) + `","ok":true`; !bytes.HasPrefix(line, []byte(head)) {
		tb.Fatalf("chat_page answer: %.200s", line)
	}
}

// medians times a and b n times each, interleaved (so load moves both),
// after a warm-up, and returns each one's median.
func medians(n int, a, b func()) (ma, mb time.Duration) {
	for range 20 {
		a()
		b()
	}
	da, db := make([]time.Duration, n), make([]time.Duration, n)
	for i := range n {
		start := time.Now()
		a()
		da[i] = time.Since(start)
		start = time.Now()
		b()
		db[i] = time.Since(start)
	}
	slices.Sort(da)
	slices.Sort(db)
	return da[n/2], db[n/2]
}

// TestChatengine_SocketLatencyWithinTwiceInProcess: a chat_page (60
// messages) over chat.sock — encode, socket, decode both ways — takes at
// most twice the same operation called in process. Relative, so machine
// load moves both sides; outside -race only.
func TestChatengine_SocketLatencyWithinTwiceInProcess(t *testing.T) {
	e, c, params := pageRig(t, 80)
	i := 0
	direct, socket := medians(300, func() { pageInProcess(t, e, params) },
		func() { i++; pageOverSocket(t, c, i, params) })
	t.Logf("chat_page median: in process %s, over chat.sock %s", direct, socket)
	if socket > 2*direct {
		t.Errorf("over chat.sock %s, more than twice in process (%s)", socket, direct)
	}
}

func BenchmarkChatengine_PageInProcess(b *testing.B) {
	e, _, params := pageRig(b, 80)
	for b.Loop() {
		pageInProcess(b, e, params)
	}
}

func BenchmarkChatengine_PageOverSocket(b *testing.B) {
	_, c, params := pageRig(b, 80)
	i := 0
	for b.Loop() {
		i++
		pageOverSocket(b, c, i, params)
	}
}
