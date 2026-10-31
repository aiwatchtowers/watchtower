package sessionhost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"slices"
	"strings"
	"sync"
)

// ErrHostV1 is returned by Dial (and Ensure) when the socket is served by a
// protocol v1 host. The Go hub never talks to one; only Desktop's one-time
// restart step replaces it.
var ErrHostV1 = errors.New("sessionhost: a v1 host is running")

// HostError is an Error frame the host answered a request with.
type HostError struct{ Message string }

func (e *HostError) Error() string { return "sessionhost: " + e.Message }

// v1Refusal is how a v1 host refuses a v2 hello (its fixed message).
const v1Refusal = "(host speaks 1)"

// Client is a non-attaching v2 client: it lists, launches detached, types
// with InputTo, delivers lines (Deliver), hints and stops, and never binds its connection to a
// session, so it never takes a pane over. Calls are serialised.
type Client struct {
	mu  sync.Mutex
	nc  net.Conn
	pid int
}

// Dial connects to the host on socket and says a v2 Hello. A v1 host gives
// ErrHostV1; nothing listening gives the dial error.
func Dial(ctx context.Context, socket string) (*Client, error) {
	var d net.Dialer
	nc, err := d.DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, fmt.Errorf("dial session host: %w", err)
	}
	c := &Client{nc: nc}
	if err := c.hello(ctx); err != nil {
		_ = nc.Close()
		return nil, err
	}
	return c, nil
}

func (c *Client) hello(ctx context.Context) error {
	_, p, err := c.roundTrip(ctx, Hello, encode(HelloMsg{Version: ProtocolVersion}), HelloOK)
	if err != nil {
		var he *HostError
		if errors.As(err, &he) && strings.Contains(he.Message, v1Refusal) {
			return ErrHostV1
		}
		return fmt.Errorf("session host hello: %w", err)
	}
	var h HelloMsg
	if err := json.Unmarshal(p, &h); err != nil {
		return fmt.Errorf("session host hello: %w", err)
	}
	if h.Version < ProtocolVersion {
		return ErrHostV1
	}
	c.pid = h.Pid
	return nil
}

// Pid is the host's process id from its HelloOK.
func (c *Client) Pid() int { return c.pid }

// Close closes the connection; hosted sessions keep running.
func (c *Client) Close() error {
	return c.nc.Close() //nolint:wrapcheck // the connection's own close error
}

// List returns every hosted session of every scope.
func (c *Client) List(ctx context.Context) ([]SessionInfo, error) {
	_, p, err := c.roundTrip(ctx, List, nil, Listed)
	if err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	var resp ListResp
	if err := json.Unmarshal(p, &resp); err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	return resp.Sessions, nil
}

// Launch starts a session. The client never binds, so Detach is always set.
func (c *Client) Launch(ctx context.Context, r LaunchReq) (SessionInfo, error) {
	r.Detach = true
	_, p, err := c.roundTrip(ctx, Launch, encode(r), Launched)
	if err != nil {
		return SessionInfo{}, fmt.Errorf("launch: %w", err)
	}
	var info SessionInfo
	if err := json.Unmarshal(p, &info); err != nil {
		return SessionInfo{}, fmt.Errorf("launch: %w", err)
	}
	return info, nil
}

// InputTo writes r.Data to the session's PTY. A wrong run or launch, or a run
// that exited, is refused.
func (c *Client) InputTo(ctx context.Context, r InputToReq) error {
	if err := c.fireAndSync(ctx, InputTo, encode(r)); err != nil {
		return fmt.Errorf("input_to: %w", err)
	}
	return nil
}

// PromptHint tells the host whether a permission dialog is up in a session.
func (c *Client) PromptHint(ctx context.Context, m PromptHintMsg) error {
	if err := c.fireAndSync(ctx, PromptHint, encode(m)); err != nil {
		return fmt.Errorf("prompt_hint: %w", err)
	}
	return nil
}

