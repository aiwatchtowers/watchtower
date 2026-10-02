package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// SlackSendScopeHint is the stable phrase every "this token cannot send"
// failure carries. The Desktop card matches it to offer Reconnect Slack
// (AgentActionCardView+Slack.swift) — change both together.
const SlackSendScopeHint = "sign in again to grant send"

// slackSendMaxRunes caps a message: long enough for any chat reply, short
// enough that the card shows the whole text the owner approves.
const slackSendMaxRunes = 4000

// SlackPosted is one message read back from a conversation.
type SlackPosted struct {
	User string
	Text string
	TS   string
}

// SlackSender is the slice of the Slack API send_slack_message needs — a seam
// so tests inject a fake and the CLI wiring a per-account client.
type SlackSender interface {
	PostMessage(ctx context.Context, channelID, text, threadTS string) (string, error)
	OpenDM(ctx context.Context, userID string) (string, error)
	// RecentMessages returns the messages in channelID (or in the thread
	// threadTS) newer than oldest, and whether there may be more than it read.
	RecentMessages(ctx context.Context, channelID, threadTS, oldest string) ([]SlackPosted, bool, error)
}

// SlackSenderFactory builds a sender for one account and reports the user
// scopes its token was granted ("" for a token saved before grants were
// recorded: unknown, so the send is tried and Slack's answer decides).
type SlackSenderFactory func(account db.SlackAccount) (SlackSender, string, error)

