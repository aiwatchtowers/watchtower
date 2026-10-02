package cmd

import (
	"context"
	"fmt"

	"watchtower/internal/config"
	"watchtower/internal/confluence"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/tools"
	"watchtower/internal/workbenchfiles"
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
// plus a Confluence fetcher for comments and user names. The grant's read
// and write scopes are reported to the tools, each of which refuses with
// its own re-consent hint (the edit tool asks for --with-confluence-write,
// which implies read).
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
		api := client.Confluence()
		return tools.NewConfluencePageClient(api, confluence.NewFetcher(api, account.SiteURL), account.SiteURL,
			jira.HasConfluenceScopes(tok), jira.HasConfluenceWriteScopes(tok)), nil
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

// slackSender adapts the rate-limited Slack client to tools.SlackSender.
type slackSender struct{ *watchtowerslack.Client }

func (s slackSender) RecentMessages(ctx context.Context, channelID, threadTS, oldest string) ([]tools.SlackPosted, bool, error) {
	var out []tools.SlackPosted
	if threadTS != "" {
		replies, err := s.GetConversationReplies(ctx, channelID, threadTS)
		if err != nil {
			return nil, false, err
		}
		for _, m := range replies {
			if m.Timestamp > oldest { // same-width Slack ts strings compare in order
				out = append(out, tools.SlackPosted{User: m.User, Text: m.Text, TS: m.Timestamp})
			}
		}
		return out, false, nil
	}
	cursor := ""
	for range slackLandedCheckPages {
		page, err := s.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{ChannelID: channelID, Oldest: oldest, Cursor: cursor})
		if err != nil {
			return nil, false, err
		}
		for _, m := range page.Messages {
			out = append(out, tools.SlackPosted{User: m.User, Text: m.Text, TS: m.Timestamp})
		}
		if !page.HasMore {
			return out, false, nil
		}
		if page.NextCursor == "" {
			return out, true, nil // more exists but cannot be read: never call it complete
		}
		cursor = page.NextCursor
	}
	return out, true, nil // more than the check reads: the caller refuses to guess
}

// slackLandedCheckPages bounds a retry's history read (200 messages a page).
const slackLandedCheckPages = 5

// slackSenderFactory serves send_slack_message: the account's token file,
// and the scopes it records (empty for a token saved before they were).
func slackSenderFactory(cfg *config.Config) tools.SlackSenderFactory {
	return func(account db.SlackAccount) (tools.SlackSender, string, error) {
		tok, err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), account.ID).Load()
		if err != nil {
			return nil, "", fmt.Errorf("reading slack account #%d token: %w", account.ID, err)
		}
		if tok == nil || tok.AccessToken == "" {
			return nil, "", fmt.Errorf("slack account #%d has no token; run 'watchtower slack login --account %d'", account.ID, account.ID)
		}
		return slackSender{newSlackClientForToken(tok.AccessToken)}, tok.Scope, nil
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
		// Slack send (#166): main chat + workbench sessions; in a workbench
		// session it is recorded pending for the Desktop's Approve (DEV-06).
		tools.NewSendSlackMessage(slackSenderFactory(cfg)),
		tools.NewGetWritingStyle(),
	)
	// The workbench tools (surface "project" only, spec 2026-10-02 A1):
	// mounted by `mcp --workbench N` (and the legacy `mcp --project N`),
	// which applies them directly under Binding.DirectApply (DEV-06).
	regTools = append(regTools, tools.WorkbenchTools(workbenchfiles.New(cfg.WorkspaceDir()), cfg.Knowledge.Enabled)...)
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
