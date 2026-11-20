package sources

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionfeed"
)

// The session chat's file-event reads (#2112 Task 4): every test but the
// real-watcher ones runs in a synctest bubble over a fake watcher, its loop
// driven by bubble time.

// fakeWatcher is a FileWatcher that holds paths and delivers what the test
// fires. Add of a missing file fails like fsnotify's; addErr fails every Add
// of an existing one.
type fakeWatcher struct {
	mu     sync.Mutex
	paths  map[string]bool
	events chan string
	errs   chan error
	closed bool
	addErr error
	// failAdd > 0 fails the failAdd-th Add of an existing file.
	failAdd, adds int
}

func (f *fakeWatcher) Add(p string) error {
	if _, err := os.Lstat(p); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.adds++
	if f.addErr != nil {
		return f.addErr
	}
	if f.failAdd > 0 && f.adds == f.failAdd {
		return errors.New("too many open files")
	}
	f.paths[p] = true
	return nil
}

func (f *fakeWatcher) Remove(p string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.paths, p)
	return nil
}

func (f *fakeWatcher) Events() <-chan string { return f.events }
func (f *fakeWatcher) Errors() <-chan error  { return f.errs }

func (f *fakeWatcher) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.closed {
		f.closed = true
		close(f.events)
		close(f.errs)
	}
	return nil
}

func (f *fakeWatcher) watched() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for p := range f.paths {
		out = append(out, p)
	}
	slices.Sort(out)
	return out
}

func (f *fakeWatcher) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// filesRig is a live session 7 whose conversation c1 is dir/conv.jsonl,
// read by a fake fetch that lists the files that exist and the live block
// the test sets. An agent record (tool use toolu_1) reads agent a1's
// transcript.
type filesRig struct {
	t       *testing.T
	dir     string
	conv    string
	watches *handlers.ChatWatchRegistry
	mu      sync.Mutex
	reads   map[string]int // by tool use id ("" = the main feed)
	// convs is what the full resolve finds, ids the session's agent-session
	// ids; resolves counts full resolves, resolveErr fails them.
	convs      []sessionfeed.Conversation
	ids        []string
	resolves   int
	resolveErr error
	// live is the main feed's live block (nil = none); liveErr fails it.
	live     func() *sessionfeed.Live
	liveErr  bool
	fetchErr error
	isLive   bool
	active   bool
	addErr   error
	watchers []*fakeWatcher
	// block, when set, holds every read after the first until it is closed.
	block chan struct{}
	s     *SessionChatSource
}

func newFilesRig(t *testing.T) *filesRig {
	dir := t.TempDir()
	r := &filesRig{t: t, dir: dir, conv: touch(t, dir, "conv.jsonl"), watches: handlers.NewChatWatchRegistry(),
		reads: map[string]int{}, isLive: true, active: true, ids: []string{"c1"}}
	r.convs = []sessionfeed.Conversation{{AgentSessionID: "c1", Path: r.conv}}
	return r
}

func touch(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func (r *filesRig) set(f func()) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f()
}

