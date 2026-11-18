package chatengine

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
)

// Dial connects to chat.sock at socketPath and reads the server's greeting
// ({"event":"ready","protocol":N}); only then may the client send its hello
// (a byte sent earlier closes the connection). r reads the answers and
// events that follow. ctx bounds the dial and the greeting's wait.
func Dial(ctx context.Context, socketPath string) (conn net.Conn, r *bufio.Reader, err error) {
	var d net.Dialer
	conn, err = d.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return nil, nil, fmt.Errorf("chatengine: dialing chat.sock: %w", err)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	r = bufio.NewReader(conn)
	line, err := r.ReadBytes('\n')
	if err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("chatengine: no greeting on chat.sock: %w", err)
	}
	var g struct {
		Event    string `json:"event"`
		Protocol int    `json:"protocol"`
	}
	if err := json.Unmarshal(line, &g); err != nil || g.Event != eventReady || g.Protocol < 1 {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("chatengine: chat.sock did not greet")
	}
	if ctx.Err() != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("chatengine: dialing chat.sock: %w", ctx.Err())
	}
	return conn, r, nil
}
