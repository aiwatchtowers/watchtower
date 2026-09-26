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

// maxDispatchPerRun bounds the AI compose calls one Run may spend across ALL
// accounts. reactions.list has no time filter, so a poll always re-enumerates
// the owner's ~2000 most recent reactions; the ledger is what makes that cheap,
// and this budget is what keeps a burst (or a dictionary edit that re-opens an
// emoji's history) from turning into an unbounded batch of AI calls in one
// cycle. Polling every daemon cycle (the default), an over-budget backlog
// drains within a few cycles; `watchtower reaction-commands poll` is the
// owner's manual drain when that is too slow.
const maxDispatchPerRun = 25

// strandedAfter is how long a provisional ledger row may stay unfinalized
// before a poll surfaces it as `failed`. A live dispatch holds its row only for
// one compose call plus one Propose, far below this; a row older than that was
// stranded by a crash or a failed ledger write between claim and finalize.
const strandedAfter = time.Hour

// strandedDetail is the error a stranded provisional row is failed with. The
// outcome is unknown — Propose may have run — so the row is never retried.
const strandedDetail = "stranded provisional row: outcome unknown (a proposal or entity may exist — check the Actions strip); not retried to avoid a duplicate"

// dispatchBudget is one Run's shared compose allowance. It counts AI calls, not
// ledger rows: a candidate whose emoji maps to no built-in tool (or to a tool
// the registry does not hold) is recorded `skipped` before compose is reached
// and costs nothing, so it must not consume a slot.
type dispatchBudget struct {
	remaining int
	deferred  int
}

// take claims one compose call, reporting false once the run's budget is spent.
// A refused candidate is counted as deferred and must NOT be recorded: it stays
// unseen and the next poll picks it up, which is exactly the semantics a
// transient failure already relies on (FilterUnseenReactionCommands).
func (b *dispatchBudget) take() bool {
	if b.remaining <= 0 {
		b.deferred++
		return false
	}
	b.remaining--
	return true
}

