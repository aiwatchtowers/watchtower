package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ErrCodexTrustUnavailable means codex's app-server could not be asked about
// or told the hook trust: it did not start, did not answer within the
// budget, closed early, or answered with an error (an unknown method means
// the protocol changed). The workbench status then reads hooks_trusted null.
var ErrCodexTrustUnavailable = errors.New("codex hook trust unavailable")

// appServerBudget bounds one app-server conversation, from start to exit. A
// var so a test can shorten it.
var appServerBudget = 10 * time.Second

// sessionFlagsSource is the hooks/list source of a hook passed as a launch
// flag (-c hooks.<Event>=…). Its trust key is the same for every folder.
const sessionFlagsSource = "sessionFlags"

// trustedStatus is the hooks/list trustStatus of a hook whose current hash
// is the trusted one ("untrusted" and "modified" are the others).
const trustedStatus = "trusted"

// HookEntry is one hook as codex's hooks/list reports it. Event is codex's
// wire name ("sessionStart"); Source is "sessionFlags", "project", "user", …
type HookEntry struct {
	Key, Command, CurrentHash, TrustStatus, Source, Event string
}

// Trusted reports whether codex runs the hook as it is now.
func (h HookEntry) Trusted() bool { return h.TrustStatus == trustedStatus }

// AppServer is a conversation with `codex app-server` about hook trust.
type AppServer interface {
	// ListHooks is hooks/list for one folder: every hook codex would load
	// there, including the launch-flag ones the server was started with.
	ListHooks(ctx context.Context, cwd string) ([]HookEntry, error)
	// TrustHooks records each launch-flag entry that is not yet trusted as
	// trusted at its current hash, in one config/batchWrite upserting only
	// hooks.state.<key>.trusted_hash. Entries of any other source, and
	// trusted ones, are never written; nothing to write sends nothing.
	TrustHooks(ctx context.Context, entries []HookEntry) error
	// Close ends the conversation and the server's process group.
	Close() error
}

// HookRef names one hook by its config event name ("SessionStart") and its
// exact command line.
type HookRef struct {
	Event, Command string
}

// MatchSessionFlagHooks picks, for each ref, the launch-flag entry codex
// listed with the same event and command. missing holds the refs codex did
// not list. A project or user hook with the same command is never matched:
// only the launch-flag key is ours to trust.
func MatchSessionFlagHooks(entries []HookEntry, refs []HookRef) (matched []HookEntry, missing []HookRef) {
	used := make([]bool, len(entries))
	for _, r := range refs {
		i := findSessionFlagHook(entries, used, r)
		if i < 0 {
			missing = append(missing, r)
			continue
		}
		used[i] = true
		matched = append(matched, entries[i])
	}
	return matched, missing
}

func findSessionFlagHook(entries []HookEntry, used []bool, r HookRef) int {
	event := wireEventName(r.Event)
	for i, e := range entries {
		if !used[i] && e.Source == sessionFlagsSource && e.Event == event && e.Command == r.Command {
			return i
		}
	}
	return -1
}

// wireEventName is the hooks/list spelling of a config event name:
// "SessionStart" → "sessionStart".
func wireEventName(event string) string {
	if event == "" {
		return ""
	}
	return strings.ToLower(event[:1]) + event[1:]
}

// StartAppServer starts `<bin> app-server <extraArgs…>` with env and opens
// the conversation (initialize, initialized). The whole conversation, Close
// included, has a 10 s budget: past it the server's process group is killed
// and every call returns ErrCodexTrustUnavailable. The server runs in its
// own process group, which Close also kills once the server has exited, so
// nothing it spawned outlives the conversation.
func StartAppServer(ctx context.Context, bin string, extraArgs []string, env []string) (AppServer, error) {
	budget, cancel := context.WithTimeout(ctx, appServerBudget)
	s, err := startAppServerProcess(budget, cancel, bin, extraArgs, env)
	if err != nil {
		cancel()
		return nil, err
	}
	if err := s.initialize(budget); err != nil {
		_ = s.Close()
		return nil, err
	}
	return s, nil
}