type sendSlackMessageArgs struct {
	Channel   string `json:"channel,omitempty" jsonschema:"the channel: #name, a channel id, or a Slack link to a channel or a message (a message link replies in its thread)"`
	ThreadTS  string `json:"thread_ts,omitempty" jsonschema:"reply in this thread of the channel (the parent message ts)"`
	User      string `json:"user,omitempty" jsonschema:"a person to DM instead of a channel: user id, @handle, display or real name, or email"`
	AccountID int64  `json:"account_id,omitempty" jsonschema:"Slack account id, only to pick the workspace when the recipient exists in several"`
	Text      string `json:"text" jsonschema:"the message, written in the owner's voice (get_writing_style); Slack mrkdwn, mention people as <@USER_ID>"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// slackRecipient is a resolved destination, pinned into the stored args at
// propose time so Execute never re-resolves a name (the PR #92 rule).
type slackRecipient struct {
	AccountID int64  `json:"account_id"`
	Workspace string `json:"workspace"`
	// ChannelID is the raw Slack id; empty for a DM whose IM channel is not
	// synced yet (Execute opens it).
	ChannelID string `json:"channel_id,omitempty"`
	UserID    string `json:"user_id,omitempty"`
	Label     string `json:"label"`
	ThreadTS  string `json:"thread_ts,omitempty"`
}

// storedSlackSend is the row's args after Normalize: the call plus either the
// one target or, when the recipient exists in several workspaces, the
// candidates the owner picks from on the card.
type storedSlackSend struct {
	sendSlackMessageArgs
	Target     *slackRecipient  `json:"target,omitempty"`
	Candidates []slackRecipient `json:"candidates,omitempty"`
}

var (
	slackThreadTSRE = regexp.MustCompile(`^\d{10}\.\d{6}$`)
	slackLinkTSRE   = regexp.MustCompile(`^p(\d{10})(\d{6})$`)
	// slackIDMentionRE matches a namespaced user/channel mention the model
	// copied from a tool result: <@2:U123>, <#2:C123|name>.
	slackIDMentionRE = regexp.MustCompile(`<([@#])(\d+):([A-Z0-9]+)`)
)

func checkSlackText(text string) error {
	switch {
	case strings.TrimSpace(text) == "":
		return &ValidationError{Msg: "text is required"}
	case len([]rune(text)) > slackSendMaxRunes:
		return &ValidationError{Msg: fmt.Sprintf("text must be at most %d characters", slackSendMaxRunes)}
	}
	return nil
}

// slackChannelRef is a parsed `channel` argument.
type slackChannelRef struct {
	ref      string // channel id (raw or namespaced) or name
	threadTS string // from a message link
	domain   string // from a link's host
}

// parseSlackChannelRef reads `#name`, an id, or a Slack link
// (https://<domain>.slack.com/archives/<id>[/p<ts>][?thread_ts=<ts>]).
func parseSlackChannelRef(raw string) (slackChannelRef, error) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "/archives/") {
		return slackChannelRef{ref: strings.TrimPrefix(raw, "#")}, nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return slackChannelRef{}, &ValidationError{Msg: "channel is not a readable Slack link"}
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 || parts[0] != "archives" || parts[1] == "" {
		return slackChannelRef{}, &ValidationError{Msg: "channel link has no channel id"}
	}
	out := slackChannelRef{ref: parts[1], domain: strings.TrimSuffix(u.Hostname(), ".slack.com")}
	if root := u.Query().Get("thread_ts"); root != "" {
		out.threadTS = root // a reply's link: answer in the thread it belongs to
	} else if len(parts) > 2 {
		m := slackLinkTSRE.FindStringSubmatch(parts[2])
		if m == nil {
			return slackChannelRef{}, &ValidationError{Msg: "channel link has an unreadable message part"}
		}
		out.threadTS = m[1] + "." + m[2]
	}
	return out, nil
}

func slackWorkspaceName(a db.SlackAccount) string {
	for _, s := range []string{a.Label, a.TeamName, a.TeamDomain} {
		if strings.TrimSpace(s) != "" {
			return s
		}
	}
	return fmt.Sprintf("Slack #%d", a.ID)
}

// sendableSlackAccounts lists the accounts a recipient may resolve in:
// enabled, not removed, narrowed to accountID when set.
func sendableSlackAccounts(d *db.DB, accountID int64) ([]db.SlackAccount, error) {
	accounts, err := d.ListEnabledSlackAccounts()
	if err != nil {
		return nil, err
	}
	if len(accounts) == 0 {
		return nil, &ValidationError{Msg: "no Slack workspace is connected"}
	}
	if accountID == 0 {
		return accounts, nil
	}
	for _, a := range accounts {
		if a.ID == accountID {
			return []db.SlackAccount{a}, nil
		}
	}
	return nil, &ValidationError{Msg: fmt.Sprintf("Slack account #%d is not connected or not enabled", accountID)}
}

// resolveSlackRecipients resolves the call against the local DB: one
// recipient per workspace it exists in. Zero matches, or several inside one
// workspace, is the model's to fix (a ValidationError, no row).
func resolveSlackRecipients(ctx context.Context, d *db.DB, a sendSlackMessageArgs) ([]slackRecipient, error) {
	hasChannel, hasUser := strings.TrimSpace(a.Channel) != "", strings.TrimSpace(a.User) != ""
	switch {
	case hasChannel == hasUser:
		return nil, &ValidationError{Msg: "pass exactly one of channel or user"}
	case hasUser && a.ThreadTS != "":
		return nil, &ValidationError{Msg: "thread_ts needs a channel; to reply in a DM thread pass the DM's message link as channel"}
	case a.ThreadTS != "" && !slackThreadTSRE.MatchString(a.ThreadTS):
		return nil, &ValidationError{Msg: "thread_ts must look like 1700000000.123456"}
	}
	accounts, err := sendableSlackAccounts(d, a.AccountID)
	if err != nil {
		return nil, err
	}
	var out []slackRecipient
	for _, acct := range accounts {
		var found []slackRecipient
		if hasChannel {
			found, err = resolveSlackChannel(ctx, d, acct, a, accounts)
		} else {
			found, err = resolveSlackUser(ctx, d, acct, a.User)
		}
		if err != nil {
			return nil, err
		}
		if len(found) > 1 {
			names := make([]string, 0, len(found))
			for _, f := range found {
				id := f.ChannelID
				if f.UserID != "" {
					id = f.UserID
				}
				names = append(names, f.Label+" ("+slack.Namespace(acct.ID, id)+")")
			}
			return nil, &ValidationError{Msg: fmt.Sprintf("%q matches several in %s: %s — ask the owner which one and pass its id",
				strings.TrimSpace(a.Channel+a.User), slackWorkspaceName(acct), strings.Join(names, ", "))}
		}
		out = append(out, found...)
	}
	if len(out) == 0 {
		what := "channel " + a.Channel
		if hasUser {
			what = "person " + a.User
		}
		return nil, &ValidationError{Msg: fmt.Sprintf("no %s in the connected Slack workspaces (only synced channels and people can be addressed)", what)}
	}
	return out, nil
}

func resolveSlackChannel(ctx context.Context, d *db.DB, acct db.SlackAccount, a sendSlackMessageArgs, all []db.SlackAccount) ([]slackRecipient, error) {
	ref, err := parseSlackChannelRef(a.Channel)
	if err != nil {
		return nil, err
	}
	thread := a.ThreadTS
	if ref.threadTS != "" {
		if thread != "" && thread != ref.threadTS {
			return nil, &ValidationError{Msg: "thread_ts differs from the thread in the channel link"}
		}
		thread = ref.threadTS
	}
	// A link names its workspace by host; honour it when it is one we know.
	if ref.domain != "" && acct.TeamDomain != ref.domain && knowsSlackDomain(all, ref.domain) {
		return nil, nil
	}
	name := ref.ref
	if n, raw, ok := slack.SplitAccountID(name); ok {
		if n != acct.ID {
			return nil, nil
		}
		name = raw
	}
	// A DM addressed by its id or a link names the person, not the IM: the
	// card must say who receives it.
	rows, err := d.QueryContext(ctx, `SELECT c.id, c.name, c.type, COALESCE(c.dm_user_id, ''),
			COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), u.name, '')
		FROM channels c LEFT JOIN users u ON u.id = c.dm_user_id
		WHERE c.id LIKE ? || ':%' AND c.is_archived = 0
		  AND (c.id = ? OR (c.type IN ('public', 'private') AND lower(c.name) = lower(?)))
		ORDER BY c.id`, strconv.FormatInt(acct.ID, 10), slack.Namespace(acct.ID, name), name)
	if err != nil {
		return nil, fmt.Errorf("resolving slack channel %q: %w", a.Channel, err)
	}
	defer rows.Close()
	var out []slackRecipient
	for rows.Next() {
		var id, chName, chType, dmUser, person string
		if err := rows.Scan(&id, &chName, &chType, &dmUser, &person); err != nil {
			return nil, fmt.Errorf("resolving slack channel %q: %w", a.Channel, err)
		}
		_, raw, _ := slack.SplitAccountID(id)
		r := slackRecipient{AccountID: acct.ID, Workspace: slackWorkspaceName(acct), ChannelID: raw, ThreadTS: thread}
		switch {
		case chType == "dm":
			_, r.UserID, _ = slack.SplitAccountID(dmUser)
			r.Label = "@" + person
			if person == "" {
				r.Label = "DM " + raw
			}
		case chType == "group_dm":
			r.Label = "group DM " + chName
		case chName != "":
			r.Label = "#" + chName
		default:
			r.Label = raw
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func knowsSlackDomain(accounts []db.SlackAccount, domain string) bool {
	for _, a := range accounts {
		if a.TeamDomain == domain {
			return true
		}
	}
	return false
}

func resolveSlackUser(ctx context.Context, d *db.DB, acct db.SlackAccount, who string) ([]slackRecipient, error) {
	ref := strings.TrimPrefix(strings.TrimSpace(who), "@")
	if n, raw, ok := slack.SplitAccountID(ref); ok {
		if n != acct.ID {
			return nil, nil
		}
		ref = raw
	}
	rows, err := d.QueryContext(ctx, `SELECT u.id, u.name, u.display_name, u.real_name,
			COALESCE((SELECT c.id FROM channels c WHERE c.type = 'dm' AND c.dm_user_id = u.id ORDER BY c.id LIMIT 1), '')
		FROM users u
		WHERE u.id LIKE ? || ':%' AND u.is_deleted = 0 AND u.is_bot = 0
		  AND (u.id = ? OR lower(u.name) = lower(?) OR lower(u.display_name) = lower(?)
		       OR lower(u.real_name) = lower(?) OR (u.email != '' AND lower(u.email) = lower(?)))
		ORDER BY u.id`, strconv.FormatInt(acct.ID, 10), slack.Namespace(acct.ID, ref), ref, ref, ref, ref)
	if err != nil {
		return nil, fmt.Errorf("resolving slack user %q: %w", who, err)
	}
	defer rows.Close()
	var out []slackRecipient
	for rows.Next() {
		var id, name, display, realName, dm string
		if err := rows.Scan(&id, &name, &display, &realName, &dm); err != nil {
			return nil, fmt.Errorf("resolving slack user %q: %w", who, err)
		}
		_, rawUser, _ := slack.SplitAccountID(id)
		_, rawDM, _ := slack.SplitAccountID(dm)
		label := name
		for _, s := range []string{display, realName} {
			if strings.TrimSpace(s) != "" {
				label = s
				break
			}
		}
		out = append(out, slackRecipient{AccountID: acct.ID, Workspace: slackWorkspaceName(acct),
			ChannelID: rawDM, UserID: rawUser, Label: "@" + label})
	}
	return out, rows.Err()
}

// pinSlackRecipients stores the resolution: the one target, or the
// candidates the owner picks from.
func pinSlackRecipients(raw json.RawMessage, found []slackRecipient) (json.RawMessage, error) {
	if len(found) == 1 {
		return mergeJSON(raw, map[string]any{"target": found[0]})
	}
	return mergeJSON(raw, map[string]any{"candidates": found})
}

func decodeStoredSlackSend(raw json.RawMessage) (storedSlackSend, error) {
	var s storedSlackSend
	if err := json.Unmarshal(raw, &s); err != nil {
		return storedSlackSend{}, fmt.Errorf("decoding send_slack_message args: %w", err)
	}
	return s, nil
}

type slackSendPatch struct {
	Text      *string `json:"text,omitempty"`
	Candidate *int    `json:"candidate,omitempty"`
}

// reviseSlackSend merges the owner's card edits: the text, and the choice of
// one pinned candidate. The recipient itself is never editable.
func reviseSlackSend(_ context.Context, _ *db.DB, stored, patch json.RawMessage) (json.RawMessage, error) {
	var p slackSendPatch
	if err := decodeStrict(patch, &p); err != nil {
		return nil, err
	}
	s, err := decodeStoredSlackSend(stored)
	if err != nil {
		return nil, err
	}
	changes := map[string]any{}
	if p.Text != nil {
		if err := checkSlackText(*p.Text); err != nil {
			return nil, err
		}
		changes["text"] = *p.Text
	}
	if p.Candidate != nil {
		if len(s.Candidates) == 0 {
			return nil, &ValidationError{Msg: "this message has a single recipient; there is no workspace to choose"}
		}
		if *p.Candidate < 0 || *p.Candidate >= len(s.Candidates) {
			return nil, &ValidationError{Msg: fmt.Sprintf("candidate must be 0..%d", len(s.Candidates)-1)}
		}
		changes["target"] = s.Candidates[*p.Candidate]
	}
	if len(changes) == 0 {
		return stored, nil
	}
	return mergeJSON(stored, changes)
}

func slackSendReady(args json.RawMessage) error {
	s, err := decodeStoredSlackSend(args)
	if err != nil {
		return err
	}
	if s.Target == nil {
		return &ValidationError{Msg: "choose the workspace to send from before approving"}
	}
	return checkSlackText(s.Text)
}

// rawSlackMentions rewrites the pinned account's namespaced mentions to the
// raw ids Slack expects; a mention namespaced to another workspace cannot be
// sent from this one.
func rawSlackMentions(text string, accountID int64) (string, error) {
	var foreign string
	out := slackIDMentionRE.ReplaceAllStringFunc(text, func(m string) string {
		parts := slackIDMentionRE.FindStringSubmatch(m)
		if n, _ := strconv.ParseInt(parts[2], 10, 64); n != accountID {
			foreign = m
			return m
		}
		return "<" + parts[1] + parts[3]
	})
	if foreign != "" {
		return "", fmt.Errorf("the message mentions %s…>, which belongs to another Slack workspace", foreign)
	}
	return out, nil
}

// SlackNotSentPrefix opens the error of a failed send that never reached
// chat.postMessage on any attempt: its Retry needs no landed-message lookup.
const SlackNotSentPrefix = "nothing was sent: "

func slackScopeError(account db.SlackAccount) error {
	return fmt.Errorf("slack workspace %s has not granted Watchtower permission to send messages — %s "+
		"(Settings → Slack → Reconnect, or 'watchtower slack login --account %d'), then Retry",
		slackWorkspaceName(account), SlackSendScopeHint, account.ID)
}

// slackSendFailed turns Slack's answer into what the owner can do about it:
// a token that may not send (or no longer works) asks to sign in again; a
// channel the owner is not in, or one that is gone, says so.
func slackSendFailed(account db.SlackAccount, what string, err error) error {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "missing_scope"), strings.Contains(msg, "not_allowed_token_type"),
		strings.Contains(msg, "invalid_auth"), strings.Contains(msg, "token_revoked"),
		strings.Contains(msg, "account_inactive"):
		return fmt.Errorf("%w (Slack said: %s)", slackScopeError(account), msg)
	case strings.Contains(msg, "not_in_channel"):
		return fmt.Errorf("slack %s: you are not a member of that conversation in %s — join it in Slack, then Retry (%s)",
			what, slackWorkspaceName(account), msg)
	case strings.Contains(msg, "channel_not_found"), strings.Contains(msg, "is_archived"):
		return fmt.Errorf("slack %s: the conversation is gone or archived — Reject this and ask for the message again (%s)", what, msg)
	}
	return fmt.Errorf("slack %s: %w", what, err)
}

// slackRejected reports whether Slack rejected the request outright, so
// nothing can have been posted (an auth or channel refusal, not a timeout).
func slackRejected(err error) bool {
	msg := err.Error()
	for _, code := range []string{"missing_scope", "not_allowed_token_type", "invalid_auth", "token_revoked",
		"account_inactive", "not_in_channel", "channel_not_found", "is_archived", "msg_too_long", "no_text"} {
		if strings.Contains(msg, code) {
			return true
		}
	}
	return false
}

var (
	// slackLinkRE matches a link as Slack stores it: <https://x> for a URL it
	// auto-linked, <https://x|label> for a labelled one.
	slackLinkRE = regexp.MustCompile(`<((?:https?|mailto):[^|>]*)(?:\|([^>]*))?>`)
	// slackRefLabelRE matches a mention or special token Slack may store with
	// a label: <#C123|general>, <@U1|alice>, <!here|here>.
	slackRefLabelRE = regexp.MustCompile(`<([@#!][^|>]*)\|[^>]*>`)
)

// normalizeSlackText is the comparison form of a message: Slack wraps the
// URLs it auto-links in <…>, may label mentions, stores &, < and > escaped
// and may trim the edges. Applied to both sides, so a labelled link compares
// by its label and a mention by its id.
func normalizeSlackText(s string) string {
	s = slackLinkRE.ReplaceAllStringFunc(s, func(m string) string {
		parts := slackLinkRE.FindStringSubmatch(m)
		if parts[2] != "" {
			return parts[2]
		}
		return parts[1]
	})
	s = slackRefLabelRE.ReplaceAllString(s, "<$1>")
	return strings.TrimSpace(html.UnescapeString(s))
}

// slackLandedCheckNext is what a retry that cannot tell tells the owner to do.
const slackLandedCheckNext = " — check the conversation in Slack: if the message is there, Reject this card; if not, Reject it and ask for the message again"

// findLandedSlackMessage returns the ts of a message an earlier, failed
// attempt posted after all ("" when none): one from the owner, with the same
// text, since the proposal was recorded (proposedAt). A lookup that cannot be
// completed is an error — the retry must not re-post on a guess.
func findLandedSlackMessage(ctx context.Context, sender SlackSender, proposedAt, ownerRaw, channel, thread, text string) (string, error) {
	proposed, err := time.Parse(time.RFC3339, proposedAt)
	if err != nil {
		return "", fmt.Errorf("parsing the proposal's created_at %q: %w", proposedAt, err)
	}
	if ownerRaw == "" {
		return "", errors.New("cannot tell whether the failed attempt posted the message: the account's own user id is unknown (sign in to the workspace again)" + slackLandedCheckNext)
	}
	// A minute of slack for clock skew between this machine and Slack.
	oldest := strconv.FormatInt(proposed.Add(-time.Minute).Unix(), 10) + ".000000"
	msgs, more, err := sender.RecentMessages(ctx, channel, thread, oldest)
	if err != nil {
		return "", fmt.Errorf("checking whether the failed attempt posted the message: %w", err)
	}
	want := normalizeSlackText(text)
	for _, m := range msgs {
		if m.User == ownerRaw && normalizeSlackText(m.Text) == want && m.TS != thread {
			return m.TS, nil
		}
	}
	if more {
		return "", errors.New("cannot tell whether the failed attempt posted the message: the conversation has more messages since the proposal than the check reads" + slackLandedCheckNext)
	}
	return "", nil
}

// NewSendSlackMessage builds the send_slack_message write tool. External
// (AGENT-03: never execute trust); in a project session it is recorded as a
// pending proposal the owner approves in the Desktop (DEV-06 amendment).
func NewSendSlackMessage(factory SlackSenderFactory) *Tool {
	return &Tool{
		Name: "send_slack_message",
		Description: "Propose sending a Slack message as the owner — to a channel, a thread (pass a message link), or a " +
			"person (DM). Call get_writing_style first and write the text in the owner's own voice: their language, " +
			"their tone for this audience, short. Nothing is sent until the owner approves the card; they may edit the " +
			"text first. When the recipient exists in several workspaces the owner picks one on the card.",
		InputSchema:             mustSchema[sendSlackMessageArgs]("send_slack_message"),
		Access:                  AccessWrite,
		External:                true,
		Surfaces:                []string{"main", "project"},
		ProposeUnderDirectApply: true,
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a sendSlackMessageArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if err := checkSlackText(a.Text); err != nil {
				return err
			}
			_, err := resolveSlackRecipients(ctx, d, a)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a sendSlackMessageArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			found, err := resolveSlackRecipients(ctx, d, a)
			if err != nil {
				return nil, err
			}
			return pinSlackRecipients(raw, found)
		},
		Revise: reviseSlackSend,
		Ready:  slackSendReady,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			s, err := decodeStoredSlackSend(call.Args)
			if err != nil {
				return nil, err
			}
			if err := slackSendReady(call.Args); err != nil {
				return nil, err
			}
			return executeSlackSend(ctx, d, factory, call, s)
		},
	}
}

