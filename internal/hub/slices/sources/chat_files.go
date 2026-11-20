package sources

import (
	"cmp"
	"context"
	"errors"
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
		return nil, err
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

// ChatConversations lists a session's conversation transcripts, oldest
// first, whose files exist (a database query and a stat, no transcript
// read).
type ChatConversations func(ctx context.Context, sessionID int64) ([]string, error)

// sessionConversations is the in-process ChatConversations over d: the
// session agent's sessionfeed.SessionConversations. With no database there
// are none.
func sessionConversations(d *db.DB, dirs sessionfeed.Dirs) ChatConversations {
	return func(ctx context.Context, id int64) ([]string, error) {
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
		out := make([]string, 0, len(convs))
		for _, c := range convs {
			p := c.Path
			if abs, err := filepath.Abs(p); err == nil {
				p = abs
			}
			out = append(out, p)
		}
		return out, nil
	}
}

// chatFiles is the file part of a chatRun: what its watcher watches and
// when its next event read is due.
type chatFiles struct {
	watcher FileWatcher
	// watched is the files the watcher holds.
	watched map[string]bool
	// convs is the resolved conversation transcripts (main feed watches),
	// resolvedAt when they were last resolved; extra is the other files of
	// the last read worth watching (watchedExtras).
	convs      []string
	resolved   bool
	resolvedAt time.Time
	extra      []string
	// fallback: a watcher could not be set; the chat reads on the Every tick
	// for the rest of its watch.
	fallback bool
	// dirty: an event since the last read started, the first at dirtySince
	// and the newest at lastEvent.
	dirty                 bool
	dirtySince, lastEvent time.Time
	// reresolve: an event named a file that is gone (removed or renamed).
	reresolve bool
	// convsChanged: the resolved conversations changed since the last read.
	convsChanged bool
	// requested: the phone asked again (session_chat_request).
	requested bool
}

// dirtyDue is when a dirty chat's read is due: Debounce after the last
// event, but no later than MinGap after the first one, so a burst still
// reads about once a second (the caller adds MinGap after the last read).
func (f *chatFiles) dirtyDue(t ChatTiming) time.Time {
	return minTime(f.lastEvent.Add(t.Debounce), f.dirtySince.Add(t.MinGap))
}

func minTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}

// want is the files to watch: the conversations then the extras, without
// repeats.
func (f *chatFiles) want() []string {
	out := make([]string, 0, len(f.convs)+len(f.extra))
	for _, p := range slices.Concat(f.convs, f.extra) {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// watchedExtras is the files of read worth watching besides the session's
// conversations: an agent record's own sidechain (the first path its read
// lists) and the transcript of each subagent its live block lists as
// running (at most maxLiveAgents; the live block lists no more). A running
// subagent whose file the read did not find is picked up by a later read.
func watchedExtras(k chatKey, read ChatRead) []string {
	var out []string
	if k.toolUseID != "" && len(read.Paths) > 0 {
		out = append(out, read.Paths[0])
	}
	if read.Live == nil {
		return out
	}
	var running []string
	for _, a := range read.Live.Agents {
		if a.Ref.Status == sessionfeed.StatusRunning && a.Ref.AgentID != "" {
			running = append(running, a.Ref.AgentID)
		}
	}
	for _, p := range read.Paths {
		if len(out) >= maxLiveAgents+1 {
			break
		}
		base := filepath.Base(p)
		if !strings.HasSuffix(base, ".jsonl") || slices.Contains(out, p) {
			continue
		}
		for _, id := range running {
			// A Claude subagent's agent-<id>.jsonl, a Codex child's
			// rollout-<stamp>-<id>.jsonl.
			if base == "agent-"+id+".jsonl" || strings.HasPrefix(base, "rollout-") && strings.HasSuffix(base, "-"+id+".jsonl") {
				out = append(out, p)
				break
			}
		}
	}
	return out
}

// resolveConversations re-resolves the conversations of the main-feed
// watches that need it — never resolved, flagged by a gone file, or live and
// not resolved for a Wake — and marks a changed list for a read. It reads no
// transcript.
func (s *SessionChatSource) resolveConversations(ctx context.Context, active map[chatKey]bool, live map[int64]time.Time) {
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
		if r.fallback || r.resolved && !r.reresolve && (!isLive || now.Sub(r.resolvedAt) < s.o.Timing.Wake) {
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
		convs, err := bounded(ctx, s.o.Timing.Timeout, func(ctx context.Context) ([]string, error) {
			return s.o.Conversations(ctx, k.session)
		})
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("hub slices: resolving the conversations of session %d failed (%s)", k.session, errClass(err))
			}
			continue
		}
		s.mu.Lock()
		if r, ok := s.runs[k]; ok && s.generation == gen {
			if r.resolved && !slices.Equal(r.convs, convs) {
				r.convsChanged = true
			}
			r.convs, r.resolved, r.resolvedAt, r.reresolve = convs, true, now, false
		}
		s.mu.Unlock()
	}
}

