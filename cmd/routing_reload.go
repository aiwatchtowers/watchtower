package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/sessions"
)

type routingGeneration struct {
	cfg           *config.Config
	gen           digest.Generator
	revision      string
	savedRevision string
}

type routingJobKey struct{}

// daemonRouting publishes a complete immutable generation. Every persistent
// pipeline keeps this dispatcher; its job context selects the actual factory.
// The scheduler, executors, pipeline caches and checkpoints are never replaced.
type daemonRouting struct {
	*providerrouting.ContextGenerator
	current       atomic.Pointer[routingGeneration]
	pool          *sessions.SessionPool
	base          *config.Config
	providerPin   string
	build         func(*config.Config) digest.Generator
	load          func(string) (*config.Config, error)
	ackFailed     routingApplication
	ackError      string
	ackRetryAfter time.Time
	ackRetryDelay time.Duration
}

func newDaemonRouting(cfg *config.Config) *daemonRouting {
	workers := cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}
	r := &daemonRouting{pool: sessions.NewSessionPool(workers), base: cfg, providerPin: flagProvider, load: config.Load}
	r.build = func(c *config.Config) digest.Generator { return pooledGeneratorFor(c, r.pool) }
	r.publish(cfg)
	r.ContextGenerator = providerrouting.NewContextGenerator(func(ctx context.Context) digest.Generator { return r.generation(ctx).gen })
	return r
}

func (r *daemonRouting) publish(saved *config.Config) {
	// Only AI inputs reload. Keep the daemon's workspace and non-AI lifecycle.
	cfg := *r.base
	cfg.AI = saved.AI
	cfg.AI.ConfiguredProvider = saved.AI.ConfiguredProviderID()
	cfg.AI.Providers = maps.Clone(saved.AI.Providers)
	cfg.ClaudePath, cfg.CodexPath = saved.ClaudePath, saved.CodexPath
	savedRevision := providers.RoutingRevision(saved)
	if r.providerPin != "" {
		cfg.AI.Provider = r.providerPin
		cfg.AI.Fallback.Enabled = false
	}
	gen := &routingGeneration{cfg: &cfg, revision: providers.RoutingRevision(&cfg), savedRevision: savedRevision}
	gen.gen = r.build(&cfg)
	workers := cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}
	r.pool.Resize(workers)
	r.current.Store(gen)
}

func (r *daemonRouting) generation(ctx context.Context) *routingGeneration {
	if g, ok := ctx.Value(routingJobKey{}).(*routingGeneration); ok {
		return g
	}
	return r.current.Load()
}

func bindRouting(ctx context.Context, g *routingGeneration) context.Context {
	return config.WithRoutingSnapshot(context.WithValue(ctx, routingJobKey{}, g), g.cfg)
}

func (r *daemonRouting) bind(ctx context.Context) context.Context {
	return bindRouting(ctx, r.generation(ctx))
}

func (r *daemonRouting) bindSync(ctx, fetchCtx context.Context) (context.Context, context.Context) {
	g := r.current.Load()
	return bindRouting(ctx, g), bindRouting(fetchCtx, g)
}

// routingBackends binds language, agent preflight/clients, registry and SDK.llm
// to the same generation. Inline primitives inherit the enclosing sync job.
func routingBackends(cfg *config.Config, database *db.DB, gen digest.Generator) automations.Backends {
	b := automationBackends(cfg, database, gen)
	if r, ok := gen.(*daemonRouting); ok {
		b.ForJob = func(ctx context.Context, original automations.Backends) (context.Context, automations.Backends) {
			ctx = r.bind(ctx)
			next := automationBackends(r.generation(ctx).cfg, database, r)
			next.Agent = &pooledAutomationAgent{inner: next.Agent, pool: r.pool}
			next.Primitives, next.DefaultPrompt = original.Primitives, original.DefaultPrompt
			return ctx, next
		}
	}
	return b
}

// routingApplication is local metadata only. Identity is the existing
// kernel-start-qualified PID file, not a PID-alive guess or an extra daemon.
type routingApplication struct {
	SavedVersion      string `json:"saved_version"`
	Identity          string `json:"identity"`
	Revision          string `json:"revision"`
	PreferredProvider string `json:"preferred_provider"`
	Error             string `json:"error,omitempty"`
}

func routingAckPath(cfg *config.Config) string { return pidFilePath(cfg) + ".routing.json" }

func writeRoutingAck(path string, ack routingApplication) error {
	data, err := json.Marshal(ack)
	if err != nil {
		return err
	}
	if old, readErr := os.ReadFile(path); readErr == nil && bytes.Equal(old, data) {
		return nil
	}
	return fsutil.WriteFileAtomic(path, data, 0o600)
}

