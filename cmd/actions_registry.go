package cmd

import (
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/confluence"
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

// confluencePageClientFactory serves get_confluence_page and
// edit_confluence_page: the account's Jira client (shared Atlassian grant)
// plus a Confluence fetcher for comments and user names. A grant without
// the Confluence read scopes is the model's cue to ask for re-consent; the
// write scopes are reported to the tool, which refuses an edit without them.
func confluencePageClientFactory(cfg *config.Config) tools.ConfluencePageClientFactory {
	return func(account db.JiraAccount) (tools.ConfluencePageClient, error) {
		client, err := jiraAccountClient(cfg, account)
		if err != nil {
			return nil, err
		}
		tok, err := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID).Load()
		if err != nil {
			return nil, fmt.Errorf("reading jira account #%d token: %w", account.ID, err)
		}
		if !jira.HasConfluenceScopes(tok) {
			_, consent := confluenceHints(account.ID)
			return nil, &tools.ValidationError{Msg: consent}
		}
		api := client.Confluence()
		return tools.NewConfluencePageClient(api, confluence.NewFetcher(api, account.SiteURL), account.SiteURL,
			jira.HasConfluenceWriteScopes(tok)), nil
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
		// Confluence page editing (EXT-05). get_confluence_page is a LIVE
		// network read, so it is registered here (chat mode only), never in
		// tools.ReadTools() — dev-mode MCP stays local-only (DEV-01).
		tools.NewGetConfluencePage(confluencePageClientFactory(cfg)),
		tools.NewEditConfluencePage(confluencePageClientFactory(cfg)),
	)
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
