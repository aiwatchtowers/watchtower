package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

func routedSessionBackend(cmd *cobra.Command, cfg *config.Config, database *db.DB, dbPath string, conv *db.ChatConversation, turnFile string, project *db.ChatProjectContext, projectID int64, mcpArgs []string, cancel context.CancelFunc) (chat.Backend, error) {
	configuredPreferred := cfg.AI.ConfiguredProviderID()
	mode := conv.RoutingMode
	if mode == "" {
		mode = "pinned"
	}
	pinProvider, pinModel := conv.Provider, conv.Model
	if flagProvider != "" || cmd.Flags().Changed("model") || cmd.Flags().Changed("provider") {
		mode = "pinned"
		pinProvider, pinModel = cfg.AI.Provider, aiSessionFlagModel
		if err := providers.Allowed(pinProvider); err != nil {
			return nil, err
		}
		if err := database.SetChatRouting(conv.ID, mode, pinProvider, pinModel); err != nil {
			return nil, err
		}
	}
	if pinProvider == "" {
		pinProvider = cfg.AI.Provider
	}
	if mode == "pinned" || !cfg.AI.Fallback.Enabled {
		provider := cfg.AI.Provider
		model := ""
		reason := "fallback_disabled"
		if mode == "pinned" {
			provider = pinProvider
			model = pinModel
			reason = "explicit_pin"
		}
		if err := providers.Allowed(provider); err != nil {
			return nil, err
		}
		if model == "" {
			_, model = providers.ResolveModelsFor(cfg, provider)
		}
		backend, err := buildSessionActual(cmd.Context(), cmd, cfg, database, dbPath, conv, turnFile, project, projectID, mcpArgs, cancel, provider, model)
		if err != nil {
			return nil, err
		}
		if err := database.SetChatActual(conv.ID, provider, model, reason); err != nil {
			_ = backend.Close()
			return nil, err
		}
		return &sessionMetadataBackend{Backend: backend, ready: chat.Event{Type: chat.EventSessionReady, Provider: provider, Model: model, PreferredProvider: configuredPreferred, RoutingMode: mode, Reason: reason}}, nil
	}
	if err := cfg.AI.Validate(); err != nil {
		return nil, err
	}
	health, healthErr := providerhealth.Installation()
	if healthErr != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "AI chat routing: %v\n", healthErr)
	}
	router := &providerrouting.Router{Health: health, Diagnostic: func(err error) { fmt.Fprintf(cmd.ErrOrStderr(), "AI chat routing: %v\n", err) }}
	// This is a requirement, not a prompt decision for the reserve. It must
	// never silently disappear merely because a different backend is selected.
	requiredClaudeAI := resolveClaudeAI(cfg, aiSessionFlagSurface, conv.ID, os.Environ(), cmd.ErrOrStderr())
	sticky := conv.ActualProvider
	return chat.NewRoutingBackend(chat.RoutingOptions{
		Router: router, Mode: mode, Preferred: configuredPreferred,
		Select: func(ctx context.Context, c chat.Command) (providerrouting.Request, string, error) {
			if mode != "pinned" {
				if err := providers.Allowed(cfg.AI.Provider); err != nil {
					return providerrouting.Request{}, "policy_denied", err
				}
			}
			req := providerrouting.Request{Preferred: cfg.AI.Provider, Reserve: cfg.AI.Fallback.Provider, Mode: providerrouting.Pinned, Tier: digest.TierStrong, Profile: providers.ToolPreflight, Retry: providerrouting.BeforeChild, Revision: providers.RoutingRevision(cfg)}
			reason := "fallback_disabled"
			if mode == "pinned" {
				req.Preferred = pinProvider
				reason = "explicit_pin"
			} else if cfg.AI.Fallback.Enabled {
				req.Mode = providerrouting.PreferredReserve
				reason = ""
				if sticky == cfg.AI.Fallback.Provider {
					req.Preferred, req.Reserve = sticky, cfg.AI.Provider
					reason = "quota_exhausted"
				}
			}
			req.Model = func(p string, _ digest.Tier) string {
				if mode == "pinned" && pinModel != "" {
					return pinModel
				}
				_, m := providers.ResolveModelsFor(cfg, p)
				return m
			}
			req.CheckCapability = func(p string, _ providers.InvocationProfile) (bool, error) {
				if p == "claude" {
					return true, nil
				}
				if requiredClaudeAI.mode.On || len(chat.ProjectAttachments(project, cmd.ErrOrStderr())) > 0 {
					return false, nil
				}
				if supported, err := sessionTextAttachmentCapability(c.Attachments); err != nil || !supported {
					return supported, err
				}
				if p != cfg.AI.Provider {
					return reserveConnectionsCapable(cfg, database, p)
				}

				return p == "codex" || p == "ollama", nil
			}

			return req, reason, nil
		},
		Selected: func(p, m, reason string) error {
			if mode != "pinned" {
				sticky = p
			}
			return database.SetChatActual(conv.ID, p, m, reason)
		},
		Build: func(ctx context.Context, p, m string) (chat.Backend, error) {
			return buildSessionActual(ctx, cmd, cfg, database, dbPath, conv, turnFile, project, projectID, mcpArgs, cancel, p, m)
		},
	}), nil
}

