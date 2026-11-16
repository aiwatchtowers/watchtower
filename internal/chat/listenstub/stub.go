// Package listenstub is a test stand-in for `watchtower ai session
// --listen`: a test binary whose TestMain sees Env set runs Main instead of
// its tests, so the chat engine's tests (and the daemon's) spawn, detach
// from and reattach to a real session process. Tests only.
//
// Its backend answers by the owner's text:
//   - "fifo:<path>": streams "partial answer ", then reads lines from the
//     FIFO at path — "text <s>" streams s ("text big:<n>" streams n bytes),
//     "step <id>" one finished tool step, "ack" writes a line to the FIFO
//     <path>.ack once everything before it was emitted, "done" (or EOF)
//     ends the turn complete (and acks when <path>.ack exists); a cancel
//     ends it interrupted.
//   - anything else: streams "echo: <text>" and ends complete.
package listenstub

import (
	"bufio"
	"context"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"watchtower/internal/chat"
	"watchtower/internal/ownerconfirm"
)

// Env turns a test binary into the stub.
const Env = "WATCHTOWER_LISTEN_STUB"

// Main runs the stub on the --listen path from os.Args and exits.
func Main() {
	path := ""
	for i, a := range os.Args {
		if a == "--listen" && i+1 < len(os.Args) {
			path = os.Args[i+1]
		}
	}
	if path == "" {
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()
	s := chat.NewSession(&backend{}, chat.NewEventWriter(os.Stdout))
	s.Provider, s.Model = "claude", "stub-model"
	err := chat.ServeListen(ctx, chat.ListenOptions{Path: path,
		// The peer's uid is checked by ServeListen; a test binary has no
		// signature to check.
		Verify: func(context.Context, ownerconfirm.PeerToken) error { return nil }}, s)
	stop()
	if err != nil {
		os.Exit(1)
	}
	os.Exit(0)
}

type backend struct {
	mu     sync.Mutex
	cancel chan struct{}
}

func (b *backend) Start(context.Context) (string, error) { return "stub-session", nil }
func (b *backend) Close() error                          { return nil }

func (b *backend) Cancel() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancel != nil {
		close(b.cancel)
		b.cancel = nil
	}
	return nil
}

func (b *backend) Turn(ctx context.Context, c chat.Command, emit func(chat.Event)) error {
	text := c.Text
	if _, rest, ok := strings.Cut(text, "]\n\n"); ok && strings.HasPrefix(text, "[Current time: ") {
		text = rest
	}
	fifo, ok := strings.CutPrefix(text, "fifo:")
	if !ok {
		emit(chat.Event{Type: chat.EventTextDelta, Text: "echo: " + text})
		emit(chat.Event{Type: chat.EventTurnDone, Status: chat.StatusComplete})
		return nil
	}
	cancelled := make(chan struct{})
	b.mu.Lock()
	b.cancel = cancelled
	b.mu.Unlock()
	emit(chat.Event{Type: chat.EventTextDelta, Text: "partial answer "})
	lines := make(chan string)
	go readFIFO(fifo, lines)
	for {
		select {
		case <-cancelled:
			emit(chat.Event{Type: chat.EventTurnDone, Status: chat.StatusInterrupted})
			return nil
		case <-ctx.Done():
			return ctx.Err()
		case line, open := <-lines:
			if !open || line == "done" {
				emit(chat.Event{Type: chat.EventTurnDone, Status: chat.StatusComplete})
				if _, err := os.Stat(fifo + ".ack"); err == nil {
					ack(fifo)
				}
				return nil
			}
			if line == "ack" {
				ack(fifo)
				continue
			}
			play(line, emit)
		}
	}
}

// play streams one FIFO line's events.
func play(line string, emit func(chat.Event)) {
	verb, arg, _ := strings.Cut(line, " ")
	switch verb {
	case "text":
		if n, err := strconv.Atoi(strings.TrimPrefix(arg, "big:")); err == nil && strings.HasPrefix(arg, "big:") {
			chunk := strings.Repeat("y", 16<<10)
			for sent := 0; sent < n; sent += len(chunk) {
				emit(chat.Event{Type: chat.EventTextDelta, Text: chunk[:min(len(chunk), n-sent)]})
			}
			return
		}
		emit(chat.Event{Type: chat.EventTextDelta, Text: arg})
	case "step":
		ok := true
		emit(chat.Event{Type: chat.EventToolStart, ID: arg, Name: "search_knowledge", Args: []byte(`{}`)})
		emit(chat.Event{Type: chat.EventToolEnd, ID: arg, OK: &ok, Summary: "found"})
	}
}

// ack tells the test that every event so far was emitted (kept in the
// turn buffer, sent to an attached engine).
func ack(fifo string) {
	f, err := os.OpenFile(fifo+".ack", os.O_WRONLY, 0)
	if err != nil {
		return
	}
	_, _ = f.WriteString("ok\n")
	_ = f.Close()
}

// readFIFO sends the FIFO's lines (its open waits for the test's writer).
func readFIFO(path string, out chan<- string) {
	defer close(out)
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		out <- sc.Text()
	}
}
