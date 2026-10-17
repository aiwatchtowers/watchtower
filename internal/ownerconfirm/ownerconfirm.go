// Package ownerconfirm asks the running Watchtower Desktop to confirm an
// owner-only CLI gesture (AGENT-07, board #568, ask #306): the CLI sends one
// request over the Unix socket the Desktop serves in the workspace directory,
// the Desktop shows the owner a confirmation window and answers with the
// owner's click. The Desktop answers its own CLI calls (a button the owner
// pressed) without a window: it registers the exact argv before it starts the
// child.
//
// The wire format is one JSON line each way and is a contract shared with
// WatchtowerDesktop's OwnerConfirmServer (WatchtowerCore).
package ownerconfirm

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"time"
)

// FileName is the socket's name in the workspace directory, next to
// watchtower.db: a CLI pointed at another workspace (or another HOME) asks a
// socket that only a Desktop serving that same database answers.
const FileName = "owner-confirm.sock"

// Version is the request format the Desktop understands.
const Version = 1

// Wait bounds how long the CLI waits for the owner's click. It stays under
// Claude Code's default 2-minute command timeout, so an unanswered request
// ends as a plain refusal rather than a killed command.
const Wait = 100 * time.Second

// Decision values of a Reply.
const (
	// Confirmed: the owner clicked Confirm, or the Desktop started this exact
	// command itself.
	Confirmed = "confirmed"
	// Denied: the owner clicked Deny or closed the window, the wait ran out,
	// or another confirmation was already open.
	Denied = "denied"
)

// ErrNoDesktop is Ask's error when no Desktop answers on the socket.
var ErrNoDesktop = errors.New("no Watchtower Desktop is running for this workspace")

// Request is what the CLI asks the Desktop to confirm.
type Request struct {
	V int `json:"v"`
	// Verb says what is being confirmed, e.g. "approve an action".
	Verb string `json:"verb"`
	// Detail is an optional line about the object, e.g. the action's tool
	// and args.
	Detail string `json:"detail,omitempty"`
	// Args is the CLI's argv without the program name: the command the
	// window shows, and what the Desktop matches its own launches against.
	Args []string `json:"args"`
	// Agent names the AI agent marker set in the CLI's environment, "" when
	// none is (informational: an agent can unset it).
	Agent string `json:"agent,omitempty"`
}

// Reply is the Desktop's answer.
type Reply struct {
	Decision string `json:"decision"`
	// Reason says why a request was denied without a click (busy, timed out).
	Reason string `json:"reason,omitempty"`
}

// SocketPath is the socket of the workspace whose database is dbPath.
func SocketPath(dbPath string) string {
	return filepath.Join(filepath.Dir(dbPath), FileName)
}

// Ask sends req to the Desktop on socketPath and waits for its reply until
// ctx ends. ErrNoDesktop when nothing listens there.
func Ask(ctx context.Context, socketPath string, req Request) (Reply, error) {
	var d net.Dialer
	dialCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	conn, err := d.DialContext(dialCtx, "unix", socketPath)
	cancel()
	if err != nil {
		return Reply{}, fmt.Errorf("%w: %v", ErrNoDesktop, err)
	}
	defer func() { _ = conn.Close() }()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.SetDeadline(time.Now()) })
	defer stop()
	req.V = Version
	line, err := json.Marshal(req)
	if err != nil {
		return Reply{}, err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return Reply{}, fmt.Errorf("sending the confirmation request: %w", err)
	}
	r := bufio.NewReader(io.LimitReader(conn, 64<<10))
	raw, err := r.ReadBytes('\n')
	if err != nil {
		var ne net.Error
		if ctx.Err() != nil || (errors.As(err, &ne) && ne.Timeout()) {
			return Reply{}, fmt.Errorf("no answer from Watchtower Desktop in time: %w", err)
		}
		return Reply{}, fmt.Errorf("reading the Desktop's answer: %w", err)
	}
	var rep Reply
	if err := json.Unmarshal(raw, &rep); err != nil {
		return Reply{}, fmt.Errorf("reading the Desktop's answer: %w", err)
	}
	return rep, nil
}
