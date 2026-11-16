package chatengine

// Stops that must end the chat (unified chat spec §7): app quit, the data
// wipe, a purge and `watchtower sync stop` send chat_shutdown on chat.sock;
// when it cannot be reached, `watchtower chat shutdown` reaps the sessions
// directly by their sockets and group files.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"watchtower/internal/chat"
)

// shutdownBudget bounds chat_shutdown: every session's close, 2 s, SIGTERM,
// 3 s, SIGKILL, and the last writes.
const shutdownBudget = 10 * time.Second

// Shutdown ends the chat: each running turn is cancelled and ends `partial`
// with its text so far, every session is closed (close, closeGrace,
// SIGTERM, killAfter, SIGKILL of its group) and waited for. The engine takes
// no more turns; its subscriptions stay until Detach (the daemon's stop).
func (e *Engine) Shutdown(ctx context.Context) error {
	return e.stop(ctx, func(s *session) { s.shutdown = true }, false)
}

// opShutdown is chat_shutdown: the Mac app's or this team's CLI's only
// (D17); a relay client is refused.
func (e *Engine) opShutdownHandler(ctx context.Context, _ json.RawMessage, c Client) (any, error) {
	if c.Kind != clientMac && c.Kind != clientCLI {
		return nil, ErrForbidden
	}
	ctx, cancel := context.WithTimeout(ctx, shutdownBudget)
	defer cancel()
	if err := e.Shutdown(ctx); err != nil {
		return nil, err
	}
	return map[string]any{}, nil
}

// RequestShutdown asks the engine serving chat.sock at socketPath for
// chat_shutdown as this team's CLI, and returns once it answered (every
// session reaped). A socket nobody serves is an error the caller answers
// with ShutdownSessions.
func RequestShutdown(ctx context.Context, socketPath string) error {
	conn, r, err := Dial(ctx, socketPath)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := roundTrip(conn, r, "1", opHello, map[string]any{"protocol": ProtocolVersion, "client": clientCLI}); err != nil {
		return err
	}
	return roundTrip(conn, r, "2", opShutdown, map[string]any{})
}

// roundTrip sends one request and waits for its answer.
func roundTrip(conn net.Conn, r *bufio.Reader, id, op string, params any) error {
	b, err := json.Marshal(map[string]any{"id": id, "op": op, "params": params})
	if err != nil {
		return fmt.Errorf("chatengine: encoding %s: %w", op, err)
	}
	if _, err := conn.Write(append(b, '\n')); err != nil {
		return fmt.Errorf("chatengine: sending %s: %w", op, err)
	}
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return fmt.Errorf("chatengine: no answer to %s: %w", op, err)
		}
		var a struct {
			ID    string `json:"id"`
			OK    bool   `json:"ok"`
			Error *struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(line, &a) != nil || a.ID != id {
			continue
		}
		if !a.OK {
			code := "internal"
			if a.Error != nil {
				code = a.Error.Code
			}
			return fmt.Errorf("chatengine: %s refused (%s)", op, code)
		}
		return nil
	}
}

// sessionGroup is one session ShutdownSessions reaps.
type sessionGroup struct {
	pgid     int
	pgidPath string
}

// ShutdownSessions is `watchtower chat shutdown`, the fallback when no
// engine answers on chat.sock: every session socket gets `cancel` and
// `close`; the sessions' groups (their group files, each checked to still
// be that conversation's `ai session`) get SIGTERM after closeGrace and
// SIGKILL after killAfter more. The rows are finalised by the next engine's
// startup sweep (session_lost).
func ShutdownSessions(ctx context.Context, workspaceDir, tempDir string) error {
	for _, path := range listSessionSockets(workspaceDir, tempDir) {
		conn, _, err := connectSession(ctx, path)
		if err != nil {
			if errors.Is(err, errStaleSocket) {
				_ = os.Remove(path)
			}
			continue
		}
		for _, c := range []string{chat.CommandCancel, chat.CommandClose} {
			b, _ := json.Marshal(chat.Command{Type: c})
			_, _ = conn.Write(append(b, '\n'))
		}
		_ = conn.Close()
	}
	groups := sessionGroups(filepath.Join(workspaceDir, "chatengine", "sessions"), psArgs)
	alive := func() []sessionGroup {
		var out []sessionGroup
		for _, g := range groups {
			if err := syscall.Kill(-g.pgid, 0); !errors.Is(err, syscall.ESRCH) {
				out = append(out, g)
			}
		}
		return out
	}
	groups = waitGroups(ctx, alive, closeGrace)
	for _, g := range groups {
		_ = syscall.Kill(g.pgid, syscall.SIGTERM)
	}
	groups = waitGroups(ctx, alive, killAfter)
	for _, g := range groups {
		_ = syscall.Kill(-g.pgid, syscall.SIGKILL)
	}
	if left := waitGroups(ctx, alive, orphanWait); len(left) > 0 {
		log.Printf("chatengine: %d chat session groups are still there after SIGKILL", len(left))
	}
	removeGroupFiles(filepath.Join(workspaceDir, "chatengine", "sessions"), psArgs)
	return ctx.Err()
}

// sessionGroups reads the live chat session groups from dir's group files.
func sessionGroups(dir string, args func(int) (string, error)) []sessionGroup {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []sessionGroup
	for _, de := range entries {
		name := de.Name()
		if !de.Type().IsRegular() || !strings.HasSuffix(name, ".pgid") {
			continue
		}
		path := filepath.Join(dir, name)
		conv, err1 := strconv.ParseInt(strings.TrimSuffix(name, ".pgid"), 10, 64)
		b, err2 := os.ReadFile(path)
		pgid, err3 := strconv.Atoi(strings.TrimSpace(string(b)))
		if err1 == nil && err2 == nil && err3 == nil && pgid > 1 && isChatSessionArgs(args, pgid, conv) {
			out = append(out, sessionGroup{pgid: pgid, pgidPath: path})
		}
	}
	return out
}

// removeGroupFiles removes every group file whose group is no longer a
// live chat session.
func removeGroupFiles(dir string, args func(int) (string, error)) {
	live := map[string]bool{}
	for _, g := range sessionGroups(dir, args) {
		live[g.pgidPath] = true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, de := range entries {
		if path := filepath.Join(dir, de.Name()); strings.HasSuffix(de.Name(), ".pgid") && !live[path] {
			_ = os.Remove(path)
		}
	}
}

// waitGroups polls until no group is alive or wait passed, and returns the
// ones still alive.
func waitGroups(ctx context.Context, alive func() []sessionGroup, wait time.Duration) []sessionGroup {
	deadline := time.Now().Add(wait)
	for {
		left := alive()
		if len(left) == 0 || !time.Now().Before(deadline) || ctx.Err() != nil {
			return left
		}
		time.Sleep(50 * time.Millisecond)
	}
}