func (r *filesRig) options() SessionChatOptions {
	return SessionChatOptions{
		Fetch: func(ctx context.Context, id int64, toolUseID string) (ChatRead, error) {
			r.mu.Lock()
			r.reads[toolUseID]++
			n, block, liveFn, liveErr := r.reads[toolUseID], r.block, r.live, r.liveErr
			var paths []string
			for _, c := range r.convs {
				paths = append(paths, c.Path)
			}
			r.mu.Unlock()
			if block != nil && n > 1 {
				select {
				case <-block:
				case <-ctx.Done():
					return ChatRead{}, ctx.Err()
				}
			}
			r.mu.Lock()
			fetchErr := r.fetchErr
			r.mu.Unlock()
			if fetchErr != nil && toolUseID == "" {
				return ChatRead{}, fetchErr
			}
			if toolUseID != "" {
				if p := r.agentPath("a1"); exists(p) {
					return ChatRead{Entries: []sessionfeed.Entry{feedEntry(n, "agent")}, Paths: []string{p}}, nil
				}
				return ChatRead{}, errors.New("no sidechain yet")
			}
			read := ChatRead{Entries: []sessionfeed.Entry{feedEntry(n, "read")}}
			if liveErr {
				read.LiveErr = errors.New("live read failed")
			} else if liveFn != nil {
				read.Live = liveFn()
				for _, a := range read.Live.Agents {
					if p := r.agentPath(a.Ref.AgentID); a.Ref.AgentID != "" && exists(p) {
						paths = append(paths, p)
					}
				}
			}
			read.Paths = paths
			return read, nil
		},
		Conversations: func(context.Context, int64) ([]sessionfeed.Conversation, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.resolves++
			if r.resolveErr != nil {
				return nil, r.resolveErr
			}
			var out []sessionfeed.Conversation
			for _, c := range r.convs {
				if exists(c.Path) { // SessionConversations lists only existing files
					out = append(out, c)
				}
			}
			return out, nil
		},
		AgentSessions: func(context.Context, int64) ([]string, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			return slices.Clone(r.ids), nil
		},
		NewWatcher: func() (FileWatcher, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			w := &fakeWatcher{paths: map[string]bool{}, events: make(chan string, 256), errs: make(chan error, 1), addErr: r.addErr}
			r.watchers = append(r.watchers, w)
			return w, nil
		},
		Liveness: func() Liveness {
			r.mu.Lock()
			defer r.mu.Unlock()
			if !r.isLive {
				return Liveness{}
			}
			return Liveness{Runs: map[int64]time.Time{7: time.Now()}}
		},
		Active: func() bool {
			r.mu.Lock()
			defer r.mu.Unlock()
			return r.active
		},
	}
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

func (r *filesRig) agentPath(id string) string {
	return filepath.Join(r.dir, "conv", "subagents", "agent-"+id+".jsonl")
}

// runningAgent is a live block listing agent id (empty: its sidecar, which
// names it, is not written yet) with status.
func runningAgent(id, status string) *sessionfeed.Live {
	return &sessionfeed.Live{TurnActive: true, AgentsState: "known", Agents: []sessionfeed.LiveAgent{{
		Ref: sessionfeed.SubagentRef{AgentID: id, ToolUseID: "toolu_1", Type: "Explore", Status: status},
	}}}
}

// start runs the source's loop (stopped at the test's end) and opens the
// phone's watch of session 7 the way session_chat_request does.
func (r *filesRig) start() {
	r.s = SessionChat(r.watches, nil, r.options())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.s.Run(ctx) }()
	r.t.Cleanup(func() { cancel(); <-done })
	synctest.Wait()
	r.request("")
}

// request is the phone's session_chat_request for the main feed ("") or
// the agent record of toolUseID.
func (r *filesRig) request(toolUseID string) {
	cw := handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)}
	if toolUseID != "" {
		cw.AgentID, cw.ToolUseID = "a1", toolUseID
	}
	r.s.RequestWatches().Watch(cw)
	synctest.Wait()
}

func (r *filesRig) readCount() int { return r.readsOf("") }

func (r *filesRig) readsOf(toolUseID string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.reads[toolUseID]
}

func (r *filesRig) resolveCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.resolves
}

func (r *filesRig) watcher() *fakeWatcher {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.watchers) == 0 {
		return nil
	}
	return r.watchers[len(r.watchers)-1]
}

func (r *filesRig) fire(p string) {
	r.t.Helper()
	w := r.watcher()
	if w == nil {
		r.t.Fatal("no watcher to fire")
	}
	w.events <- p
	synctest.Wait()
}

func (r *filesRig) sleep(d time.Duration) {
	time.Sleep(d)
	synctest.Wait()
}

func (r *filesRig) wantReads(n int, when string) {
	r.t.Helper()
	if got := r.readCount(); got != n {
		r.t.Fatalf("%s: %d reads, want %d", when, got, n)
	}
}

