package sources

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"

	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionfeed"
)

// FileWatcher watches single files (never a directory: on macOS fsnotify's
// kqueue backend opens a descriptor for every file of a watched directory).
// Events carries the path of a file that changed, was removed or renamed;
// Events and Errors are closed by Close. Add of a missing file fails with an
// error that matches fs.ErrNotExist.
type FileWatcher interface {
	Add(path string) error
	Remove(path string) error
	Events() <-chan string
	Errors() <-chan error
	Close() error
}

// newFSWatcher is the fsnotify FileWatcher (kqueue on macOS, inotify on
// Linux). A Chmod alone is no change.
func newFSWatcher() (FileWatcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("session chat file watcher: %w", err)
	}
	out := make(chan string)
	go func() {
		defer close(out)
		for ev := range w.Events {
			if ev.Op == fsnotify.Chmod {
				continue
			}
			out <- ev.Name
		}
	}()
	return &fsWatcher{w: w, events: out}, nil
}

type fsWatcher struct {
	w      *fsnotify.Watcher
	events chan string
}

func (f *fsWatcher) Add(path string) error    { return f.w.Add(path) }
func (f *fsWatcher) Remove(path string) error { return f.w.Remove(path) }
func (f *fsWatcher) Events() <-chan string    { return f.events }
func (f *fsWatcher) Errors() <-chan error     { return f.w.Errors }
func (f *fsWatcher) Close() error             { return f.w.Close() }

// ChatConversations lists a session's conversations, oldest first, whose
// transcripts exist: the full resolve (it may list git worktrees and glob
// the transcript dirs), run only when the session's agent-session ids
// changed or one of them has no transcript yet.
type ChatConversations func(ctx context.Context, sessionID int64) ([]sessionfeed.Conversation, error)

// ChatAgentSessions lists a session's agent-session ids, oldest first (one
// database query): the Wake loop's cheap check for a new conversation.
type ChatAgentSessions func(ctx context.Context, sessionID int64) ([]string, error)

// sessionConversations is the in-process ChatConversations over d: the
// session agent's sessionfeed.SessionConversations, paths made absolute.
// With no database there are none.
func sessionConversations(d *db.DB, dirs sessionfeed.Dirs) ChatConversations {
	return func(ctx context.Context, id int64) ([]sessionfeed.Conversation, error) {
		if d == nil {
			return nil, nil
		}
		sess, err := sessionagent.LoadSession(d, id)
		if err != nil {
			return nil, err
		}
		a, ok := sessionagent.Of(sess.Kind)
		if !ok {
			return nil, nil
		}
		convs, err := a.Conversations(ctx, d, id, sess.FolderPath, sess.TranscriptPath.String, dirs)
		if err != nil {
			return nil, err
		}
		for i := range convs {
			if abs, err := filepath.Abs(convs[i].Path); err == nil {
				convs[i].Path = abs
			}
		}
		return convs, nil
	}
}

// sessionAgentSessions is the in-process ChatAgentSessions over d (none
// without a database).
func sessionAgentSessions(d *db.DB) ChatAgentSessions {
	return func(_ context.Context, id int64) ([]string, error) {
		if d == nil {
			return nil, nil
		}
		rows, err := d.ListTerminalAgentSessions(id)
		if err != nil {
			return nil, err
		}
		ids := make([]string, len(rows))
		for i, r := range rows {
			ids[i] = r.AgentSessionID
		}
		return ids, nil
	}
}