type sessionMetadataBackend struct {
	chat.Backend
	ready chat.Event
}

func (b *sessionMetadataBackend) Start(ctx context.Context) (string, error) {
	sid, err := b.Backend.Start(ctx)
	b.ready.SessionID = sid
	return sid, err
}
func (b *sessionMetadataBackend) RoutingEvent() chat.Event { return b.ready }

func buildSessionActual(ctx context.Context, cmd *cobra.Command, cfg *config.Config, database *db.DB, dbPath string, conv *db.ChatConversation, turnFile string, project *db.ChatProjectContext, projectID int64, mcpArgs []string, cancel context.CancelFunc, p, m string) (chat.Backend, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	actual := *cfg
	actual.AI = cfg.AI
	actual.AI.Provider = p
	claudeAI := resolveClaudeAI(&actual, aiSessionFlagSurface, conv.ID, os.Environ(), cmd.ErrOrStderr())
	writeUnavailableConnectors(dbPath, claudeAI, cmd.ErrOrStderr())
	prompt, err := chat.BuildSystemPrompt(ctx, database, &actual, sessionPromptOptions(&actual, aiSessionFlagSurface, projectID, time.Now(), claudeAI.prompt))
	if err != nil {
		return nil, err
	}
	var mounted []ai.ExternalMCPServer
	backend, err := newSessionBackend(sessionWiring{cfg: &actual, database: database, dbPath: dbPath, conv: conv, model: m, prompt: prompt, mcpArgs: mcpArgs, turnFile: turnFile, project: project, chatProjectID: projectID, warn: cmd.ErrOrStderr(), claudeAI: claudeAI, onMounted: func(ext []ai.ExternalMCPServer) { mounted = ext }})
	if err != nil {
		return nil, err
	}
	return policyCheckedBackend{Backend: backend, provider: p, mounted: mounted, claudeAIOn: claudeAI.mode.On, end: cancel}, nil
}

// A connection omitted by Codex's existing env-isolation rules cannot be
// silently dropped by a reserve selection. This performs no model/tool probe.
func reserveConnectionsCapable(cfg *config.Config, database *db.DB, provider string) (bool, error) {
	if provider != "codex" {
		return true, nil
	}
	conns, err := database.ListEnabledExternalConnections()
	if err != nil {
		return false, fmt.Errorf("listing reserve Quick Connections: %w", err)
	}
	return len(codexEnvSkips(cfg, conns, os.Environ())) == 0, nil
}

func sessionTextAttachmentCapability(attachments []chat.Attachment) (bool, error) {
	_, err := chat.InlineTextAttachments("", attachments)
	if err == nil {
		return true, nil
	}
	var rejection *chat.AttachmentError
	if errors.As(err, &rejection) && rejection.RequiresClaude {
		return false, nil
	}
	return false, fmt.Errorf("checking turn attachments: %w", err)
}
