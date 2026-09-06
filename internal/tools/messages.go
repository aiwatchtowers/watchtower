package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

type listMessagesArgs struct {
	Person  string `json:"person,omitempty" jsonschema:"filter to one person's messages: Slack user id (U…) or a name (username, display or real name, partial match)"`
	Channel string `json:"channel,omitempty" jsonschema:"filter to one channel: Slack channel id (C…) or a channel name"`
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
			if a.Channel != "" {
				channelID, err := resolveChannel(d, a.Channel)
				if err != nil {
					return nil, err
				}
				opts.ChannelIDs = []string{channelID}
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
			return renderMessages(d, msgs), nil
		},
	}
}

// messageLimit mirrors listLimit but with a tighter default: raw messages are
// verbose, so an unbounded call defaults to 30 rather than 50.
func messageLimit(n int) int {
	if n <= 0 {
		return 30
	}
	if n > maxListLimit {
		return maxListLimit
	}
	return n
}

// resolvePerson turns a person reference (user id or name) into the set of
// matching user ids, or a model-facing *ValidationError when it cannot resolve.
func resolvePerson(d *db.DB, person string) ([]string, error) {
	// A Slack user id (U…/W…) is taken verbatim — LLM callers that already have
	// an id from another tool should not be re-fuzzed against names.
	if looksLikeUserID(person) {
		return []string{person}, nil
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

// resolveChannel turns a channel reference (channel id or name) into a channel
// id, or a model-facing *ValidationError when unresolved.
func resolveChannel(d *db.DB, channel string) (string, error) {
	if strings.HasPrefix(channel, "C") && !strings.ContainsAny(channel, " #") {
		if c, err := d.GetChannelByID(channel); err == nil && c != nil {
			return c.ID, nil
		}
	}
	name := strings.TrimPrefix(channel, "#")
	c, err := d.GetChannelByName(name)
	if err != nil || c == nil {
		return "", &ValidationError{Msg: "no channel matches " + strconv.Quote(channel)}
	}
	return c.ID, nil
}

// looksLikeUserID reports whether s is shaped like a bare Slack user id: a
// leading U or W followed by all-uppercase alphanumerics (e.g. U08UA26G342). The
// strict shape keeps ordinary names that merely start with U/W (e.g. "Ulyana")
// on the name-resolution path instead of being mistaken for an id.
func looksLikeUserID(s string) bool {
	if len(s) < 8 || (s[0] != 'U' && s[0] != 'W') {
		return false
	}
	for _, r := range s[1:] {
		if !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') {
			return false
		}
	}
	return true
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
