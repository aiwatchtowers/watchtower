package reactioncmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/slack-go/slack"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/tools"
)

// ReactionLister is the slice of the Slack client the pipeline needs: list the
// items a user reacted to. *slack.Client (internal/slack) satisfies it.
type ReactionLister interface {
	ListUserReactions(ctx context.Context, userID string) ([]slack.ReactedItem, error)
}

// Account is one connected Slack account the pipeline polls: its id, the
// owner's user id (raw or namespaced — processAccount strips it), and a lister.
type Account struct {
	AccountID int64
	OwnerID   string
	Lister    ReactionLister
}

// Pipeline detects owner reaction-commands and dispatches them as agent-actions
// through the shared tools registry. It never touches Slack write scopes and
// never posts anything back to Slack (REACT-05); the agent-action row is the
// feedback surface the Desktop reads.
type Pipeline struct {
	db          *db.DB
	cfg         *config.Config
	generator   digest.Generator
	registry    *tools.Registry
	accountsFn  func(context.Context) ([]Account, error)
	promptStore *prompts.Store
	logger      *log.Logger
}

// New builds a reaction-commands pipeline. accountsFn resolves the connected
// Slack accounts (with a live client each) at run time; the generator and
// registry are shared with the rest of the daemon.
func New(database *db.DB, cfg *config.Config, gen digest.Generator, registry *tools.Registry,
	accountsFn func(context.Context) ([]Account, error), logger *log.Logger) *Pipeline {
	return &Pipeline{db: database, cfg: cfg, generator: gen, registry: registry, accountsFn: accountsFn, logger: logger}
}

// SetPromptStore injects the owner-customizable prompt store.
func (p *Pipeline) SetPromptStore(s *prompts.Store) { p.promptStore = s }

