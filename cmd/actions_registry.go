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

// buildToolRegistry is the ONE place the assistant's write tools are
// assembled — shared by `mcp --chat`, `actions …` and `jira create`, so the
// three entry points can never disagree about what exists.
func buildToolRegistry(cfg *config.Config, database *db.DB) *tools.Registry {
	reg := tools.New(database)
	for _, t := range []*tools.Tool{
		tools.NewCreateTarget(),
		tools.NewCreateJiraIssue(jiraClientFactory(cfg)),
	} {
		if err := reg.Register(t); err != nil {
			panic("tool registry: " + err.Error())
		}
	}
	return reg
}
