package cmd

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/tools"
)

// jiraAccountClient builds a per-account Jira client the way the sync wiring
// does: the account's token file + the resolved OAuth client credentials.
func jiraAccountClient(cfg *config.Config, account db.JiraAccount) (*jira.Client, error) {
	store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
	if !store.Exists() {
		return nil, fmt.Errorf("jira account #%d has no token; run 'watchtower jira login --account %d'", account.ID, account.ID)
	}
	if account.CloudID == "" {
		return nil, fmt.Errorf("jira account #%d has no cloud id; run 'watchtower jira login --account %d'", account.ID, account.ID)
	}
	return jira.NewClient(account.CloudID, resolveJiraOAuthConfig(), store), nil
}

// jiraClientFactory serves create_jira_issue.
func jiraClientFactory(cfg *config.Config) tools.JiraClientFactory {
	return func(account db.JiraAccount) (tools.JiraIssueClient, error) {
		c, err := jiraAccountClient(cfg, account)
		if err != nil {
			return nil, err // never a typed-nil *jira.Client inside the interface
		}
		return c, nil
	}
}

// jiraWriteClientFactory serves the four existing-issue write tools.
func jiraWriteClientFactory(cfg *config.Config) tools.JiraWriteClientFactory {
	return func(account db.JiraAccount) (tools.JiraWriteClient, error) {
		c, err := jiraAccountClient(cfg, account)
		if err != nil {
			return nil, err
		}
		return c, nil
	}
}

// jiraConnectFactory builds the per-account board client + board analyzer
// connect_jira_board needs, the way runJiraBoards/runJiraBoardsAnalyze do.
func jiraConnectFactory(cfg *config.Config, database *db.DB) tools.JiraConnectFactory {
	return func(account db.JiraAccount) (tools.JiraConnect, error) {
		client, err := jiraAccountClient(cfg, account)
		if err != nil {
			return tools.JiraConnect{}, err
		}
		analyzer := jira.NewBoardAnalyzer(client, database, newAIClient(cfg, cfg.DBPath()), account.ID)
		analyzer.SetLanguage(cfg.Digest.Language)
		return tools.JiraConnect{Client: client, Profiler: analyzer}, nil
	}
}

// buildToolRegistry is the ONE place the assistant's tools are assembled —
// shared by `mcp --chat`, `actions …`, `jira create` and the runtime-B
// `ai query --tools chat` ollama loop, so the entry points can never disagree
// about what exists.
func buildToolRegistry(cfg *config.Config, database *db.DB) *tools.Registry {
	reg := tools.New(database)
	regTools := []*tools.Tool{
		tools.NewCreateTarget(),
		tools.NewCreateJiraIssue(jiraClientFactory(cfg)),
	}
	regTools = append(regTools, tools.JiraWriteTools(jiraWriteClientFactory(cfg))...)
	regTools = append(regTools,
		tools.NewConnectJiraBoard(jiraConnectFactory(cfg, database)),
		tools.NewCreateTrack(),
		tools.NewCreateIdea(),
		tools.NewRemindMe(),
		tools.NewBriefContext(),
	)
	// The project tools (surface "project" only): mounted by `mcp --project N`,
	// which applies them directly under Binding.DirectApply (DEV-06).
	regTools = append(regTools, tools.ProjectTools()...)
	// Every migrated read tool. Chat mode dispatches these through the registry's
	// read branch; the runtime-B loop calls them in-process. Dev-mode MCP mounts
	// the same list via tools.NewReadRegistry.
	regTools = append(regTools, tools.ReadTools()...)
	for _, t := range regTools {
		if err := reg.Register(t); err != nil {
			panic("tool registry: " + err.Error())
		}
	}
	return reg
}