// Run polls every connected account's reactions.list and dispatches new
// commands, returning the count dispatched. One account's failure never blocks
// the others (the sync-wiring fan-out precedent); the first error is returned
// for the daemon's run stats after every account has been tried.
func (p *Pipeline) Run(ctx context.Context) (int, error) {
	dict, err := p.db.ListReactionCommandMap()
	if err != nil {
		return 0, fmt.Errorf("loading reaction command map: %w", err)
	}
	if len(dict) == 0 {
		return 0, nil
	}
	accounts, err := p.accountsFn(ctx)
	if err != nil {
		return 0, fmt.Errorf("resolving reaction accounts: %w", err)
	}
	total := 0
	var firstErr error
	for _, acct := range accounts {
		n, err := p.processAccount(ctx, acct, dict)
		total += n
		if err != nil {
			p.logf("reaction-commands: account #%d: %v", acct.AccountID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return total, firstErr
}

func (p *Pipeline) processAccount(ctx context.Context, acct Account, dict map[string]db.ReactionCommandMapping) (int, error) {
	rawOwner := acct.OwnerID
	if _, raw, ok := watchtowerslack.SplitAccountID(acct.OwnerID); ok {
		rawOwner = raw
	}
	items, err := acct.Lister.ListUserReactions(ctx, rawOwner)
	if err != nil {
		return 0, fmt.Errorf("reactions.list: %w", err)
	}
	cands := extractOwnerReactions(items, rawOwner, dict, acct.AccountID)
	if len(cands) == 0 {
		return 0, nil
	}

	byKey := make(map[string]candidate, len(cands))
	owned := make([]db.OwnerReaction, 0, len(cands))
	for _, c := range cands {
		byKey[ledgerKey(c.ChannelID, c.MessageTS, c.Emoji)] = c
		owned = append(owned, db.OwnerReaction{
			AccountID: c.AccountID, ChannelID: c.ChannelID, MessageTS: c.MessageTS, Emoji: c.Emoji,
		})
	}
	// Only reactions not already in the ledger are dispatched; a transient
	// failure below is NOT recorded, so it stays unseen and retries next poll.
	unseen, err := p.db.FilterUnseenReactionCommands(acct.AccountID, owned)
	if err != nil {
		return 0, fmt.Errorf("filtering reaction commands: %w", err)
	}

	dispatched := 0
	for _, u := range unseen {
		c := byKey[ledgerKey(u.ChannelID, u.MessageTS, u.Emoji)]
		status, actionID, detail, record := p.dispatch(ctx, c)
		if !record {
			continue // transient — leave unseen so the next poll retries
		}
		if err := p.db.InsertReactionCommand(u, status, actionID, detail); err != nil {
			p.logf("reaction-commands: recording %s outcome for %s: %v", status, u.Emoji, err)
		}
		if status == "dispatched" {
			dispatched++
		}
	}
	return dispatched, nil
}

func ledgerKey(channelID, ts, emoji string) string {
	return channelID + "\x00" + ts + "\x00" + emoji
}

// dispatch composes and proposes one command's action. It returns the terminal
// ledger status to record (dispatched/skipped/failed), the agent-action id (0
// unless dispatched), a detail string, and record=false for a TRANSIENT failure
// that must NOT be recorded — leaving the reaction unseen so the next poll
// retries it instead of burning it permanently.
func (p *Pipeline) dispatch(ctx context.Context, c candidate) (status string, actionID int64, detail string, record bool) {
	if c.Mapping.Kind != "builtin_tool" || c.Mapping.Tool == "" {
		return "skipped", 0, "emoji maps to no built-in tool", true
	}
	tool, ok := p.registry.Get(c.Mapping.Tool)
	if !ok {
		return "skipped", 0, "tool not registered: " + c.Mapping.Tool, true
	}
	args, transient, err := p.compose(ctx, c)
	if err != nil {
		if transient {
			p.logf("reaction-commands: transient compose failure for :%s: (%s), will retry: %v", c.Emoji, c.Mapping.Tool, err)
			return "", 0, "", false
		}
		return "failed", 0, "compose: " + err.Error(), true
	}
	// Surface "reaction" keeps these proposals out of any chat conversation;
	// the External-never-auto-execute rule (AGENT-03) and per-tool trust are
	// enforced inside Propose, so a create_jira_issue reaction always lands as
	// a pending proposal even if create_target is execute-trusted.
	binding := tools.Binding{Surface: "reaction", ContextType: "reaction"}
	receipt, err := p.registry.Propose(ctx, tool.Name, args, binding)
	if err != nil {
		// A ValidationError is terminal — the model's args cannot pass the
		// tool's schema/semantics, and re-composing the same message would only
		// spend AI budget to fail again. Any other Propose error (a DB write
		// failure) is transient: don't record, retry next poll.
		var ve *tools.ValidationError
		if errors.As(err, &ve) {
			return "failed", 0, "propose: " + err.Error(), true
		}
		p.logf("reaction-commands: transient propose failure for :%s:, will retry: %v", c.Emoji, err)
		return "", 0, "", false
	}
	return "dispatched", receipt.ActionID, "", true
}

// compose runs the one AI call that turns the reacted message into the tool's
// argument JSON. transient=true means the generator itself failed (provider
// down / timeout) and the caller should retry later rather than record a
// terminal failure; a reply that arrived but carried no JSON is terminal.
func (p *Pipeline) compose(ctx context.Context, c candidate) (args json.RawMessage, transient bool, err error) {
	system, _ := p.getPrompt(prompts.ReactionCommand)
	var jiraProjects []string
	if c.Mapping.Tool == "create_jira_issue" {
		if jiraProjects, err = p.db.ListSyncedJiraProjectKeys(); err != nil {
			p.logf("reaction-commands: listing jira projects (composing without them): %v", err)
			jiraProjects = nil
		}
	}
	var threadLines []string
	if c.ThreadTS != "" {
		threadLines = p.threadContext(c)
	}
	today := time.Now().UTC().Format("2006-01-02")
	userMsg := buildComposeUserMessage(c, argGuide(c.Mapping.Tool), threadLines, jiraProjects, today, prompts.Directive(p.language()))

	reply, _, _, err := p.generator.Generate(digest.WithSource(ctx, prompts.ReactionCommand), system, userMsg, "")
	if err != nil {
		return nil, true, err
	}
	obj, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return nil, false, fmt.Errorf("no JSON object in reply: %w", err)
	}
	return json.RawMessage(obj), false, nil
}

// threadContext returns a few surrounding thread messages for grounding.
// Best-effort: any error or a message outside the sync window just yields a
// thinner brief, never a failure.
func (p *Pipeline) threadContext(c candidate) []string {
	msgs, err := p.db.GetThreadReplies(c.ChannelID, c.ThreadTS)
	if err != nil {
		p.logf("reaction-commands: thread context for :%s: unavailable (composing without it): %v", c.Emoji, err)
		return nil
	}
	const maxLines = 10
	var out []string
	for _, m := range msgs {
		text := strings.TrimSpace(m.Text)
		if text == "" {
			continue
		}
		out = append(out, fmt.Sprintf("%s: %s", m.UserID, text))
		if len(out) >= maxLines {
			break
		}
	}
	return out
}

func (p *Pipeline) getPrompt(id string) (string, int) {
	if p.promptStore != nil {
		if tmpl, version, err := p.promptStore.Get(id); err == nil {
			return tmpl, version
		}
	}
	return prompts.Defaults[id], 0
}

func (p *Pipeline) language() string {
	if p.cfg == nil {
		return ""
	}
	return p.cfg.Digest.Language
}

func (p *Pipeline) logf(format string, args ...any) {
	if p.logger != nil {
		p.logger.Printf(format, args...)
	}
}