// refund returns a slot taken for a candidate that never reached compose (its
// ledger claim failed or was lost to a concurrent poll).
func (b *dispatchBudget) refund() { b.remaining++ }

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
	budget := &dispatchBudget{remaining: maxDispatchPerRun}
	for _, acct := range accounts {
		n, err := p.processAccount(ctx, acct, dict, budget)
		total += n
		if err != nil {
			p.logf("reaction-commands: account #%d: %v", acct.AccountID, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if budget.deferred > 0 {
		p.logf("reaction-commands: dispatched %d, deferred %d to the next cycle (cap %d)",
			total, budget.deferred, maxDispatchPerRun)
	}
	return total, firstErr
}

func (p *Pipeline) processAccount(ctx context.Context, acct Account, dict map[string]db.ReactionCommandMapping, budget *dispatchBudget) (int, error) {
	// An account whose history was never seeded (an install that never ran
	// `features enable` — the feature defaults to on — or a Slack account added
	// after the enable) is seeded by this poll instead of dispatched: FEAT-03's
	// "never replay history" holds by construction, not only via the enable hook.
	seeded, err := p.db.ReactionCommandsSeeded(acct.AccountID)
	if err != nil {
		return 0, err
	}
	if !seeded {
		n, err := seedAccount(ctx, p.db, acct)
		if err != nil {
			return 0, fmt.Errorf("seeding reaction history on first poll: %w", err)
		}
		p.logf("reaction-commands: account #%d polled for the first time, recorded %d pre-existing reaction(s) as seen", acct.AccountID, n)
		return 0, nil
	}
	p.failStranded(acct.AccountID)
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
	// failure below releases its provisional row, so it stays unseen and
	// retries next poll.
	unseen, err := p.db.FilterUnseenReactionCommands(acct.AccountID, owned)
	if err != nil {
		return 0, fmt.Errorf("filtering reaction commands: %w", err)
	}

	dispatched := 0
	for _, u := range unseen {
		if p.dispatchOne(ctx, u, byKey[ledgerKey(u.ChannelID, u.MessageTS, u.Emoji)], budget) {
			dispatched++
		}
	}
	return dispatched, nil
}

// failStranded surfaces this account's stranded provisional rows as `failed`
// and logs each one. Best-effort: a failure here is logged and never blocks
// the poll, since a stranded row is already filtered out as seen either way.
func (p *Pipeline) failStranded(accountID int64) {
	rows, err := p.db.FailStrandedReactionCommands(accountID, time.Now().Add(-strandedAfter), strandedDetail)
	if err != nil {
		p.logf("reaction-commands: account #%d: surfacing stranded provisional rows: %v", accountID, err)
		return
	}
	for _, r := range rows {
		p.logf("reaction-commands: ERROR ledger row #%d (:%s: on %s@%s) was stranded provisional for over %s and is now failed — outcome unknown, a proposal may exist; it will not be retried",
			r.ID, r.Emoji, r.ChannelID, r.MessageTS, strandedAfter)
	}
}

// ledgerStep is what dispatchOne does with a claimed provisional row once the
// dispatch returns.
type ledgerStep int

const (
	// stepFinalize records the returned terminal status on the row.
	stepFinalize ledgerStep = iota
	// stepRelease deletes the row: the failure was transient and provably
	// produced no agent action, so the next poll retries.
	stepRelease
	// stepStrand leaves the row provisional: whether an action was recorded is
	// unknown, so the command is never retried and surfaces as failed after
	// strandedAfter.
	stepStrand
)

// dispatchOne runs one unseen command through the ledger state machine and
// reports whether it dispatched. A side-effect-free skip is recorded terminal
// directly; anything that reaches compose/Propose first claims a provisional
// row, so the row exists BEFORE the side effect: a failed finalize can only
// strand that row (never re-dispatch), a transient failure that provably
// proposed nothing releases it for the next poll, and a failed claim
// dispatches nothing (retried next poll).
func (p *Pipeline) dispatchOne(ctx context.Context, u db.OwnerReaction, c candidate, budget *dispatchBudget) bool {
	tool, detail, ok := p.resolveTool(c)
	if !ok {
		if err := p.db.InsertReactionCommand(u, "skipped", 0, detail); err != nil {
			p.logf("reaction-commands: recording skipped outcome for :%s: (will retry next poll): %v", u.Emoji, err)
		}
		return false
	}
	// The budget is claimed HERE, past the free skips above, and refunded when
	// the claim below does not lead to the AI call — so only compose calls
	// spend a slot.
	if !budget.take() {
		return false
	}
	id, claimed, err := p.db.ClaimReactionCommand(u)
	if err != nil {
		budget.refund()
		p.logf("reaction-commands: claiming ledger row for :%s: failed, nothing dispatched, will retry next poll: %v", u.Emoji, err)
		return false
	}
	if !claimed {
		budget.refund()
		return false // a concurrent poll already holds this key
	}
	status, actionID, detail, step := p.dispatch(ctx, c, tool)
	switch step {
	case stepRelease:
		p.release(id, u.Emoji)
		return false
	case stepStrand:
		p.logf("reaction-commands: ERROR ledger row #%d for :%s: left provisional — whether an action was recorded is unknown; it will not be retried and surfaces as failed after %s",
			id, u.Emoji, strandedAfter)
		return false
	case stepFinalize:
	}
	applied, err := p.db.FinalizeReactionCommand(id, status, actionID, detail)
	switch {
	case err != nil:
		p.logf("reaction-commands: ERROR recording %s outcome (action #%d) for :%s: — ledger row #%d stays provisional; it will not re-dispatch and surfaces as failed after %s: %v",
			status, actionID, u.Emoji, id, strandedAfter, err)
	case !applied:
		p.logf("reaction-commands: ERROR ledger row #%d for :%s: was no longer provisional when its %s outcome (action #%d) arrived — the row keeps its stranded status; the outcome is known only from this line",
			id, u.Emoji, status, actionID)
	}
	return status == "dispatched"
}

// release deletes a claimed row after a transient failure that proposed
// nothing, so the next poll retries. A failed or no-op release strands the row:
// safe (no duplicate), but this reaction will not be retried.
func (p *Pipeline) release(id int64, emoji string) {
	applied, err := p.db.ReleaseReactionCommand(id)
	switch {
	case err != nil:
		p.logf("reaction-commands: ERROR releasing ledger row #%d for :%s: after a transient failure — it will NOT be retried and surfaces as failed after %s: %v", id, emoji, strandedAfter, err)
	case !applied:
		p.logf("reaction-commands: ERROR ledger row #%d for :%s: was no longer provisional when its transient failure came back — it will NOT be retried", id, emoji)
	}
}

func ledgerKey(channelID, ts, emoji string) string {
	return channelID + "\x00" + ts + "\x00" + emoji
}

// resolveTool returns the registered tool a candidate's emoji maps to, or
// ok=false with the detail of the terminal `skipped` outcome to record — both
// checks are free (no AI call, no side effect).
func (p *Pipeline) resolveTool(c candidate) (tool *tools.Tool, detail string, ok bool) {
	if c.Mapping.Kind != "builtin_tool" || c.Mapping.Tool == "" {
		return nil, "emoji maps to no built-in tool", false
	}
	tool, ok = p.registry.Get(c.Mapping.Tool)
	if !ok {
		return nil, "tool not registered: " + c.Mapping.Tool, false
	}
	return tool, "", true
}

// dispatch composes and proposes one command's action. With stepFinalize it
// returns the terminal ledger status to record (dispatched/failed), the
// agent-action id (0 unless dispatched) and a detail string; stepRelease marks
// a TRANSIENT failure that produced no action (the caller releases the row so
// the next poll retries instead of burning it), stepStrand one whose outcome
// is unknown.
func (p *Pipeline) dispatch(ctx context.Context, c candidate, tool *tools.Tool) (status string, actionID int64, detail string, step ledgerStep) {
	args, transient, err := p.compose(ctx, c)
	if err != nil {
		if transient {
			p.logf("reaction-commands: transient compose failure for :%s: (%s), will retry: %v", c.Emoji, c.Mapping.Tool, err)
			return "", 0, "", stepRelease
		}
		return "failed", 0, "compose: " + err.Error(), stepFinalize
	}
	// Surface "reaction" keeps these proposals out of any chat conversation;
	// the External-never-auto-execute rule (AGENT-03) and per-tool trust are
	// enforced inside Propose, so a create_jira_issue reaction always lands as
	// a pending proposal even if create_target is execute-trusted.
	binding := tools.Binding{
		Surface:     "reaction",
		ContextType: "reaction",
		ContextID:   c.ChannelID + "@" + c.MessageTS, // REACT-02: real message ref for reminders/brief
	}
	// The agent_actions high-water mark before Propose lets a failed Propose be
	// told apart: "recorded a row, then failed" vs "recorded nothing".
	floor, err := p.db.MaxAgentActionID()
	if err != nil {
		p.logf("reaction-commands: reading agent-action high-water mark for :%s: failed, will retry: %v", c.Emoji, err)
		return "", 0, "", stepRelease
	}
	receipt, err := p.registry.Propose(ctx, tool.Name, args, binding)
	if err != nil {
		// A ValidationError is terminal — the model's args cannot pass the
		// tool's schema/semantics, and re-composing the same message would only
		// spend AI budget to fail again.
		var ve *tools.ValidationError
		if errors.As(err, &ve) {
			return "failed", 0, "propose: " + err.Error(), stepFinalize
		}
		return p.afterProposeError(c, tool.Name, binding.ContextID, floor, err)
	}
	return "dispatched", receipt.ActionID, "", stepFinalize
}

// afterProposeError classifies a non-validation Propose error. Propose can fail
// AFTER inserting its agent_actions row (a failed approve stamp or apply
// bookkeeping on an execute-trusted tool), so the error alone does not prove
// nothing was proposed: a row recorded since `floor` for this binding means the
// command dispatched (finalize with that id); none means the failure was
// transient before any write (release, retry next poll); a failed lookup
// leaves the outcome unknown (strand).
func (p *Pipeline) afterProposeError(c candidate, toolName, contextID string, floor int64, proposeErr error) (string, int64, string, ledgerStep) {
	id, err := p.db.ReactionAgentActionSince(contextID, toolName, floor)
	if err != nil {
		p.logf("reaction-commands: ERROR propose for :%s: failed (%v) and the recorded-action lookup failed too: %v", c.Emoji, proposeErr, err)
		return "", 0, "", stepStrand
	}
	if id != 0 {
		p.logf("reaction-commands: propose for :%s: failed after recording action #%d — recording it as dispatched, not retrying: %v", c.Emoji, id, proposeErr)
		return "dispatched", id, "propose error after recording: " + proposeErr.Error(), stepFinalize
	}
	p.logf("reaction-commands: transient propose failure for :%s:, nothing recorded, will retry: %v", c.Emoji, proposeErr)
	return "", 0, "", stepRelease
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
	// The daemon runs in the owner's TZ (the create_target due precedent), so
	// time.Local is the owner's zone — both the date and the clock below are
	// the owner's, so "tomorrow" cannot straddle a UTC midnight.
	now := time.Now()
	today := now.Format("2006-01-02")
	ownerNow := now.Format("2006-01-02T15:04:05-07:00 (MST)")
	userMsg := buildComposeUserMessage(c, argGuide(c.Mapping.Tool), threadLines, jiraProjects, today, ownerNow, prompts.Directive(p.language()))

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