func (r *filesRig) wantWatched(when string, want ...string) {
	r.t.Helper()
	w := r.watcher()
	var got []string
	if w != nil && !w.isClosed() {
		got = w.watched()
	}
	slices.Sort(want)
	if !slices.Equal(got, want) {
		r.t.Fatalf("%s: watching %v, want %v", when, got, want)
	}
}

func TestChatFiles_EventReadsAfterDebounce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.wantReads(1, "the open read")
		r.wantWatched("after the open read", r.conv)
		r.sleep(5 * time.Second)
		r.fire(r.conv)
		r.sleep(249 * time.Millisecond)
		r.wantReads(1, "249 ms after the event")
		r.sleep(time.Millisecond)
		r.wantReads(2, "250 ms after the event")
		r.sleep(10 * time.Second)
		r.wantReads(2, "10 s later")
	})
}

func TestChatFiles_BurstCapsReads(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(5 * time.Second)
		for range 100 { // 100 events in 500 ms
			r.fire(r.conv)
			r.sleep(5 * time.Millisecond)
		}
		r.sleep(5 * time.Second)
		r.wantReads(2, "after 100 events in 500 ms")

		for range 60 { // an event every 50 ms for 3 s
			r.fire(r.conv)
			r.sleep(50 * time.Millisecond)
		}
		burst := r.readCount() - 2
		r.sleep(10 * time.Second)
		after := r.readCount() - 2
		if after < 3 || after > 4 {
			t.Fatalf("events every 50 ms for 3 s: %d reads, want 3–4", after)
		}
		if after-burst > 1 {
			t.Fatalf("%d reads after the burst ended, want at most the trailing one", after-burst)
		}
	})
}

// An idle live chat costs no read and no full resolve: the Wake loop only
// lists the agent-session ids.
func TestChatFiles_NoEventNoRead(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(60 * time.Second)
		r.wantReads(1, "a live chat with no event for 60 s")
		if n := r.resolveCount(); n != 1 {
			t.Fatalf("%d full resolves in 60 idle seconds, want the first only", n)
		}
	})
}

func TestChatFiles_RenameReresolves(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(5 * time.Second)
		renamed := filepath.Join(r.dir, "renamed.jsonl")
		if err := os.Rename(r.conv, renamed); err != nil {
			t.Fatal(err)
		}
		r.set(func() { r.convs = []sessionfeed.Conversation{{AgentSessionID: "c1", Path: renamed}} })
		r.fire(r.conv)
		r.wantReads(2, "right after the rename")
		r.wantWatched("after the rename", renamed)
		r.sleep(5 * time.Second)
		r.wantReads(2, "after the rename's read")
		r.fire(renamed)
		r.sleep(250 * time.Millisecond)
		r.wantReads(3, "a write to the renamed file")
	})
}

func TestChatFiles_NewConversationOnWake(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(time.Second)
		next := touch(t, r.dir, "next.jsonl")
		r.set(func() {
			r.ids = []string{"c1", "c2"}
			r.convs = append(r.convs, sessionfeed.Conversation{AgentSessionID: "c2", Path: next})
		})
		r.sleep(time.Second) // the Wake tick, 2 s after the open
		r.wantReads(2, "one Wake after the new conversation")
		r.wantWatched("after the new conversation", r.conv, next)
		r.sleep(30 * time.Second)
		r.wantReads(2, "30 s later")
		if n := r.resolveCount(); n != 2 {
			t.Fatalf("%d full resolves, want 2 (the open, the new id)", n)
		}
		r.fire(next)
		r.sleep(250 * time.Millisecond)
		r.wantReads(3, "a write to the new conversation")
	})
}

