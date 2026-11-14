package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

type listMessagesArgs struct {
	Person  string `json:"person,omitempty" jsonschema:"filter to one person's messages: Slack user id, raw (U…) or namespaced (1:U…; a raw id matches that user in every connected workspace), or a name (username, display or real name, partial match)"`
	Channel string `json:"channel,omitempty" jsonschema:"filter to one channel: Slack channel id, raw (C…/G…/D…) or namespaced (1:C…; a raw id matches that channel in every connected workspace), or a channel name"`
	Query   string `json:"query,omitempty" jsonschema:"optional keywords for full-text search of the message body"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (30), capped at 200"`
}

// messageResult is the LLM-facing shape of one message: senders and channels are
// rendered as human names (not raw Slack ids) so the assistant echoes names back.
type messageResult struct {
	Timestamp string `json:"ts"`
	Channel   string `json:"channel"`
	Sender    string `json:"sender"`
	Text      string `json:"text"`
	Permalink string `json:"permalink,omitempty"`
}

// listMessagesResult is list_messages' answer: the messages and what the
// local Slack copy covers, so the assistant knows when to ask Live Slack.
type listMessagesResult struct {
	Messages []messageResult       `json:"messages"`
	Coverage messageCoverageResult `json:"coverage"`
}

// messageCoverageResult: scope is "own" when an enabled, working Slack
// account exists, else "none"; synced_through and backfill_from are "" when
// unknown; channel_in_scope is null unless the call named a channel.
type messageCoverageResult struct {
	Scope          string `json:"scope"`
	SyncedThrough  string `json:"synced_through"`
	BackfillFrom   string `json:"backfill_from"`
	ChannelInScope *bool  `json:"channel_in_scope"`
}

func messageCoverage(d *db.DB, inScope *bool) (messageCoverageResult, error) {
	c, err := d.SlackCoverage()
	if err != nil {
		return messageCoverageResult{}, fmt.Errorf("slack coverage: %w", err)
	}
	out := messageCoverageResult{Scope: "none", ChannelInScope: inScope}
	if c.Own {
		out.Scope = "own"
	}
	if !c.SyncedThrough.IsZero() {
		out.SyncedThrough = c.SyncedThrough.Format(time.RFC3339)
	}
	if !c.BackfillFrom.IsZero() {
		out.BackfillFrom = c.BackfillFrom.Format("2006-01-02")
	}
	if !c.Own && inScope != nil {
		f := false
		out.ChannelInScope = &f
	}
	return out, nil
}

// channelInScope is true when one of the resolved channels is synced for
// the owner: a member channel or a direct message.
func channelInScope(d *db.DB, ids []string) (*bool, error) {
	in := false
	for _, id := range ids {
		c, err := d.GetChannelByID(id)
		if err != nil {
			return nil, fmt.Errorf("resolving channel: %w", err)
		}
		if c != nil && !c.IsArchived && (c.IsMember || c.Type == "dm" || c.Type == "group_dm") {
			in = true
		}
	}
	return &in, nil
}

// NewListMessages searches/lists raw Slack messages, filtered by person,
// channel, and/or keyword. At least one filter is required.
func NewListMessages() *Tool {
	return &Tool{
		Name: "list_messages",
		Description: "Search/list raw Slack messages from the local database, filtered by person, " +
			"channel, and/or keyword. Use this to find what a specific person said (e.g. the open " +
			"questions they handed over). At least one of person/channel/query is required. Newest first.",
		InputSchema: mustSchema[listMessagesArgs]("list_messages"),
		Access:      AccessRead,
		CompanyData: true,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listMessagesArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			opts := db.SearchOpts{Limit: messageLimit(a.Limit)}
			if a.Person != "" {
				userIDs, err := resolvePerson(d, a.Person)
				if err != nil {
					return nil, err
				}
				opts.UserIDs = userIDs
			}
			var inScope *bool
			if a.Channel != "" {
				channelIDs, err := resolveChannel(d, a.Channel)
				if err != nil {
					return nil, err
				}
				opts.ChannelIDs = channelIDs
				if inScope, err = channelInScope(d, channelIDs); err != nil {
					return nil, err
				}
			}
			if a.Person == "" && a.Channel == "" && a.Query == "" {
				return nil, &ValidationError{Msg: "provide at least one filter: person, channel, or query"}
			}
			var msgs []db.Message
			var err error
			if a.Query != "" {
				msgs, err = d.SearchMessages(a.Query, opts)
			} else {
				msgs, err = d.ListRecentMessages(opts)
			}
			if err != nil {
				return nil, fmt.Errorf("searching messages: %w", err)
			}
			if call.Binding.Surface != "main" {
				// Every other surface (automations, embedded chats, MCP) keeps the
				// bare array: recipes and templates parse it (confirmed hashes).
				return renderMessages(d, msgs), nil
			}
			cov, err := messageCoverage(d, inScope)
			if err != nil {
				return nil, err
			}
			return listMessagesResult{Messages: renderMessages(d, msgs), Coverage: cov}, nil
		},
	}
}