// chatFiles is the file part of a chatRun: the files it holds in the
// source's watcher and what its next read waits for.
type chatFiles struct {
	// watched is the files this chat holds in the source's watcher.
	watched map[string]bool
	// convs is the resolved conversations (main-feed watches) and ids the
	// agent-session ids seen with them; checkedAt is the last Wake check.
	convs     []sessionfeed.Conversation
	ids       []string
	resolved  bool
	checkedAt time.Time
	// extra is the other files of the last read worth watching
	// (watchedExtras); agentsUnwatched: a running agent's transcript is not
	// watched (no id yet, no file yet), so the chat ticks while live.
	extra           []string
	agentsUnwatched bool
	// fallback: the files cannot be watched; the chat reads on the Every
	// tick for the rest of its watch.
	fallback bool
	// live is the session's liveness at the last pass.
	live bool
	// fetched: a read succeeded; failed: the last read failed. Until one
	// succeeds a failure ticks (a live_error-only record does not count).
	fetched, failed bool
	// dirty: an event since the last read started, the first at dirtySince
	// and the newest at lastEvent.
	dirty                 bool
	dirtySince, lastEvent time.Time
	// reresolve: an event named a file that is gone (removed or renamed).
	reresolve bool
	// Reads waiting for MinGap after the last: the conversations changed, a
	// read found new files to watch (one reconcile read for what was
	// written before they were watched), the phone asked again (Retry).
	convsChanged, reconcile, requested bool
}

// dirtyDue is when a dirty chat's read is due: Debounce after the last
// event, but no later than MinGap after the first one, so a burst still
// reads about once a second (isDue adds MinGap after the last read).
func (f *chatFiles) dirtyDue(t ChatTiming) time.Time {
	at := f.lastEvent.Add(t.Debounce)
	if first := f.dirtySince.Add(t.MinGap); first.Before(at) {
		return first
	}
	return at
}

// ticks says whether the chat reads on the Every tick: its files cannot be
// watched; no read succeeded yet and the last one failed (however healthy
// the watch); or — while the session is live — a running agent's
// transcript is not watched yet, or it is an agent record with nothing
// watched.
func (f *chatFiles) ticks(k chatKey, isLive bool) bool {
	return f.fallback || !f.fetched && f.failed ||
		isLive && (f.agentsUnwatched || k.toolUseID != "" && len(f.watched) == 0)
}