// The real order: the Agent call lands in the main transcript (one event),
// the agent's id is known only once its sidecar is written, and the main
// transcript stays quiet while the agent works. The chat ticks until the
// agent's transcript is watched, then reads on its writes only.
func TestChatFiles_SubagentFileAddedAfterAgentStarts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		sidecar := filepath.Join(r.dir, "conv", "subagents", "agent-a1.meta.json")
		status := sessionfeed.StatusRunning
		r.live = func() *sessionfeed.Live {
			if !exists(sidecar) {
				return &sessionfeed.Live{TurnActive: true, AgentsState: "known", Agents: []sessionfeed.LiveAgent{}}
			}
			return runningAgent("a1", status)
		}
		r.start()
		r.sleep(5 * time.Second)
		// The Agent call: running, no id yet.
		r.set(func() {
			r.live = func() *sessionfeed.Live {
				if !exists(sidecar) {
					return runningAgent("", sessionfeed.StatusRunning)
				}
				return runningAgent("a1", status)
			}
		})
		r.fire(r.conv)
		r.sleep(250 * time.Millisecond)
		r.wantReads(2, "the Agent call")
		r.wantWatched("before the agent's id is known", r.conv)
		// The sidecar and the agent's transcript appear; no main event.
		touch(t, r.dir, "conv/subagents/agent-a1.meta.json")
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.sleep(3 * time.Second) // the fallback tick
		r.wantReads(3, "the tick after the sidecar")
		r.wantWatched("after the agent's id is known", r.conv, sub)
		r.sleep(time.Second)
		r.wantReads(4, "the reconcile read for the newly watched transcript")
		r.sleep(30 * time.Second)
		r.wantReads(4, "30 s with every running agent watched")
		r.fire(sub)
		r.sleep(250 * time.Millisecond)
		r.wantReads(5, "a write to the agent's transcript")
		// The agent finishes: its transcript is let go.
		r.set(func() { status = sessionfeed.StatusFinished })
		r.fire(sub)
		r.sleep(time.Second)
		r.wantReads(6, "the agent's end")
		r.wantWatched("after the agent finished", r.conv)
	})
}

func TestChatFiles_ConversationFileAppearsLater(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		if err := os.Remove(r.conv); err != nil {
			t.Fatal(err)
		}
		r.start()
		r.wantReads(1, "the open read")
		r.sleep(30 * time.Second)
		r.wantReads(1, "30 s with no conversation file")
		if r.watcher() != nil {
			t.Fatal("a watcher was opened with nothing to watch")
		}
		touch(t, r.dir, "conv.jsonl")
		r.sleep(2 * time.Second) // one Wake
		r.wantReads(2, "one Wake after the file appeared")
		r.wantWatched("after the file appeared", r.conv)
		r.fire(r.conv)
		r.sleep(time.Second) // MinGap after the read the file's arrival made
		r.wantReads(3, "a write to the new file")
	})
}

// A first resolve that fails, then one that succeeds, arms the watch and
// reads (the success is a change even though nothing was known before).
func TestChatFiles_FirstResolveFailsThenArms(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.resolveErr = errors.New("database is locked")
		r.start()
		r.wantReads(1, "the open read")
		r.wantWatched("with the resolve failing")
		r.set(func() { r.resolveErr = nil })
		r.sleep(2 * time.Second)
		r.wantReads(2, "the Wake after the resolve succeeded")
		r.wantWatched("after the resolve succeeded", r.conv)
	})
}

func TestChatFiles_HubRestartReadsOnFirstRequest(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start() // a fresh source: no runs, no watchers
		r.wantReads(1, "right after the first request")
		r.wantWatched("right after the first request", r.conv)
	})
}

// The phone repeats session_chat_request every 60 s to keep the watch: that
// reads nothing.
func TestChatFiles_KeepAliveRequestDoesNotRead(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		for range 3 {
			r.sleep(60 * time.Second)
			r.request("")
		}
		r.wantReads(1, "three keep-alive requests")
	})
}

// The Retry is a request while the stored chat has live_error: it reads,
// and inside MinGap it waits for MinGap's end instead of being dropped.
func TestChatFiles_RetryRequestReads(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.live = func() *sessionfeed.Live { return runningAgent("", sessionfeed.StatusFinished) }
		r.start()
		r.sleep(5 * time.Second)
		r.set(func() { r.liveErr = true })
		r.fire(r.conv)
		r.sleep(250 * time.Millisecond)
		r.wantReads(2, "the read whose live part failed")
		r.set(func() { r.liveErr = false })
		r.sleep(500 * time.Millisecond)
		r.request("") // Retry, 500 ms after that read
		r.wantReads(2, "a Retry inside MinGap")
		r.sleep(500 * time.Millisecond)
		r.wantReads(3, "MinGap after the failed read")
		r.sleep(5 * time.Second)
		r.request("") // live_error is gone: a keep-alive now
		r.wantReads(3, "a request after the recovery")
	})
}

