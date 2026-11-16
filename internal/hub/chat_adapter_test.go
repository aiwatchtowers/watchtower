package hub

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/chat"
	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/policy"
)

// streamingSession is an in-process `ai session`: ready at once, it answers
// a turn with turn_start and one text delta and then holds the turn open
// until it is closed, cancelled or killed (no turn_done, no wall clock).
type streamingSession struct {
	text      string
	inR, outR *io.PipeReader
	inW, outW *io.PipeWriter
	exited    chan struct{}
	once      sync.Once
}

func startStreamingSession(text string) chatengine.StartFunc {
	return func([]string) (chatengine.Process, error) {
		p := &streamingSession{text: text, exited: make(chan struct{})}
		p.inR, p.inW = io.Pipe()
		p.outR, p.outW = io.Pipe()
		go p.run()
		return p, nil
	}
}

func (p *streamingSession) Stdin() io.Writer        { return p.inW }
func (p *streamingSession) Stdout() io.ReadCloser   { return p.outR }
func (p *streamingSession) PGID() int               { return 0 }
func (p *streamingSession) Terminate() error        { p.exit(); return nil }
func (p *streamingSession) Kill() error             { p.exit(); return nil }
func (p *streamingSession) Exited() <-chan struct{} { return p.exited }

func (p *streamingSession) exit() {
	p.once.Do(func() {
		_ = p.outW.Close()
		_ = p.inR.Close()
		close(p.exited)
	})
}

func (p *streamingSession) emit(ev chat.Event) bool {
	b, _ := json.Marshal(ev)
	_, err := p.outW.Write(append(b, '\n'))
	return err == nil
}

func (p *streamingSession) run() {
	defer p.exit()
	if !p.emit(chat.Event{Type: chat.EventSessionReady, SessionID: "sid-1", Provider: "claude", Model: "opus"}) {
		return
	}
	sc := bufio.NewScanner(p.inR)
	sc.Buffer(make([]byte, 0, 64<<10), 8<<20)
	for sc.Scan() {
		var c chat.Command
		if json.Unmarshal(sc.Bytes(), &c) != nil {
			continue
		}
		switch c.Type {
		case chat.CommandTurn:
			p.emit(chat.Event{Type: chat.EventTurnStart, TurnID: c.TurnID})
			p.emit(chat.Event{Type: chat.EventTextDelta, TurnID: c.TurnID, Text: p.text})
		case chat.CommandClose, chat.CommandCancel:
			return
		}
	}
}

// TestChatFeedSource_LiveTurnFromEngineEvents: the hub watches no chat_*
// table (this rig runs no data_version watch at all): the engine's
// OnChange publishes chat_feed, and the record, read from the engine,
// carries the running turn's text.
func TestChatFeedSource_LiveTurnFromEngineEvents(t *testing.T) {
	const live = "streaming answer from the engine"
	published := make(chan []hubslices.Kind, 1024)
	var eng *chatengine.Engine
	r := newChatRigWith(t, policy.MobileAllowed, transport.KindRelay, func(o *Options) {
		path, err := mainFile(context.Background(), o.DB)
		if err != nil {
			t.Fatal(err)
		}
		eng = chatengine.New(chatengine.Config{DBPath: path, Dir: t.TempDir(), DB: o.DB, Start: startStreamingSession(live)})
		if err := eng.Start(context.Background()); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = eng.Close(context.Background()) })
		o.ChatEngine = eng
		o.published = func(k []hubslices.Kind) {
			select {
			case published <- k:
			default: // the test reads what it needs; the rest may go
			}
		}
	})
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: "BBBBBBBB-0000-4000-8000-000000000002", Name: "p", Scope: "private", LinkedAt: r.now})
	}); err != nil {
		t.Fatal(err)
	}
	var feed hubslices.Source
	for _, s := range r.w.set.Sources {
		if s.Kind() == hubslices.KindChatFeed {
			feed = s
		}
	}
	if feed == nil {
		t.Fatal("no chat_feed source")
	}
	conv, err := eng.NewConversation(context.Background(), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	r.w.set.ChatWatches.Watch(conv, "open", r.now.Add(sources.ChatOpenWatch))
	for len(published) > 0 {
		<-published
	}
	if _, err := eng.Turn(context.Background(), chatengine.TurnRequest{StartRequest: chatstore.StartRequest{
		ConversationID: conv, Mode: chatstore.ModeSend, Text: "a question"}}); err != nil {
		t.Fatal(err)
	}
	for {
		kinds := <-published // the engine's changes: queued, started, the delta
		if !containsKind(kinds, hubslices.KindChatFeed) {
			continue
		}
		items, err := feed.Items(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if len(items) == 1 && strings.Contains(string(items[0].Payload), live) {
			return
		}
	}
}

func containsKind(kinds []hubslices.Kind, k hubslices.Kind) bool {
	for _, x := range kinds {
		if x == k {
			return true
		}
	}
	return false
}