// want is the files to watch: the conversations then the extras, without
// repeats.
func (f *chatFiles) want() []string {
	var out []string
	for _, c := range f.convs {
		if !slices.Contains(out, c.Path) {
			out = append(out, c.Path)
		}
	}
	for _, p := range f.extra {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// unlocated says whether an agent-session id has no transcript yet.
func (f *chatFiles) unlocated() bool {
	for _, id := range f.ids {
		if !slices.ContainsFunc(f.convs, func(c sessionfeed.Conversation) bool { return c.AgentSessionID == id }) {
			return true
		}
	}
	return false
}

// watchedExtras is the files of read worth watching besides the session's
// conversations: an agent record's own sidechain (the first path its read
// lists) and the transcript of each subagent its live block lists as
// running (at most maxLiveAgents; the live block lists no more). running is
// those transcripts; found is false when a running agent has no id or no
// transcript in the read yet, or an agent's status is still unknown.
func watchedExtras(k chatKey, read ChatRead) (extra, running []string, found bool) {
	if k.toolUseID != "" && len(read.Paths) > 0 {
		extra = append(extra, read.Paths[0])
	}
	if read.Live == nil {
		return extra, nil, true
	}
	found = true
	for _, a := range read.Live.Agents {
		switch a.Ref.Status {
		case sessionfeed.StatusRunning:
		case sessionfeed.StatusUnknown:
			// A launch not resolved yet (its sidecar unread): not
			// watchable until it shows as running.
			found = false
			continue
		default:
			continue
		}
		id := a.Ref.AgentID
		i := -1
		if id != "" {
			i = slices.IndexFunc(read.Paths, func(p string) bool {
				// A Claude subagent's agent-<id>.jsonl, a Codex child's
				// rollout-<stamp>-<id>.jsonl.
				base := filepath.Base(p)
				return base == "agent-"+id+".jsonl" || strings.HasPrefix(base, "rollout-") && strings.HasSuffix(base, "-"+id+".jsonl")
			})
		}
		if i < 0 {
			found = false
			continue
		}
		running = append(running, read.Paths[i])
		if !slices.Contains(extra, read.Paths[i]) {
			extra = append(extra, read.Paths[i])
		}
	}
	return extra, running, found
}

// checkConversations is the Wake loop's look at the main-feed watches:
// first for a new watch, then for a live session at most once per Wake (or
// at once when an event named a gone file). It queries the session's
// agent-session ids and stats the known transcripts it does not watch; the
// full resolve runs only when the ids changed, one is not located yet, or a
// file is gone. A changed resolution, or one with a transcript not watched,
// asks for a read. It reads no transcript.
func (s *SessionChatSource) checkConversations(ctx context.Context, active map[chatKey]bool, live map[int64]time.Time) {
	now := s.o.Now()
	s.mu.Lock()
	var keys []chatKey
	for k := range active {
		if k.agent != "" || k.toolUseID != "" {
			continue
		}
		r, ok := s.runs[k]
		if !ok {
			r = &chatRun{}
			s.runs[k] = r
		}
		_, isLive := live[k.session]
		if r.fallback || !r.checkedAt.IsZero() && !r.reresolve && (!isLive || now.Sub(r.checkedAt) < s.o.Timing.Wake) {
			continue
		}
		keys = append(keys, k)
	}
	gen := s.generation
	s.mu.Unlock()
	slices.SortFunc(keys, func(a, b chatKey) int { return cmp.Compare(a.session, b.session) })
	for _, k := range keys {
		if ctx.Err() != nil {
			return
		}
		s.checkConversation(ctx, k, gen, now)
	}
}

func (s *SessionChatSource) checkConversation(ctx context.Context, k chatKey, gen int, now time.Time) {
	ids, err := bounded(ctx, s.o.Timing.Timeout, func(ctx context.Context) ([]string, error) {
		return s.o.AgentSessions(ctx, k.session)
	})
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("hub slices: listing the conversations of session %d failed (%s)", k.session, errClass(err))
		}
		s.withRun(k, gen, func(r *chatRun) { r.checkedAt = now })
		return
	}
	var full bool
	var unwatched []string
	s.withRun(k, gen, func(r *chatRun) {
		r.checkedAt = now
		full = !r.resolved || r.reresolve || !slices.Equal(ids, r.ids) || r.unlocated()
		for _, c := range r.convs {
			if !r.watched[c.Path] {
				unwatched = append(unwatched, c.Path)
			}
		}
	})
	if !full {
		// A known transcript the watcher could not add yet (it was missing).
		if slices.ContainsFunc(unwatched, func(p string) bool { _, err := os.Stat(p); return err == nil }) {
			s.withRun(k, gen, func(r *chatRun) { r.convsChanged = true })
		}
		return
	}
	convs, err := bounded(ctx, s.o.Timing.Timeout, func(ctx context.Context) ([]sessionfeed.Conversation, error) {
		return s.o.Conversations(ctx, k.session)
	})
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("hub slices: resolving the conversations of session %d failed (%s)", k.session, errClass(err))
		}
		return
	}
	s.withRun(k, gen, func(r *chatRun) {
		changed := !slices.Equal(r.convs, convs) ||
			slices.ContainsFunc(convs, func(c sessionfeed.Conversation) bool { return !r.watched[c.Path] })
		if changed && !r.last.IsZero() {
			r.convsChanged = true
		}
		r.convs, r.ids, r.resolved, r.reresolve = convs, ids, true, false
	})
}

// withRun calls f with k's run under s.mu, unless it was dropped since gen.
func (s *SessionChatSource) withRun(k chatKey, gen int, f func(r *chatRun)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.runs[k]; ok && s.generation == gen {
		f(r)
	}
}