func TestChatFiles_StopsBeingLiveReadsOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(5 * time.Second)
		r.set(func() { r.isLive = false })
		r.sleep(2 * time.Second) // the Wake tick sees it
		r.wantReads(2, "the session stopped being live")
		r.sleep(60 * time.Second)
		r.wantReads(2, "a minute after it stopped")
	})
}

// An agent record with nothing to watch (its read failed: no sidechain yet)
// ticks while the session is live, until its read arms the watch.
func TestChatFiles_AgentRecordTicksUntilArmed(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.request("toolu_1")
		if n := r.readsOf("toolu_1"); n != 1 {
			t.Fatalf("the agent record's open read: %d", n)
		}
		r.sleep(3 * time.Second)
		if n := r.readsOf("toolu_1"); n != 2 {
			t.Fatalf("an unarmed agent record did not tick: %d reads", n)
		}
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.sleep(4 * time.Second) // the arming tick and its reconcile read
		n := r.readsOf("toolu_1")
		r.sleep(30 * time.Second)
		if m := r.readsOf("toolu_1"); m != n {
			t.Fatalf("the armed agent record kept ticking: %d → %d reads", n, m)
		}
		r.wantWatched("the armed agent record", r.conv, sub)
	})
}

// A read that finds a new file to watch asks for one more read MinGap
// later: what was written to it before it was watched sent no event. That
// reconcile adds nothing new, so it never loops.
func TestChatFiles_NewFileGetsOneReconcileRead(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.live = func() *sessionfeed.Live { return runningAgent("a1", sessionfeed.StatusRunning) }
		r.start()
		r.wantReads(1, "the open read")
		r.wantWatched("after the open read", r.conv, sub)
		r.sleep(time.Second)
		r.wantReads(2, "the reconcile read")
		r.sleep(30 * time.Second)
		r.wantReads(2, "30 s after the reconcile")
	})
}

// A file both the main feed and an agent record hold is watched once, and
// one write reads each record once.
func TestChatFiles_SharedFileOneWatch(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.live = func() *sessionfeed.Live { return runningAgent("a1", sessionfeed.StatusRunning) }
		r.start()
		r.request("toolu_1")
		r.sleep(5 * time.Second) // past the reconcile reads
		main, agent := r.readCount(), r.readsOf("toolu_1")
		r.fire(sub)
		r.sleep(250 * time.Millisecond)
		if r.readCount() != main+1 || r.readsOf("toolu_1") != agent+1 {
			t.Fatalf("one write: main %d → %d, agent %d → %d reads, want one each", main, r.readCount(), agent, r.readsOf("toolu_1"))
		}
		if n := len(r.watchers); n != 1 {
			t.Fatalf("%d watchers, want one for the source", n)
		}
		holders := func() int {
			r.s.mu.Lock()
			defer r.s.mu.Unlock()
			return len(r.s.byPath[sub])
		}
		if holders() != 2 {
			t.Fatalf("%d records hold the shared file, want 2", holders())
		}
	})
}

// A dirty chat whose debounce has already passed (a read held it) is due at
// once, not skipped.
func TestChatFiles_NextDueKeepsAPastDebounce(t *testing.T) {
	r := newChatRig(t)
	s := r.source(nil, ChatTiming{})
	now := r.clock.Now()
	s.runs[chatKey{session: 7}] = &chatRun{last: now.Add(-5 * time.Second), chatFiles: chatFiles{
		dirty: true, dirtySince: now.Add(-4 * time.Second), lastEvent: now.Add(-4 * time.Second),
	}}
	at, ok := s.nextDue()
	if !ok || at.After(now) {
		t.Fatalf("nextDue = %v, %v; want a moment not after now", at, ok)
	}
}

