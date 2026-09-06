package cmd

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/tools"
)

// jiraClientFactory builds a per-account Jira client the way the sync wiring
// does: the account's token file + the resolved OAuth client credentials.
func jiraClientFactory(cfg *config.Config) tools.JiraClientFactory {
	return func(account db.JiraAccount) (tools.JiraIssueClient, error) {
		store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
		if !store.Exists() {
			return nil, fmt.Errorf("jira account #%d has no token; run 'watchtower jira login --account %d'", account.ID, account.ID)
		}
		if account.CloudID == "" {
			return nil, fmt.Errorf("jira account #%d has no cloud id; run 'watchtower jira login --account %d'", account.ID, account.ID)
		}
		return jira.NewClient(account.CloudID, resolveJiraOAuthConfig(), store), nil
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