// messageLimit mirrors listLimit but with a tighter default: raw messages are
// verbose, so an unbounded call defaults to 30 rather than 50.
func messageLimit(n int) int {
	if n <= 0 {
		return 30
	}
	if n > MaxListLimit {
		return MaxListLimit
	}
	return n
}

// resolvePerson turns a person reference (user id or name) into the set of
// matching user ids, or a model-facing *ValidationError when it cannot resolve.
func resolvePerson(d *db.DB, person string) ([]string, error) {
	// A Slack user id (U…/W…, raw or namespaced) is taken as an id — LLM
	// callers that already have one from another tool should not be re-fuzzed
	// against names. It expands to every stored form (slackIDForms).
	if looksLikeUserID(person) {
		return slackIDForms(d, person)
	}
	users, err := d.SearchUsersByName(person, 10)
	if err != nil {
		return nil, fmt.Errorf("resolving person: %w", err)
	}
	if len(users) == 0 {
		return nil, &ValidationError{Msg: "no person matches " + strconv.Quote(person)}
	}
	userIDs := make([]string, 0, len(users))
	for _, u := range users {
		userIDs = append(userIDs, u.ID)
	}
	return userIDs, nil
}

// resolveChannel turns a channel reference (channel id or name) into the
// stored channel ids it names, or a model-facing *ValidationError when
// unresolved. A raw id known in several workspaces returns each of them.
func resolveChannel(d *db.DB, channel string) ([]string, error) {
	if looksLikeChannelID(channel) {
		forms, err := slackIDForms(d, channel)
		if err != nil {
			return nil, err
		}
		var ids []string
		for _, id := range forms {
			c, err := d.GetChannelByID(id)
			if err != nil {
				return nil, fmt.Errorf("resolving channel: %w", err)
			}
			if c != nil {
				ids = append(ids, c.ID)
			}
		}
		if len(ids) > 0 {
			return ids, nil
		}
	}
	name := strings.TrimPrefix(channel, "#")
	c, err := d.GetChannelByName(name)
	if err != nil {
		return nil, fmt.Errorf("resolving channel: %w", err)
	}
	if c == nil {
		return nil, &ValidationError{Msg: "no channel matches " + strconv.Quote(channel)}
	}
	return []string{c.ID}, nil
}

// renderMessages resolves sender/channel ids to display names for the LLM.
func renderMessages(d *db.DB, msgs []db.Message) []messageResult {
	channelNames := map[string]string{}
	out := make([]messageResult, 0, len(msgs))
	for _, m := range msgs {
		sender, _ := d.UserNameByID(m.UserID)
		channel, ok := channelNames[m.ChannelID]
		if !ok {
			channel = m.ChannelID
			if c, err := d.GetChannelByID(m.ChannelID); err == nil && c != nil && c.Name != "" {
				channel = c.Name
			}
			channelNames[m.ChannelID] = channel
		}
		out = append(out, messageResult{
			Timestamp: m.TS, Channel: channel, Sender: sender, Text: m.Text, Permalink: m.Permalink,
		})
	}
	return out
}