func TestChatFiles_RealWatcherOnlyListedFiles(t *testing.T) {
	dir := t.TempDir()
	var files []string
	for i := range 200 {
		files = append(files, touch(t, dir, "conv-"+itoa(i)+".jsonl"))
	}
	watches := handlers.NewChatWatchRegistry()
	s := SessionChat(watches, nil, SessionChatOptions{
		Fetch: func(context.Context, int64, string) (ChatRead, error) {
			return ChatRead{Entries: []sessionfeed.Entry{feedEntry(1, "hi")}, Paths: []string{files[0]}}, nil
		},
		Conversations: func(context.Context, int64) ([]sessionfeed.Conversation, error) {
			return []sessionfeed.Conversation{{AgentSessionID: "c1", Path: files[0]}}, nil
		},
		AgentSessions: func(context.Context, int64) ([]string, error) { return []string{"c1"}, nil },
		Liveness:      func() Liveness { return Liveness{Runs: map[int64]time.Time{7: time.Now()}} },
	})
	defer s.dropAll()
	before := openFiles(t)
	watches.Watch(handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)})
	s.RunDue(context.Background())
	s.mu.Lock()
	armed := s.fw != nil && s.byPath[files[0]] != nil
	s.mu.Unlock()
	if !armed {
		t.Fatal("no watcher armed")
	}
	if grew := openFiles(t) - before; grew > 4 {
		t.Fatalf("arming one file's watch opened %d descriptors, want ≤ 4", grew)
	}
}

// The real fsnotify path end to end: a write to the watched file reads the
// chat once.
func TestChatFiles_RealWatcherWriteReadsOnce(t *testing.T) {
	conv := touch(t, t.TempDir(), "conv.jsonl")
	reads := make(chan struct{}, 16)
	var mu sync.Mutex
	n := 0
	watches := handlers.NewChatWatchRegistry()
	s := SessionChat(watches, nil, SessionChatOptions{
		Timing: ChatTiming{Every: time.Hour, Timeout: 30 * time.Second, Wake: time.Hour, Debounce: time.Millisecond, MinGap: time.Millisecond},
		Fetch: func(context.Context, int64, string) (ChatRead, error) {
			mu.Lock()
			n++
			mu.Unlock()
			reads <- struct{}{}
			return ChatRead{Entries: []sessionfeed.Entry{feedEntry(1, "hi")}, Paths: []string{conv}}, nil
		},
		Conversations: func(context.Context, int64) ([]sessionfeed.Conversation, error) {
			return []sessionfeed.Conversation{{AgentSessionID: "c1", Path: conv}}, nil
		},
		AgentSessions: func(context.Context, int64) ([]string, error) { return []string{"c1"}, nil },
		Liveness:      func() Liveness { return Liveness{Runs: map[int64]time.Time{7: time.Now()}} },
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	s.RequestWatches().Watch(handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)})
	go func() { done <- s.Run(ctx) }()
	await := func(what string) {
		t.Helper()
		select {
		case <-reads:
		case <-time.After(10 * time.Second):
			cancel()
			<-done
			t.Fatalf("no read: %s", what)
		}
	}
	await("the open read")
	f, err := os.OpenFile(conv, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("{\"type\":\"user\"}\n"); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	await("the write")
	cancel()
	<-done
	mu.Lock()
	defer mu.Unlock()
	if n != 2 {
		t.Fatalf("%d reads, want the open read and one for the write", n)
	}
}

// openFiles counts the process's open descriptors.
func openFiles(t *testing.T) int {
	t.Helper()
	f, err := os.Open("/dev/fd")
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("no /dev/fd")
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	names, err := f.Readdirnames(-1)
	if err != nil {
		t.Fatal(err)
	}
	return len(names)
}

func TestChatFiles_AddFailsFallsBackToTick(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var logs bytes.Buffer
		log.SetOutput(&logs)
		defer log.SetOutput(os.Stderr)
		r := newFilesRig(t)
		r.addErr = errors.New("too many open files")
		r.start()
		r.wantReads(1, "the open read")
		r.sleep(9 * time.Second)
		r.wantReads(4, "9 s on the fallback tick")
		if w := r.watcher(); w == nil || !w.isClosed() {
			t.Fatal("the watcher holding nothing was not closed")
		}
		if n := strings.Count(logs.String(), "cannot watch the files"); n != 1 {
			t.Fatalf("the fallback was logged %d times, want once:\n%s", n, logs.String())
		}
		// Not live any more: one read for the end, then none.
		r.set(func() { r.isLive = false })
		r.sleep(30 * time.Second)
		r.wantReads(5, "after the session stopped")
	})
}