// settle takes a read's files (read nil: it failed, the extras stay), arms
// them and asks for one reconcile read when it added a file the read could
// not have seen written.
func (s *SessionChatSource) settle(k chatKey, gen int, read *ChatRead) {
	var running []string
	allFound := true
	keep := read == nil || read.Live == nil && read.LiveErr != nil
	s.withRun(k, gen, func(r *chatRun) {
		if !keep {
			r.extra, running, allFound = watchedExtras(k, *read)
		}
	})
	added := s.arm(k, gen)
	s.withRun(k, gen, func(r *chatRun) {
		if added > 0 {
			r.reconcile = true
		}
		if !keep {
			r.agentsUnwatched = !allFound || slices.ContainsFunc(running, func(p string) bool { return !r.watched[p] })
		}
	})
}

// arm points the source's watcher at k's files and returns how many it
// added that k did not hold: it adds every wanted file — again too, since a
// removed or renamed file's watch is gone — and lets go of the rest. A file
// that does not exist yet is skipped; any other failure, or no watcher at
// all, sends the chat to the Every tick, logged once, and lets go of what
// this pass added. The watcher's I/O and its ownership change together
// under s.wmu, so a file another chat lets go of meanwhile is never removed
// from under its new holder.
func (s *SessionChatSource) arm(k chatKey, gen int) int {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	s.mu.Lock()
	r, ok := s.runs[k]
	if !ok || s.generation != gen || r.fallback {
		s.mu.Unlock()
		return 0
	}
	want, w := r.want(), s.fw
	if w == nil && len(want) > 0 {
		var err error
		if w, err = s.o.NewWatcher(); err != nil {
			s.mu.Unlock()
			s.fallBack(k, gen, nil, err)
			return 0
		}
		s.fw = w
		go s.forward(w)
	}
	s.mu.Unlock()
	var holds []string
	for _, p := range want {
		err := w.Add(p)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			s.fallBack(k, gen, holds, err)
			return 0
		}
		holds = append(holds, p)
	}
	s.mu.Lock()
	r, ok = s.runs[k]
	if !ok || s.generation != gen || r.fallback {
		// Dropped meanwhile: hold nothing for it.
		s.unheld(holds)
		s.mu.Unlock()
		s.syncWatcher()
		return 0
	}
	added := 0
	for _, p := range holds {
		if !r.watched[p] {
			added++
		}
		if s.byPath[p] == nil {
			s.byPath[p] = map[chatKey]bool{}
		}
		s.byPath[p][k] = true
	}
	keep := setOf(holds)
	for p := range r.watched {
		if !keep[p] {
			s.release(k, p)
		}
	}
	r.watched = keep
	s.mu.Unlock()
	s.syncWatcher()
	return added
}

func setOf(paths []string) map[string]bool {
	out := make(map[string]bool, len(paths))
	for _, p := range paths {
		out[p] = true
	}
	return out
}

// release lets go of p for k (s.mu held); a file no chat holds any more is
// queued for syncWatcher.
func (s *SessionChatSource) release(k chatKey, p string) {
	if holders := s.byPath[p]; holders != nil {
		delete(holders, k)
		if len(holders) > 0 {
			return
		}
		delete(s.byPath, p)
	}
	s.unwatch[p] = true
}

// releaseAll lets go of every file of r (s.mu held).
func (s *SessionChatSource) releaseAll(k chatKey, r *chatRun) {
	for p := range r.watched {
		s.release(k, p)
	}
}

// unheld queues the files of paths no chat holds (s.mu held).
func (s *SessionChatSource) unheld(paths []string) {
	for _, p := range paths {
		if s.byPath[p] == nil {
			s.unwatch[p] = true
		}
	}
}

// syncWatcher does the watcher's I/O for the queued files (s.wmu held, s.mu
// not): a file still unheld is removed — one held again since it was queued
// stays — and a watcher holding nothing is closed.
func (s *SessionChatSource) syncWatcher() {
	s.mu.Lock()
	w := s.fw
	var remove []string
	for p := range s.unwatch {
		if s.byPath[p] == nil {
			remove = append(remove, p)
		}
	}
	clear(s.unwatch)
	closing := w != nil && len(s.byPath) == 0
	if closing {
		s.fw = nil
	}
	s.mu.Unlock()
	switch {
	case w == nil:
	case closing:
		_ = w.Close()
	default:
		for _, p := range remove {
			if err := w.Remove(p); err != nil && !errors.Is(err, fsnotify.ErrNonExistentWatch) {
				log.Printf("hub slices: unwatching a session chat file failed (%s)", errClass(err))
			}
		}
	}
}