func readRoutingApplication(cfg *config.Config) (*routingApplication, error) {
	return readRoutingAck(routingAckPath(cfg), func() (string, error) {
		pid, err := daemon.FindConfirmedProcess(pidFilePath(cfg))
		if err != nil {
			return "", fmt.Errorf("confirming background process identity: %w", err)
		}
		if pid == 0 {
			return "", nil
		}
		identity, err := os.ReadFile(pidFilePath(cfg))
		if os.IsNotExist(err) {
			return "", nil
		}
		if err != nil {
			return "", fmt.Errorf("reading background process identity: %w", err)
		}
		return strings.TrimSpace(string(identity)), nil
	})
}

func readRoutingAck(path string, identity func() (string, error)) (*routingApplication, error) {
	current, err := identity()
	if err != nil || current == "" {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading AI configuration acknowledgement: %w", err)
	}
	var ack routingApplication
	if err := json.Unmarshal(data, &ack); err != nil {
		return nil, fmt.Errorf("decoding AI configuration acknowledgement: %w", err)
	}
	if ack.Identity != current {
		return nil, nil
	}
	// Reject replacement during the read, including a reused PID.
	latest, err := identity()
	if err != nil {
		return nil, err
	}
	if latest != current {
		return nil, nil
	}
	return &ack, nil
}

// watch re-reads saved state (Retry never writes config). Publication precedes
// ack: an ack-write failure leaves the new runtime installed and confirmation
// unknown; it never rolls active jobs back to an older generation.
func (r *daemonRouting) watch(ctx context.Context, configPath string, logger *log.Logger) {
	var identity string
	var identityError string
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		if identity == "" {
			data, err := os.ReadFile(pidFilePath(r.base))
			if err != nil {
				if identityError != err.Error() {
					logger.Printf("AI routing process identity: %v", err)
					identityError = err.Error()
				}
			} else {
				identity = strings.TrimSpace(string(data))
			}
		}
		r.refresh(configPath, identity, writeRoutingAck, logger)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func (r *daemonRouting) refresh(configPath, identity string, write func(string, routingApplication) error, logger *log.Logger) {
	version := routingSavedVersion(configPath)
	saved, err := r.load(configPath)
	if version != routingSavedVersion(configPath) {
		return
	}
	if err == nil && providers.RoutingRevision(saved) != r.current.Load().savedRevision {
		r.publish(saved)
	}
	g := r.current.Load()
	ack := routingApplication{SavedVersion: version, Identity: identity, Revision: g.revision, PreferredProvider: g.cfg.AI.Provider}
	if err != nil {
		ack.Error = "Could not read saved AI settings"
	}
	if r.providerPin != "" && (g.cfg.AI.Provider != g.cfg.AI.ConfiguredProviderID() || g.savedRevision != g.revision) {
		ack.Error = "The background process has an explicit provider override"
	}
	if identity == "" {
		return
	}
	if ack == r.ackFailed && time.Now().Before(r.ackRetryAfter) {
		return
	}
	if err := write(routingAckPath(r.base), ack); err != nil {
		if r.ackError != err.Error() {
			logger.Printf("AI routing acknowledgement: %v", err)
		}
		r.ackError, r.ackFailed = err.Error(), ack
		r.ackRetryDelay = min(max(500*time.Millisecond, r.ackRetryDelay*2), 30*time.Second)
		r.ackRetryAfter = time.Now().Add(r.ackRetryDelay)
	} else {
		r.ackError, r.ackRetryDelay = "", 0
	}
}

// routingSavedVersion distinguishes separate atomic Saves even when normalized
// routing inputs return A→B→A. It is only a causal file version, never a second
// routing hash or configuration writer.
func routingSavedVersion(path string) string {
	if path == "" {
		path = defaultConfigPath()
	}
	info, err := os.Stat(path)
	if err != nil {
		return ""
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return fmt.Sprintf("%d:%d:%d:%d", stat.Dev, stat.Ino, info.ModTime().UnixNano(), info.Size())
	}
	return ""
}

// pooledAutomationAgent preserves provider preparation and one started tool loop
// while sharing admission with all sync/SDK generator generations.
type pooledAutomationAgent struct {
	inner automations.AgentRunner
	pool  *sessions.SessionPool
}

func (a *pooledAutomationAgent) Name() string { return a.inner.Name() }
func (a *pooledAutomationAgent) Prepare(ctx context.Context, tier string) (automations.AgentRunner, error) {
	inner := a.inner
	if prepare, ok := inner.(automations.AgentPreparer); ok {
		var err error
		inner, err = prepare.Prepare(ctx, tier)
		if err != nil {
			return nil, err
		}
	}
	return &pooledAutomationAgent{inner: inner, pool: a.pool}, nil
}
func (a *pooledAutomationAgent) Run(ctx context.Context, req automations.AgentRequest) (automations.AgentResult, error) {
	ctx, cancel := context.WithDeadline(ctx, req.Deadline)
	defer cancel()
	worker, err := a.pool.Acquire(ctx)
	if err != nil {
		return automations.AgentResult{}, fmt.Errorf("waiting for AI worker: %w", err)
	}
	defer a.pool.Release(worker)
	return a.inner.Run(ctx, req)
}