func TestChatFiles_WatchersClosedOnExpiryAndUnlink(t *testing.T) {
	t.Run("expiry", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			r := newFilesRig(t)
			r.start()
			w := r.watcher()
			r.sleep(handlers.ChatWatchLength + 2*time.Second)
			if !w.isClosed() {
				t.Fatal("the watcher outlived its watch")
			}
			r.sleep(time.Minute)
			r.wantReads(1, "after the watch expired")
		})
	})
	t.Run("unlink", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			r := newFilesRig(t)
			r.start()
			w := r.watcher()
			r.set(func() { r.active = false })
			r.sleep(2 * time.Second)
			if !w.isClosed() {
				t.Fatal("the watcher outlived the phone's link")
			}
			r.sleep(time.Minute)
			r.wantReads(1, "after the phone unlinked")
		})
	})
}

func TestChatFiles_ReadInFlightRearms(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		release := make(chan struct{})
		r.block = release
		r.start()
		r.sleep(5 * time.Second)
		r.fire(r.conv)
		r.sleep(250 * time.Millisecond)
		r.wantReads(2, "the read in flight")
		r.fire(r.conv) // two events while it reads
		r.fire(r.conv)
		r.sleep(2 * time.Second)
		r.wantReads(2, "while the read is held")
		close(release)
		synctest.Wait()
		r.wantReads(3, "right after the held read")
		r.sleep(10 * time.Second)
		r.wantReads(3, "10 s after the held read")
	})
}

// A launch whose status is still unknown (its sidecar unread) is not
// watchable yet: the chat ticks while the parent transcript is quiet, and
// the child's run is picked up when it resolves.
func TestChatFiles_UnknownLaunchTicksUntilResolved(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		sidecar := filepath.Join(r.dir, "conv", "subagents", "agent-a1.meta.json")
		r.live = func() *sessionfeed.Live {
			if !exists(sidecar) {
				return runningAgent("", sessionfeed.StatusUnknown)
			}
			return runningAgent("a1", sessionfeed.StatusRunning)
		}
		r.start()
		r.sleep(3 * time.Second)
		r.wantReads(2, "the tick while the launch is unresolved")
		touch(t, r.dir, "conv/subagents/agent-a1.meta.json")
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.sleep(3 * time.Second)
		r.wantReads(3, "the tick after the child appeared")
		r.wantWatched("after the launch resolved", r.conv, sub)
		r.sleep(time.Second)
		r.wantReads(4, "the reconcile read")
		r.sleep(30 * time.Second)
		r.wantReads(4, "30 s once the child is watched")
		r.fire(sub)
		r.sleep(250 * time.Millisecond)
		r.wantReads(5, "the child's write")
	})
}

// A first read that fails while the files are watched retries on the tick
// until one succeeds, then stops.
func TestChatFiles_FirstFetchFailsTicks(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.fetchErr = errors.New("database is locked")
		r.start()
		r.wantWatched("with the read failing", r.conv)
		r.sleep(6 * time.Second)
		r.wantReads(3, "two ticks after the failed open read")
		r.set(func() { r.fetchErr = nil })
		r.sleep(3 * time.Second)
		r.wantReads(4, "the tick that succeeds")
		r.sleep(30 * time.Second)
		r.wantReads(4, "30 s after a read succeeded")
	})
}

