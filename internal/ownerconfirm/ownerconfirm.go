// Package ownerconfirm asks the running Watchtower Desktop to confirm an
// owner-only CLI gesture (AGENT-07, board #568, owner decision ask #357): the
// CLI sends one request over the Unix socket the Desktop serves in the
// workspace directory, checks that the process answering is the Watchtower
// app signed by the CLI's own team, and waits for the owner's click in the
// Desktop's confirmation window. The Desktop answers the commands it started
// itself without a window.
//
// The wire format is one JSON line each way and is a contract shared with
// WatchtowerDesktop's OwnerConfirmServer (WatchtowerCore).
//
// What it protects against: an agent talked into running an owner-only
// command (a prompt injection). Not against a malicious program running as
// the owner, which can write the database itself.
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
	// or the Desktop refused the request (another window open, too many).
	Denied = "denied"
)

// ErrNoDesktop is Ask's error when no Desktop answers on the socket.
var ErrNoDesktop = errors.New("no Watchtower Desktop is running for this workspace")

// ErrUntrustedPeer is Ask's error when the process serving the socket is not
// the signed Watchtower app.
var ErrUntrustedPeer = errors.New("the process answering on the confirmation socket is not the signed Watchtower app")

// Request is what the CLI asks the Desktop to confirm.
type Request struct {
	V int `json:"v"`
	// Verb says what is being confirmed, e.g. "approve an action".
	Verb string `json:"verb"`
	// Detail is what the window shows about the object, in full: the
	// action's args, the recipe, the lesson, the hunk.
	Detail string `json:"detail,omitempty"`
	// Args is the CLI's argv without the program name: the command the
	// window shows, and what the Desktop matches its own launches against.
	Args []string `json:"args"`
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

// VerifyPeer checks the pid serving the socket; tests replace it.
var VerifyPeer = VerifyDesktop

// Ask sends req to the Desktop on socketPath and waits for its reply until
// ctx ends. ErrNoDesktop when nothing listens there; ErrUntrustedPeer when
// the listener fails VerifyPeer — checked before the request is sent, so an
// impostor never sees it and its answer is never read.
func Ask(ctx context.Context, socketPath string, req Request) (Reply, error) {
	var d net.Dialer
	dialCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	conn, err := d.DialContext(dialCtx, "unix", socketPath)
	cancel()
	if err != nil {
		return Reply{}, fmt.Errorf("%w: %v", ErrNoDesktop, err)
	}
	defer func() { _ = conn.Close() }()
	pid, err := peerPID(conn)
	if err != nil {
		return Reply{}, fmt.Errorf("%w: %v", ErrUntrustedPeer, err)
	}
	if err := VerifyPeer(ctx, pid); err != nil {
		return Reply{}, fmt.Errorf("%w: %v", ErrUntrustedPeer, err)
	}
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
	raw, err := bufio.NewReader(io.LimitReader(conn, 64<<10)).ReadBytes('\n')
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
