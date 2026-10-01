package externalmcp

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"

	"github.com/modelcontextprotocol/go-sdk/mcp"

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
// exchange; a stdio server is started for the call and stopped (and reaped)
// before ListTools returns.
func ListTools(ctx context.Context, spec ServerSpec) ([]db.ExternalTool, error) {
	transport, err := discoveryTransport(ctx, spec)
	if err != nil {
		return nil, err
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "watchtower", Version: "1"}, nil)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return nil, fmt.Errorf("connecting to the server: %w", err)
	}
	// Close stops (and reaps) a stdio server; its error only says how the
	// server went away, which cannot change a listing already taken.
	defer func() { _ = session.Close() }()

	tools := []db.ExternalTool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			return nil, fmt.Errorf("listing tools: %w", err)
		}
		t := db.ExternalTool{Name: tool.Name}
		if tool.Annotations != nil {
			t.Annotated = true
			t.ReadOnlyHint = tool.Annotations.ReadOnlyHint
		}
		tools = append(tools, t)
	}
	return tools, nil
}

func discoveryTransport(ctx context.Context, spec ServerSpec) (mcp.Transport, error) {
	switch spec.Kind {
	case "stdio":
		cmd := exec.CommandContext(ctx, spec.Command, spec.Args...)
		// The vendor CLI starts stdio servers with the config's env on top of
		// its own; mirror that. A neutral cwd keeps the server's startup from
		// probing a TCC-protected folder on Watchtower's behalf.
		cmd.Env = os.Environ()
		for k, v := range spec.Env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		cmd.Dir = os.TempDir()
		return &mcp.CommandTransport{Command: cmd}, nil
	case "http":
		return &mcp.StreamableClientTransport{
			Endpoint:             spec.URL,
			HTTPClient:           &http.Client{Transport: headerTransport{headers: spec.Headers}},
			MaxRetries:           -1,
			DisableStandaloneSSE: true,
		}, nil
	default:
		return nil, fmt.Errorf("unknown connection kind %q", spec.Kind)
	}
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
