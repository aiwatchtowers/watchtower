package ollama

import (
	"net"
	"net/http"
	"time"
)

// responseHeaderTimeout bounds how long a request waits for the server's
// response headers. It is deliberately not a short total timeout: a
// non-streaming chat completion sends its headers only once the whole
// generation is done, and a local model on modest hardware can take minutes
// over a large prompt. 15 minutes sits above the daemon's own per-call bound
// (digest.DaemonAICallTimeout, 10 minutes), so that deadline still governs
// daemon calls and this one only catches a server that accepted the
// connection and then never answered. A streaming response is not cut off
// once its headers arrive. A var so tests can shorten it.
var responseHeaderTimeout = 15 * time.Minute

// NewHTTPClient returns the client for an OpenAI-compatible server: bounded
// dial, TLS handshake and wait for response headers, and no total timeout, so
// a legitimately long generation or stream is never cut short.
func NewHTTPClient() *http.Client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DialContext = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	t.TLSHandshakeTimeout = 10 * time.Second
	t.ResponseHeaderTimeout = responseHeaderTimeout
	return &http.Client{Transport: t}
}