// arm points k's watcher at its files after a read (read nil: a failed
// read, the extras stay): it adds every wanted file — again too, since a
// removed or renamed file's watch is gone — and removes the rest. A file
// that does not exist yet is skipped; any other failure, or no watcher at
// all, sends the chat to the Every tick, logged once.
func (s *SessionChatSource) arm(k chatKey, gen int, read *ChatRead) {
	s.mu.Lock()
	r, ok := s.runs[k]
	if !ok || s.generation != gen || r.fallback {
		s.mu.Unlock()
		return
	}
	if read != nil && (read.Live != nil || read.LiveErr == nil) {
		r.extra = watchedExtras(k, *read)
	}
	want, w := r.want(), r.watcher
	s.mu.Unlock()
	if w == nil {
		if len(want) == 0 {
			return
		}
		var err error
		if w, err = s.o.NewWatcher(); err != nil {
			s.fallBack(k, gen, nil, err)
			return
		}
		s.mu.Lock()
		r, ok = s.runs[k]
		if !ok || s.generation != gen || r.fallback || r.watcher != nil {
			s.mu.Unlock()
			_ = w.Close()
			return
		}
		r.watcher = w
		s.mu.Unlock()
		go s.forward(k, w)
	}
	added := map[string]bool{}
	for _, p := range want {
		err := w.Add(p)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			s.fallBack(k, gen, w, err)
			return
		}
		added[p] = true
	}
	s.mu.Lock()
	prev := r.watched
	r.watched = added
	s.mu.Unlock()
	for p := range prev {
		if !added[p] {
			_ = w.Remove(p)
		}
	}
}

// fallBack sends k to the Every tick and closes its watcher.
func (s *SessionChatSource) fallBack(k chatKey, gen int, w FileWatcher, err error) {
	s.mu.Lock()
	r, ok := s.runs[k]
	if ok && s.generation == gen && !r.fallback && (w == nil || r.watcher == w) {
		r.fallback, r.watcher, r.watched = true, nil, nil
		s.mu.Unlock()
		log.Printf("hub slices: cannot watch the files of the session chat of session %d (%s); reading it every %s", k.session, errClass(err), s.o.Timing.Every)
	} else {
		s.mu.Unlock()
	}
	if w != nil {
		_ = w.Close()
	}
}

// forward turns w's events into dirty marks on k until w is closed.
func (s *SessionChatSource) forward(k chatKey, w FileWatcher) {
	events, errs := w.Events(), w.Errors()
	for events != nil || errs != nil {
		select {
		case p, ok := <-events:
			if !ok {
				events = nil
				continue
			}
			_, statErr := os.Lstat(p)
			s.fileEvent(k, w, statErr != nil)
		case err, ok := <-errs:
			if !ok {
				errs = nil
				continue
			}
			// An overflow or a read error may have lost events: read again.
			log.Printf("hub slices: the file watch of the session chat of session %d failed (%s)", k.session, errClass(err))
			s.fileEvent(k, w, false)
		}
	}
}

// fileEvent marks k dirty (gone: the file is gone, re-resolve too) and
// wakes the loop when the chat was clean, so it sets its debounce timer.
func (s *SessionChatSource) fileEvent(k chatKey, w FileWatcher, gone bool) {
	now := s.o.Now()
	s.mu.Lock()
	r, ok := s.runs[k]
	if !ok || r.watcher != w {
		s.mu.Unlock()
		return
	}
	wake := !r.dirty || gone && !r.reresolve
	if !r.dirty {
		r.dirty, r.dirtySince = true, now
	}
	r.lastEvent = now
	if gone {
		r.reresolve = true
	}
	s.mu.Unlock()
	if wake {
		notify(s.wake)
	}
}

// nextDue is when the earliest dirty chat's read, or a fallback chat's
// Every tick, is due (ok false: none), so the loop wakes for it rather than
// on its next Wake tick. A moment already past is left to the Wake tick (a
// fallback chat that is not live is not read on it), so the loop never
// spins.
func (s *SessionChatSource) nextDue() (time.Time, bool) {
	now := s.o.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	var next time.Time
	found := false
	for _, r := range s.runs {
		var at time.Time
		switch {
		case r.last.IsZero():
			continue
		case r.fallback:
			at = r.last.Add(s.o.Timing.Every)
		case r.dirty:
			at = r.dirtyDue(s.o.Timing)
			if gap := r.last.Add(s.o.Timing.MinGap); gap.After(at) {
				at = gap
			}
		default:
			continue
		}
		if !at.After(now) {
			continue
		}
		if !found || at.Before(next) {
			next, found = at, true
		}
	}
	return next, found
}

// closeWatchers closes watchers taken out of their runs (outside s.mu: a
// watcher's forwarder may be waiting for it).
func closeWatchers(ws []FileWatcher) {
	for _, w := range ws {
		_ = w.Close()
	}
}