func executeSlackSend(ctx context.Context, d *db.DB, factory SlackSenderFactory, call Call, s storedSlackSend) (any, error) {
	// Did any earlier attempt reach chat.postMessage? Only then can a message
	// have landed, and only then does a retry look for it first.
	mayHaveLanded, proposedAt := false, ""
	if call.Retry {
		row, err := d.GetAgentAction(call.ActionID)
		if err != nil {
			return nil, err
		}
		if row == nil {
			return nil, fmt.Errorf("action #%d not found", call.ActionID)
		}
		mayHaveLanded, proposedAt = !strings.HasPrefix(row.Error, SlackNotSentPrefix), row.CreatedAt
	}
	notSent := func(err error) error {
		if mayHaveLanded {
			return err
		}
		return fmt.Errorf("%s%w", SlackNotSentPrefix, err)
	}
	t := s.Target
	account, err := d.GetSlackAccount(t.AccountID)
	if err != nil {
		return nil, notSent(err)
	}
	if !account.Enabled || account.Status == "removed" {
		return nil, notSent(fmt.Errorf("slack workspace %s is disabled or removed; enable it, or ask for the message again", slackWorkspaceName(account)))
	}
	text, err := rawSlackMentions(s.Text, account.ID)
	if err != nil {
		return nil, notSent(err)
	}
	sender, scope, err := factory(account)
	if err != nil {
		return nil, notSent(err)
	}
	if scope != "" && !(&slack.Token{Scope: scope}).HasScope(slack.SendScope) {
		return nil, notSent(slackScopeError(account))
	}
	channel := t.ChannelID
	if channel == "" {
		if channel, err = sender.OpenDM(ctx, t.UserID); err != nil {
			return nil, notSent(slackSendFailed(account, "conversations.open", err))
		}
	}
	ts, reused := "", false
	if mayHaveLanded {
		_, ownerRaw, _ := slack.SplitAccountID(account.CurrentUserID)
		if ts, err = findLandedSlackMessage(ctx, sender, proposedAt, ownerRaw, channel, t.ThreadTS, text); err != nil {
			return nil, err
		}
		reused = ts != ""
	}
	if ts == "" {
		if ts, err = sender.PostMessage(ctx, channel, text, t.ThreadTS); err != nil {
			failed := slackSendFailed(account, "chat.postMessage", err)
			if slackRejected(err) {
				return nil, notSent(failed) // refused by Slack: nothing posted
			}
			return nil, failed // a timeout or a lost answer may have posted it
		}
	}
	result := map[string]any{"channel_id": channel, "ts": ts, "workspace": slackWorkspaceName(account),
		"label": "Message to " + t.Label}
	if account.TeamDomain != "" {
		result["url"] = slack.GeneratePermalink(account.TeamDomain, channel, ts)
	}
	if reused {
		result["reused"] = true
	}
	return result, nil
}
