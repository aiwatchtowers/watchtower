package commands_test

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/inboxfeed/feedtest"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
	"watchtower/internal/tower/commands"
)

// benchSocket serves the gate fixture (2 000 outputs, 200 approvals, 500
// open items, 30 folders) on a real tower socket with every command
// registered, and returns a connected client.
func benchSocket(b *testing.B) *benchClient {
	b.Helper()
	now := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	d, err := db.Open(filepath.Join(b.TempDir(), "watchtower.db"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = d.Close() })
	if err := feedtest.SeedGate(d, now); err != nil {
		b.Fatal(err)
	}
	r := &tower.Registry{}
	commands.RegisterAll(r, commands.Deps{})
	tw := tower.New(d, tower.Options{Registry: r, Now: func() time.Time { return now }})
	// macOS limits a socket path to 104 bytes, which b.TempDir can exceed.
	dir, err := os.MkdirTemp("/tmp", "twb")
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = os.RemoveAll(dir) })
	stop, err := tower.Serve(context.Background(), filepath.Join(dir, "t.sock"), tw)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(stop)
	c, err := net.Dial("unix", filepath.Join(dir, "t.sock"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = c.Close() })
	return &benchClient{b: b, conn: c, r: bufio.NewReaderSize(c, 1<<20)}
}

type benchClient struct {
	b    *testing.B
	conn net.Conn
	r    *bufio.Reader
	seq  int
}

// call sends one request and reads its answer (one connection, one call at
// a time, as the Desktop's reads are).
func (c *benchClient) call(command string, params any) api.Response {
	c.b.Helper()
	c.seq++
	raw, err := json.Marshal(params)
	if err != nil {
		c.b.Fatal(err)
	}
	line, err := json.Marshal(api.Request{V: api.EnvelopeVersion, ID: fmt.Sprint(c.seq), Command: command, Params: raw})
	if err != nil {
		c.b.Fatal(err)
	}
	if _, err := c.conn.Write(append(line, '\n')); err != nil {
		c.b.Fatal(err)
	}
	answer, err := c.r.ReadBytes('\n')
	if err != nil {
		c.b.Fatal(err)
	}
	var resp api.Response
	if err := json.Unmarshal(answer, &resp); err != nil {
		c.b.Fatal(err)
	}
	if resp.Status != api.StatusOK {
		c.b.Fatalf("%s answered %+v", command, resp)
	}
	return resp
}

// BenchmarkSocketRoundTrip_InboxFeed is the Mac's read: inbox.feed with no
// options (no limit, no clip) over the socket, decoded as the client does.
// Gate: median ≤ 100 ms (spec §5.1).
func BenchmarkSocketRoundTrip_InboxFeed(b *testing.B) {
	c := benchSocket(b)
	b.ResetTimer()
	for b.Loop() {
		var feed api.Feed
		if err := json.Unmarshal(c.call("inbox.feed", api.FeedRequest{}).Result, &feed); err != nil {
			b.Fatal(err)
		}
		if len(feed.Cards) < feedtest.Outputs/2 {
			b.Fatalf("only %d cards", len(feed.Cards))
		}
	}
}

// BenchmarkSocketRoundTrip_Write is one write command over the socket:
// inbox.act read on an artifact card with its content_hash (the fixture's
// are empty, which the guard compares as is), each with a fresh request_id
// (one ledger row and one guarded write transaction per call). Gate: median
// ≤ 15 ms (spec §5.1).
func BenchmarkSocketRoundTrip_Write(b *testing.B) {
	c := benchSocket(b)
	var feed api.Feed
	if err := json.Unmarshal(c.call("inbox.feed", api.FeedRequest{}).Result, &feed); err != nil {
		b.Fatal(err)
	}
	var cards []api.Card
	for _, card := range feed.Cards {
		if card.CardKind == api.CardArtifact {
			cards = append(cards, card)
		}
	}
	if len(cards) == 0 {
		b.Fatal("no artifact card")
	}
	n := 0
	b.ResetTimer()
	for b.Loop() {
		card := cards[n%len(cards)]
		n++
		c.call("inbox.act", api.ActRequest{
			WriteParams: api.WriteParams{RequestID: fmt.Sprintf("00000000-0000-4000-8000-%012d", n)},
			Target:      card.ID, Verb: api.ActRead, Params: api.ActParams{ContentHash: card.ContentHash},
		})
	}
}