// armRig is a source with chats held by hand, for the watcher's
// bookkeeping.
func armRig(t *testing.T, w *fakeWatcher) *SessionChatSource {
	t.Helper()
	return SessionChat(handlers.NewChatWatchRegistry(), nil, SessionChatOptions{
		Fetch:      func(context.Context, int64, string) (ChatRead, error) { return ChatRead{}, nil },
		NewWatcher: func() (FileWatcher, error) { return w, nil },
	})
}

func holdRun(s *SessionChatSource, k chatKey, paths ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := &chatRun{}
	for _, p := range paths {
		r.convs = append(r.convs, sessionfeed.Conversation{Path: p})
	}
	s.runs[k] = r
}

func dropRun(s *SessionChatSource, k chatKey) {
	s.mu.Lock()
	if r, ok := s.runs[k]; ok {
		s.releaseAll(k, r)
		delete(s.runs, k)
	}
	s.mu.Unlock()
	s.lockedSync()
}

// A file one chat lets go of while another takes it is never removed from
// under the new holder, which still gets its events.
func TestChatFiles_ReleaseAndReaddKeepTheWatch(t *testing.T) {
	p := touch(t, t.TempDir(), "conv.jsonl")
	w := &fakeWatcher{paths: map[string]bool{}, events: make(chan string, 16), errs: make(chan error, 1)}
	s := armRig(t, w)
	defer s.dropAll()
	a, b := chatKey{session: 1}, chatKey{session: 2}
	// Chat 1 lets go of the file (queued, not yet removed), then chat 2
	// takes it: the queued removal must not drop chat 2's watch.
	holdRun(s, a, p)
	s.arm(a, 0)
	s.mu.Lock()
	s.releaseAll(a, s.runs[a])
	delete(s.runs, a)
	s.mu.Unlock()
	holdRun(s, b, p)
	s.arm(b, 0)
	if got := w.watched(); !slices.Equal(got, []string{p}) {
		t.Fatalf("after the hand-over the watcher holds %v, want %s", got, p)
	}
	dropRun(s, b)
	for i := range 200 {
		holdRun(s, a, p)
		holdRun(s, b, p)
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); s.arm(a, 0); dropRun(s, a) }()
		go func() { defer wg.Done(); dropRun(s, b); holdRun(s, b, p); s.arm(b, 0) }()
		wg.Wait()
		if got := w.watched(); !slices.Equal(got, []string{p}) {
			t.Fatalf("round %d: the watcher holds %v while chat 2 holds %s", i, got, p)
		}
		dropRun(s, b)
	}
	holdRun(s, b, p)
	s.arm(b, 0)
	s.fileEvent(w, p, false)
	s.mu.Lock()
	dirty := s.runs[b].dirty
	s.mu.Unlock()
	if !dirty {
		t.Fatal("the new holder got no event")
	}
}

// An Add failing part-way lets go of what that pass added: only the other
// chat's file stays watched, and the failed chat holds nothing.
func TestChatFiles_FailedAddRollsBack(t *testing.T) {
	dir := t.TempDir()
	w := &fakeWatcher{paths: map[string]bool{}, events: make(chan string, 16), errs: make(chan error, 1), failAdd: 4}
	s := armRig(t, w)
	defer s.dropAll()
	other, k := chatKey{session: 1}, chatKey{session: 2}
	kept := touch(t, dir, "other.jsonl")
	holdRun(s, other, kept)
	s.arm(other, 0) // Add 1
	holdRun(s, k, touch(t, dir, "a.jsonl"), touch(t, dir, "b.jsonl"), touch(t, dir, "c.jsonl"))
	s.arm(k, 0) // Adds 2, 3, then 4 fails
	if got := w.watched(); !slices.Equal(got, []string{kept}) {
		t.Fatalf("after the failed Add the watcher holds %v, want only %s", got, kept)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.byPath) != 1 || s.byPath[kept] == nil || !s.runs[k].fallback || len(s.runs[k].watched) != 0 {
		t.Fatalf("after the failed Add: byPath %v, fallback %v, held %v", s.byPath, s.runs[k].fallback, s.runs[k].watched)
	}
}
