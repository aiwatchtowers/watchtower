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
// real-watcher one runs in a synctest bubble over a fake watcher, its loop
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
}

func (f *fakeWatcher) Add(p string) error {
	if _, err := os.Lstat(p); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.addErr != nil {
		return f.addErr
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

// filesRig is a live session 7 whose conversation is dir/conv.jsonl, read by
// a fake fetch that lists the files that exist and a live block the test
// sets.
type filesRig struct {
	t        *testing.T
	dir      string
	conv     string
	watches  *handlers.ChatWatchRegistry
	mu       sync.Mutex
	reads    int
	convs    []string
	live     *sessionfeed.Live
	isLive   bool
	active   bool
	addErr   error
	watchers []*fakeWatcher
	// block, when set, holds every read after the first until it is closed.
	block chan struct{}
	s     *SessionChatSource
	stop  func()
}

func newFilesRig(t *testing.T) *filesRig {
	dir := t.TempDir()
	r := &filesRig{t: t, dir: dir, conv: touch(t, dir, "conv.jsonl"), watches: handlers.NewChatWatchRegistry(), isLive: true, active: true}
	r.convs = []string{r.conv}
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

func (r *filesRig) options() SessionChatOptions {
	return SessionChatOptions{
		Fetch: func(ctx context.Context, id int64, toolUseID string) (ChatRead, error) {
			r.mu.Lock()
			r.reads++
			n, block, live := r.reads, r.block, r.live
			paths := slices.Clone(r.convs)
			r.mu.Unlock()
			if block != nil && n > 1 {
				select {
				case <-block:
				case <-ctx.Done():
					return ChatRead{}, ctx.Err()
				}
			}
			if live != nil {
				for _, a := range live.Agents {
					if p := r.agentPath(a.Ref.AgentID); exists(p) {
						paths = append(paths, p)
					}
				}
			}
			return ChatRead{Entries: []sessionfeed.Entry{feedEntry(n, "read")}, Live: live, Paths: paths}, nil
		},
		Conversations: func(context.Context, int64) ([]string, error) {
			r.mu.Lock()
			defer r.mu.Unlock()
			return slices.Clone(r.convs), nil
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

// start runs the source's loop (stopped at the test's end) and opens the
// phone's watch of session 7 the way session_chat_request does.
func (r *filesRig) start() {
	r.s = SessionChat(r.watches, nil, r.options())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.s.Run(ctx) }()
	r.stop = func() { cancel(); <-done }
	r.t.Cleanup(r.stop)
	synctest.Wait()
	r.request()
}

func (r *filesRig) request() {
	r.s.RequestWatches().Watch(handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)})
	synctest.Wait()
}

func (r *filesRig) readCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.reads
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
	if w != nil {
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

func TestChatFiles_NoEventNoRead(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(60 * time.Second)
		r.wantReads(1, "a live chat with no event for 60 s")
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
		r.mu.Lock()
		r.convs = []string{renamed}
		r.mu.Unlock()
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
		r.mu.Lock()
		r.convs = []string{r.conv, next}
		r.mu.Unlock()
		r.sleep(time.Second) // the Wake tick, 2 s after the open
		r.wantReads(2, "one Wake after the new conversation")
		r.wantWatched("after the new conversation", r.conv, next)
		r.sleep(30 * time.Second)
		r.wantReads(2, "30 s later")
		r.fire(next)
		r.sleep(250 * time.Millisecond)
		r.wantReads(3, "a write to the new conversation")
	})
}

func TestChatFiles_SubagentFileAddedAfterAgentStarts(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.sleep(5 * time.Second)
		agent := func(status string) *sessionfeed.Live {
			return &sessionfeed.Live{TurnActive: true, AgentsState: "known", Agents: []sessionfeed.LiveAgent{{
				Ref: sessionfeed.SubagentRef{AgentID: "a1", ToolUseID: "toolu_1", Type: "Explore", Status: status},
			}}}
		}
		// The Agent call lands in the conversation; the agent's file is not
		// there yet.
		r.mu.Lock()
		r.live = agent(sessionfeed.StatusRunning)
		r.mu.Unlock()
		r.fire(r.conv)
		r.sleep(time.Second)
		r.wantReads(2, "the Agent call")
		r.wantWatched("before the agent's file exists", r.conv)
		// Its file appears; the next read adds it.
		sub := touch(t, r.dir, "conv/subagents/agent-a1.jsonl")
		r.fire(r.conv)
		r.sleep(time.Second)
		r.wantReads(3, "the next conversation write")
		r.wantWatched("after the agent's file appeared", r.conv, sub)
		r.fire(sub)
		r.sleep(time.Second)
		r.wantReads(4, "a write to the agent's file")
		// The agent finishes: its file is no longer watched.
		r.mu.Lock()
		r.live = agent(sessionfeed.StatusFinished)
		r.mu.Unlock()
		r.fire(r.conv)
		r.sleep(time.Second)
		r.wantReads(5, "the agent's end")
		r.wantWatched("after the agent finished", r.conv)
	})
}

func TestChatFiles_ConversationFileAppearsLater(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		if err := os.Remove(r.conv); err != nil {
			t.Fatal(err)
		}
		r.convs = nil // SessionConversations lists only existing files
		r.start()
		r.wantReads(1, "the open read")
		r.sleep(30 * time.Second)
		r.wantReads(1, "30 s with no conversation file")
		if r.watcher() != nil {
			t.Fatal("a watcher was opened with nothing to watch")
		}
		touch(t, r.dir, "conv.jsonl")
		r.mu.Lock()
		r.convs = []string{r.conv}
		r.mu.Unlock()
		r.sleep(2 * time.Second) // one Wake
		r.wantReads(2, "one Wake after the file appeared")
		r.wantWatched("after the file appeared", r.conv)
		r.fire(r.conv)
		r.sleep(time.Second) // MinGap after the read the file's arrival made
		r.wantReads(3, "a write to the new file")
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

// The phone's Retry is a repeated session_chat_request: it reads again at
// once when the last read is at least MinGap old.
func TestChatFiles_RepeatRequestReadsAgain(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newFilesRig(t)
		r.start()
		r.request()
		r.wantReads(1, "a repeat inside MinGap")
		r.sleep(5 * time.Second)
		r.request()
		r.wantReads(2, "a repeat 5 s later")
	})
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
		Conversations: func(context.Context, int64) ([]string, error) { return []string{files[0]}, nil },
		Liveness:      func() Liveness { return Liveness{Runs: map[int64]time.Time{7: time.Now()}} },
	})
	defer s.dropAll()
	before := openFiles(t)
	watches.Watch(handlers.ChatWatch{SessionID: 7, Expires: time.Now().Add(handlers.ChatWatchLength)})
	s.RunDue(context.Background())
	s.mu.Lock()
	armed := s.runs[chatKey{session: 7}].watcher != nil
	s.mu.Unlock()
	if !armed {
		t.Fatal("no watcher armed")
	}
	if grew := openFiles(t) - before; grew > 4 {
		t.Fatalf("arming one file's watch opened %d descriptors, want ≤ 4", grew)
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
			t.Fatal("the failed watcher was not closed")
		}
		if n := strings.Count(logs.String(), "cannot watch the files"); n != 1 {
			t.Fatalf("the fallback was logged %d times, want once:\n%s", n, logs.String())
		}
		// Not live any more: one read for the end, then none.
		r.mu.Lock()
		r.isLive = false
		r.mu.Unlock()
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
			r.mu.Lock()
			r.active = false
			r.mu.Unlock()
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
		r.sleep(10 * time.Second)
		r.wantReads(3, "after the held read")
	})
}