// lockedSync is syncWatcher for a caller not holding s.wmu.
func (s *SessionChatSource) lockedSync() {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	s.syncWatcher()
}

// fallBack sends k to the Every tick, lets go of its files and of added —
// the files this pass added for it — and logs once (s.wmu held, s.mu not).
func (s *SessionChatSource) fallBack(k chatKey, gen int, added []string, err error) {
	s.mu.Lock()
	s.unheld(added)
	r, ok := s.runs[k]
	first := ok && s.generation == gen && !r.fallback
	if first {
		s.releaseAll(k, r)
		r.fallback, r.watched = true, nil
	}
	s.mu.Unlock()
	s.syncWatcher()
	if first {
		log.Printf("hub slices: cannot watch the files of the session chat of session %d (%s); reading it every %s", k.session, errClass(err), s.o.Timing.Every)
	}
}

// forward turns w's events into dirty marks until w is closed.
func (s *SessionChatSource) forward(w FileWatcher) {
	events, errs := w.Events(), w.Errors()
	for events != nil || errs != nil {
		select {
		case p, ok := <-events:
			if !ok {
				events = nil
				continue
			}
			_, statErr := os.Lstat(p)
			s.fileEvent(w, p, statErr != nil)
		case err, ok := <-errs:
			if !ok {
				errs = nil
				continue
			}
			// An overflow or a read error may have lost events: every chat
			// reads again.
			log.Printf("hub slices: the session chat file watch failed (%s)", errClass(err))
			s.fileEvent(w, "", false)
		}
	}
}

// fileEvent marks the chats holding p (every chat for "") dirty — gone: the
// file is gone, re-resolve too — and wakes the loop when one was clean, so
// it sets its debounce timer.
func (s *SessionChatSource) fileEvent(w FileWatcher, p string, gone bool) {
	now := s.o.Now()
	s.mu.Lock()
	if s.fw != w {
		s.mu.Unlock()
		return
	}
	wake := false
	for k, r := range s.runs {
		if p != "" && !s.byPath[p][k] {
			continue
		}
		if !r.dirty || gone && !r.reresolve {
			wake = true
		}
		if !r.dirty {
			r.dirty, r.dirtySince = true, now
		}
		r.lastEvent = now
		if gone {
			r.reresolve = true
		}
	}
	s.mu.Unlock()
	if wake {
		notify(s.wake)
	}
}

// nextDue is the earliest moment a chat's read becomes due between Wake
// ticks (ok false: none): a waiting read or a dirty chat's debounce, no
// sooner than MinGap after its last read — at once when that is past —
// and the Every tick of a chat that ticks. A tick already past is left to
// the Wake tick (a fallback chat that is not live is not read on it), so the
// loop never spins.
func (s *SessionChatSource) nextDue() (time.Time, bool) {
	now := s.o.Now()
	t := s.o.Timing
	s.mu.Lock()
	defer s.mu.Unlock()
	var next time.Time
	found := false
	consider := func(at time.Time) {
		if !found || at.Before(next) {
			next, found = at, true
		}
	}
	for k, r := range s.runs {
		if r.last.IsZero() {
			continue
		}
		gap := r.last.Add(t.MinGap)
		if r.requested || r.convsChanged || r.reconcile {
			consider(gap)
		}
		if r.dirty {
			at := r.dirtyDue(t)
			if gap.After(at) {
				at = gap
			}
			consider(at)
		}
		if r.ticks(k, r.live) && (r.live || r.payload == nil || !r.fetched) {
			if at := r.last.Add(t.Every); at.After(now) {
				consider(at)
			}
		}
	}
	return next, found
}
