package externalmcp

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/claude"
	"watchtower/internal/db"
)

// ServerSpec is what ListTools needs to reach one connection's server: the
// row's transport fields plus its secret's env/headers (an OAuth bearer
// already folded into Headers by the caller).
type ServerSpec struct {
	Kind    string // "stdio" | "http"
	Command string
	Args    []string
	URL     string
	Env     map[string]string
	Headers map[string]string
}

// ListTools connects to the server, runs tools/list (all pages) and returns
// each tool's name and annotations for the QC-02 policy. ctx bounds the whole
// exchange; a stdio server is started for the call in its own process group,
// and the group is stopped before ListTools returns.
func ListTools(ctx context.Context, spec ServerSpec) ([]db.ExternalTool, error) {
	transport, stderr, err := discoveryTransport(ctx, spec)
	if err != nil {
		return nil, err
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "watchtower", Version: "1"}, nil)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return nil, withStderr(fmt.Errorf("connecting to the server: %w", err), stderr)
	}
	// Close stops a stdio server; its error only says how the server went
	// away, which cannot change a listing already taken.
	defer func() { _ = session.Close() }()
	if ct, ok := transport.(*mcp.CommandTransport); ok {
		// Runs before Close (defers are LIFO), while the leader is still
		// alive and its group id cannot have been reused.
		defer killProcessGroup(ct.Command)
	}

	tools := []db.ExternalTool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			return nil, withStderr(fmt.Errorf("listing tools: %w", err), stderr)
		}
		t := db.ExternalTool{Name: tool.Name}
		if tool.Annotations != nil {
			t.Annotated = true
			t.ReadOnlyHint = tool.Annotations.ReadOnlyHint
			t.DestructiveHint = tool.Annotations.DestructiveHint != nil && *tool.Annotations.DestructiveHint
		}
		tools = append(tools, t)
	}
	return tools, nil
}

// stderrHeadLimit bounds how much of a stdio server's stderr a failed
// listing quotes.
const stderrHeadLimit = 2048

// discoveryTransport builds the transport for spec, plus (stdio only) the
// buffer collecting the server's stderr for error messages.
func discoveryTransport(ctx context.Context, spec ServerSpec) (mcp.Transport, *headBuffer, error) {
	switch spec.Kind {
	case "stdio":
		path := claude.RichPATH() // version-manager and Homebrew dirs first
		cmd := exec.CommandContext(ctx, lookPathIn(spec.Command, path), spec.Args...)
		// The vendor CLI starts stdio servers with its rich PATH and the
		// config's env on top of its own; mirror both, so a server that works
		// in chat also lists. A neutral cwd keeps the server's startup from
		// probing a TCC-protected folder on Watchtower's behalf.
		cmd.Env = append(os.Environ(), "PATH="+path)
		for k, v := range spec.Env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		cmd.Dir = os.TempDir()
		// Own process group, so a wrapper's children (npx → node) are
		// stopped with it on cancel and after the listing.
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		cmd.WaitDelay = 5 * time.Second
		stderr := &headBuffer{limit: stderrHeadLimit}
		cmd.Stderr = stderr
		return &mcp.CommandTransport{Command: cmd}, stderr, nil
	case "http":
		return &mcp.StreamableClientTransport{
			Endpoint:             spec.URL,
			HTTPClient:           &http.Client{Transport: headerTransport{headers: spec.Headers}},
			MaxRetries:           -1,
			DisableStandaloneSSE: true,
		}, nil, nil
	default:
		return nil, nil, fmt.Errorf("unknown connection kind %q", spec.Kind)
	}
}

// lookPathIn resolves a bare command name against path the way the vendor
// CLI's spawn would; a name with a slash, or one not found, is returned as
// is (exec then reports the error).
func lookPathIn(name, path string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, dir := range filepath.SplitList(path) {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return name
}

// killProcessGroup stops a stdio server's whole process group (a wrapper's
// children included) once the listing is done. Best effort.
func killProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

// headBuffer keeps the first limit bytes written to it (a server's startup
// error comes first) — safe for the transport's concurrent writes.
type headBuffer struct {
	mu    sync.Mutex
	buf   []byte
	limit int
}

func (b *headBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := b.limit - len(b.buf); room > 0 {
		b.buf = append(b.buf, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

func (b *headBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.TrimSpace(string(b.buf))
}

// withStderr appends the stdio server's stderr, if any, to err.
func withStderr(err error, stderr *headBuffer) error {
	if stderr == nil {
		return err
	}
	if tail := stderr.String(); tail != "" {
		return fmt.Errorf("%w (server stderr: %s)", err, tail)
	}
	return err
}

// headerTransport adds the connection's static/OAuth headers to every request.
type headerTransport struct {
	headers map[string]string
}

func (t headerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	for k, v := range t.headers {
		req.Header.Set(k, v)
	}
	return http.DefaultTransport.RoundTrip(req)
}