type appServer struct {
	cmd    *exec.Cmd
	budget context.Context
	cancel context.CancelFunc
	stdin  *os.File
	stdout *os.File
	lines  chan []byte   // one JSON message per line, closed at EOF
	exited chan struct{} // closed once the process has been waited for
	stderr *tailBuffer

	writeMu   sync.Mutex
	nextID    int
	closeOnce sync.Once
}

func startAppServerProcess(budget context.Context, cancel context.CancelFunc, bin string, extraArgs, env []string) (*appServer, error) {
	cmd := exec.Command(bin, append([]string{"app-server"}, extraArgs...)...)
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Plain pipes, not cmd's: Wait must not block on a pipe a grandchild
	// still holds open.
	inR, inW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCodexTrustUnavailable, err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		closeAll(inR, inW)
		return nil, fmt.Errorf("%w: %v", ErrCodexTrustUnavailable, err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		closeAll(inR, inW, outR, outW)
		return nil, fmt.Errorf("%w: %v", ErrCodexTrustUnavailable, err)
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, errW
	if err := cmd.Start(); err != nil {
		closeAll(inR, inW, outR, outW, errR, errW)
		return nil, fmt.Errorf("%w: starting %s app-server: %v", ErrCodexTrustUnavailable, bin, err)
	}
	closeAll(inR, outW, errW) // the child's ends
	s := &appServer{
		cmd: cmd, budget: budget, cancel: cancel, stdin: inW, stdout: outR,
		lines: make(chan []byte, 16), exited: make(chan struct{}), stderr: &tailBuffer{max: 2048},
	}
	go s.readLines()
	go s.stderr.drain(errR)
	go func() { _ = cmd.Wait(); close(s.exited) }()
	go s.watchdog()
	return s, nil
}

func closeAll(files ...*os.File) {
	for _, f := range files {
		_ = f.Close()
	}
}

// watchdog kills the process group once the budget is spent.
func (s *appServer) watchdog() {
	select {
	case <-s.budget.Done():
		s.killGroup()
	case <-s.exited:
	}
}

func (s *appServer) killGroup() {
	_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
}

func (s *appServer) readLines() {
	defer close(s.lines)
	sc := bufio.NewScanner(s.stdout)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		select {
		case s.lines <- bytes.Clone(line):
		case <-s.budget.Done():
			return
		}
	}
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

func (s *appServer) send(msg map[string]any) error {
	msg["jsonrpc"] = "2.0"
	b, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("%w: encoding %v: %v", ErrCodexTrustUnavailable, msg["method"], err)
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err := s.stdin.Write(append(b, '\n')); err != nil {
		return s.unavailable(fmt.Sprintf("writing %v", msg["method"]), err)
	}
	return nil
}

// call sends one request and waits for its response; notifications and
// requests from the server in between are skipped.
func (s *appServer) call(ctx context.Context, method string, params any, result any) error {
	s.writeMu.Lock()
	s.nextID++
	id := s.nextID
	s.writeMu.Unlock()
	if err := s.send(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		return err
	}
	for {
		select {
		case line, ok := <-s.lines:
			if !ok {
				return s.unavailable(method, errors.New("the app-server closed its output"))
			}
			done, err := decodeResponse(line, id, method, result)
			if done || err != nil {
				return err
			}
		case <-s.budget.Done():
			return s.unavailable(method, fmt.Errorf("no answer within %s", appServerBudget))
		case <-ctx.Done():
			return s.unavailable(method, ctx.Err())
		}
	}
}

// decodeResponse reads line as the response to request id: done is false
// for any other message.
func decodeResponse(line []byte, id int, method string, result any) (done bool, err error) {
	var m rpcMessage
	if err := json.Unmarshal(line, &m); err != nil {
		return true, fmt.Errorf("%w: %s: unreadable answer: %v", ErrCodexTrustUnavailable, method, err)
	}
	if m.Method != "" || string(m.ID) != strconv.Itoa(id) {
		return false, nil
	}
	if m.Error != nil {
		return true, fmt.Errorf("%w: %s: error %d: %s", ErrCodexTrustUnavailable, method, m.Error.Code, m.Error.Message)
	}
	if result == nil {
		return true, nil
	}
	if err := json.Unmarshal(m.Result, result); err != nil {
		return true, fmt.Errorf("%w: %s: unexpected result: %v", ErrCodexTrustUnavailable, method, err)
	}
	return true, nil
}

func (s *appServer) unavailable(what string, err error) error {
	if tail := s.stderr.String(); tail != "" {
		return fmt.Errorf("%w: %s: %v (stderr: %s)", ErrCodexTrustUnavailable, what, err, tail)
	}
	return fmt.Errorf("%w: %s: %v", ErrCodexTrustUnavailable, what, err)
}

func (s *appServer) initialize(ctx context.Context) error {
	params := map[string]any{"clientInfo": map[string]any{"name": "watchtower", "version": "1"}}
	if err := s.call(ctx, "initialize", params, nil); err != nil {
		return err
	}
	return s.send(map[string]any{"method": "initialized"})
}

type hooksListResult struct {
	Data []struct {
		Hooks []struct {
			Key         string `json:"key"`
			Command     string `json:"command"`
			CurrentHash string `json:"currentHash"`
			TrustStatus string `json:"trustStatus"`
			Source      string `json:"source"`
			EventName   string `json:"eventName"`
		} `json:"hooks"`
	} `json:"data"`
}

func (s *appServer) ListHooks(ctx context.Context, cwd string) ([]HookEntry, error) {
	var res hooksListResult
	if err := s.call(ctx, "hooks/list", map[string]any{"cwds": []string{cwd}}, &res); err != nil {
		return nil, err
	}
	var out []HookEntry
	for _, d := range res.Data {
		for _, h := range d.Hooks {
			out = append(out, HookEntry{
				Key: h.Key, Command: h.Command, CurrentHash: h.CurrentHash,
				TrustStatus: h.TrustStatus, Source: h.Source, Event: h.EventName,
			})
		}
	}
	return out, nil
}

func (s *appServer) TrustHooks(ctx context.Context, entries []HookEntry) error {
	value := map[string]any{}
	for _, e := range entries {
		if e.Source != sessionFlagsSource || e.Trusted() || e.Key == "" || e.CurrentHash == "" {
			continue
		}
		value[e.Key] = map[string]any{"trusted_hash": e.CurrentHash}
	}
	if len(value) == 0 {
		return nil
	}
	params := map[string]any{"edits": []map[string]any{{
		"keyPath": "hooks.state", "mergeStrategy": "upsert", "value": value,
	}}}
	return s.call(ctx, "config/batchWrite", params, nil)
}

// Close closes the server's input (the app-server exits at EOF), waits for
// it within the budget, then kills whatever is left of its process group.
func (s *appServer) Close() error {
	var err error
	s.closeOnce.Do(func() {
		_ = s.stdin.Close()
		if !s.waitExit() {
			err = s.unavailable("closing", fmt.Errorf("the app-server did not exit within %s", appServerBudget))
		}
		s.killGroup()
		s.cancel()
		_ = s.stdout.Close()
	})
	return err
}

// waitExit waits for the server to exit; false when the budget ran out
// first (the watchdog then kills the group, and the exit follows).
func (s *appServer) waitExit() bool {
	select {
	case <-s.exited:
		return true
	default:
	}
	select {
	case <-s.exited:
		return true
	case <-s.budget.Done():
		<-s.exited
		return false
	}
}

// tailBuffer keeps the last max bytes written to it.
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tailBuffer) drain(f *os.File) {
	defer func() { _ = f.Close() }()
	b := make([]byte, 4096)
	for {
		n, err := f.Read(b)
		if n > 0 {
			t.mu.Lock()
			t.buf = append(t.buf, b[:n]...)
			if len(t.buf) > t.max {
				t.buf = t.buf[len(t.buf)-t.max:]
			}
			t.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return strings.TrimSpace(string(t.buf))
}