// Forget drops an exited session's record.
func (c *Client) Forget(ctx context.Context, row int64, run string) error {
	if _, _, err := c.roundTrip(ctx, Forget, encode(AttachReq{Row: row, Run: run}), Forgot); err != nil {
		return fmt.Errorf("forget: %w", err)
	}
	return nil
}

// Stop asks the host to stop a session and returns once it answered
// Stopping; the Exit (Requested) follows on the attached clients and in List.
// alreadyExited: the run had exited before the request, so the stop did
// nothing and its exit stays natural.
func (c *Client) Stop(ctx context.Context, r StopReq) (alreadyExited bool, err error) {
	_, p, err := c.roundTrip(ctx, Stop, encode(r), Stopping)
	if err != nil {
		return false, fmt.Errorf("stop: %w", err)
	}
	var m StoppingMsg
	if len(p) > 0 {
		if err := json.Unmarshal(p, &m); err != nil {
			return false, fmt.Errorf("stop: %w", err)
		}
	}
	return m.AlreadyExited, nil
}

// fireAndSync sends a frame the host answers only on failure, then a List as
// a barrier: the host handles a connection's frames in order, so an Error
// for the first frame arrives before Listed.
func (c *Client) fireAndSync(ctx context.Context, t FrameType, p []byte) error {
	_, _, err := c.do(ctx, func() (FrameType, []byte, error) {
		if err := WriteFrame(c.nc, t, p); err != nil {
			return 0, nil, err
		}
		ft, rp, err := c.exchangeLocked(List, nil, Listed)
		var he *HostError
		if errors.As(err, &he) {
			// The barrier's Listed still follows the Error; read it so
			// the next call starts in step.
			for {
				dt, _, derr := ReadFrame(c.nc)
				if derr != nil {
					return 0, nil, derr
				}
				if dt == Listed {
					break
				}
			}
		}
		return ft, rp, err
	})
	return err
}

func (c *Client) roundTrip(ctx context.Context, t FrameType, p []byte, want FrameType) (FrameType, []byte, error) {
	return c.do(ctx, func() (FrameType, []byte, error) { return c.exchangeLocked(t, p, want) })
}

// do runs one exchange under the lock with ctx's deadline and cancellation.
// Any failure but a host Error leaves the stream out of step, so the
// connection is closed and later calls fail.
func (c *Client) do(ctx context.Context, fn func() (FrameType, []byte, error)) (FrameType, []byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return 0, nil, err //nolint:wrapcheck // the caller wraps with the operation
	}
	dl, _ := ctx.Deadline() // zero = no deadline
	_ = c.nc.SetDeadline(dl)
	stop := context.AfterFunc(ctx, func() { _ = c.nc.Close() })
	defer stop()
	ft, p, err := fn()
	var he *HostError
	if err != nil && !errors.As(err, &he) {
		_ = c.nc.Close()
		if ctxErr := ctx.Err(); ctxErr != nil {
			return 0, nil, ctxErr //nolint:wrapcheck // the caller wraps with the operation
		}
	}
	return ft, p, err
}

// exchangeLocked writes one request and reads until want or an Error. Other
// frames are skipped (an unbound connection gets none today; a newer host
// may add some).
func (c *Client) exchangeLocked(t FrameType, p []byte, want FrameType) (FrameType, []byte, error) {
	if err := WriteFrame(c.nc, t, p); err != nil {
		return 0, nil, err
	}
	return c.readUntil(want)
}

// readUntil reads until want (returned) or an Error (a *HostError).
func (c *Client) readUntil(want FrameType) (FrameType, []byte, error) {
	return c.readUntilAny(want)
}

// readUntilAny reads until one of want (returned) or an Error (a
// *HostError).
func (c *Client) readUntilAny(want ...FrameType) (FrameType, []byte, error) {
	for {
		ft, rp, err := ReadFrame(c.nc)
		if err != nil {
			return 0, nil, err
		}
		if slices.Contains(want, ft) {
			return ft, rp, nil
		}
		if ft == Error {
			var m ErrorMsg
			_ = json.Unmarshal(rp, &m) // a malformed Error still fails the call
			return ft, nil, &HostError{Message: m.Message}
		}
	}
}
