package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// automationMCPTimeout bounds one automation tool call (connect, call, stop).
const automationMCPTimeout = 30 * time.Second

// callServerTool is externalmcp.CallTool; a var so tests can probe the call.
var callServerTool = externalmcp.CallTool

// automationMCPCaller is the automations.MCPCaller over the owner's Quick
// Connections.
type automationMCPCaller struct {
	cfg      *config.Config
	database *db.DB
}

func newAutomationMCPCaller(cfg *config.Config, database *db.DB) automations.MCPCaller {
	return &automationMCPCaller{cfg: cfg, database: database}
}

// Call runs tool on the enabled connection named exactly server, only under
// QC-02's verdict (externalmcp.ResolveTools on the cached listing). An
// automation never lists tools itself: a never-listed connection is not
// available until the chat's launch-time listing or `connections tools
// --refresh` lists it. The tool is checked before credentials are resolved
// or any process starts.
func (m *automationMCPCaller) Call(ctx context.Context, server, tool string, args json.RawMessage) (json.RawMessage, error) {
	conns, err := m.database.ListEnabledExternalConnections()
	if err != nil {
		return nil, fmt.Errorf("%w: listing connections: %v", automations.ErrMCPNotAvailable, err)
	}
	i := slices.IndexFunc(conns, func(c db.ExternalConnection) bool { return c.Name == server })
	if i < 0 {
		return nil, fmt.Errorf("%w: no enabled connection named %q", automations.ErrMCPNotAvailable, server)
	}
	c := conns[i]
	if !c.ToolsListed {
		return nil, fmt.Errorf("%w: %q's tools were never listed — `watchtower connections tools %d --refresh`",
			automations.ErrMCPNotAvailable, server, c.ID)
	}
	allowed, _ := externalmcp.ResolveTools(c)
	if len(allowed) == 0 {
		return nil, fmt.Errorf("%w: none of %q's tools is allowed", automations.ErrMCPNotAvailable, server)
	}
	if !slices.Contains(allowed, tool) {
		return nil, fmt.Errorf("%w: %s on %q", automations.ErrMCPToolNotAllowed, tool, server)
	}
	spec, err := connectionServer(m.cfg, m.database, c)
	if err != nil {
		return nil, fmt.Errorf("%w: %q's credentials: %v", automations.ErrMCPNotAvailable, server, err)
	}
	callCtx, cancel := context.WithTimeout(ctx, automationMCPTimeout)
	defer cancel()
	return callServerTool(callCtx, serverSpec(spec), tool, args)
}
