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
	"bytes"
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

// MaxRequestBytes is the longest request line, its newline included, that
// the Desktop reads — Swift OwnerConfirmServer.maxRequestBytes, keep the two
// equal. The detail carries an action's args in full (a Confluence page
// edit is the whole page), so it is far above any one line of text; a
// longer request is refused here, before anything is sent.
const MaxRequestBytes = 8 << 20

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

// ErrRequestTooLarge is Ask's error when the request line is longer than
// MaxRequestBytes.
var ErrRequestTooLarge = errors.New("the confirmation request is too large for Watchtower Desktop")

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
// impostor never sees it and its answer is never read; ErrRequestTooLarge,
// before dialing, when the request is over MaxRequestBytes.
func Ask(ctx context.Context, socketPath string, req Request) (Reply, error) {
	line, err := encodeRequest(req)
	if err != nil {
		return Reply{}, err
	}
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
	if _, werr := conn.Write(line); werr != nil {
		// The Desktop may have refused the request and closed the
		// connection with its reason already written: that reason is the
		// answer, not the broken pipe.
		_ = conn.SetReadDeadline(time.Now().Add(time.Second))
		if rep, rerr := readReply(conn); rerr == nil {
			return rep, nil
		}
		return Reply{}, fmt.Errorf("sending the confirmation request: Watchtower Desktop closed the connection "+
			"before reading it (%d bytes): %w", len(line), werr)
	}
	rep, err := readReply(conn)
	if err != nil {
		var ne net.Error
		if ctx.Err() != nil || (errors.As(err, &ne) && ne.Timeout()) {
			return Reply{}, fmt.Errorf("no answer from Watchtower Desktop in time: %w", err)
		}
		return Reply{}, fmt.Errorf("reading the Desktop's answer: %w", err)
	}
	return rep, nil
}

// encodeRequest is req's wire line with its newline: HTML characters are
// kept as they are (a page body full of < and > stays its own size), and a
// line over MaxRequestBytes is ErrRequestTooLarge.
func encodeRequest(req Request) ([]byte, error) {
	req.V = Version
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(req); err != nil { // Encode ends the line with '\n'
		return nil, err
	}
	if buf.Len() > MaxRequestBytes {
		return nil, fmt.Errorf("%w: %d bytes, at most %d", ErrRequestTooLarge, buf.Len(), MaxRequestBytes)
	}
	return buf.Bytes(), nil
}

// readReply reads the Desktop's one reply line.
func readReply(conn net.Conn) (Reply, error) {
	raw, err := bufio.NewReader(io.LimitReader(conn, 64<<10)).ReadBytes('\n')
	if err != nil {
		return Reply{}, err
	}
	var rep Reply
	if err := json.Unmarshal(raw, &rep); err != nil {
		return Reply{}, err
	}
	return rep, nil
}
