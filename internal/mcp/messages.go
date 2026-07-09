package mcp

import (
	"context"
	"strconv"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listMessagesArgs struct {
	Person  string `json:"person,omitempty" jsonschema:"filter to one person's messages: Slack user id (U…) or a name (username, display or real name, partial match)"`
	Channel string `json:"channel,omitempty" jsonschema:"filter to one channel: Slack channel id (C…) or a channel name"`
	Query   string `json:"query,omitempty" jsonschema:"optional keywords for full-text search of the message body"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (30), capped at 200"`
}

// messageResult is the LLM-facing shape of one message: senders and channels
// are rendered as human names (not raw Slack ids) so the assistant echoes names
// back to the user.
type messageResult struct {
	Timestamp string `json:"ts"`
	Channel   string `json:"channel"`
	Sender    string `json:"sender"`
	Text      string `json:"text"`
	Permalink string `json:"permalink,omitempty"`
}

func registerMessages(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_messages",
		Description: "Search/list raw Slack messages from the local database, filtered by person, " +
			"channel, and/or keyword. Use this to find what a specific person said (e.g. the open " +
			"questions they handed over). At least one of person/channel/query is required. Newest first.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listMessagesArgs) (*mcpsdk.CallToolResult, any, error) {
		opts := db.SearchOpts{Limit: messageLimit(args.Limit)}

		if args.Person != "" {
			userIDs, msg := resolvePerson(database, args.Person)
			if msg != "" {
				return errResult(msg), nil, nil
			}
			opts.UserIDs = userIDs
		}

		if args.Channel != "" {
			channelID, msg := resolveChannel(database, args.Channel)
			if msg != "" {
				return errResult(msg), nil, nil
			}
			opts.ChannelIDs = []string{channelID}
		}

		if args.Person == "" && args.Channel == "" && args.Query == "" {
			return errResult("provide at least one filter: person, channel, or query"), nil, nil
		}

		var msgs []db.Message
		var err error
		if args.Query != "" {
			msgs, err = database.SearchMessages(args.Query, opts)
		} else {
			msgs, err = database.ListRecentMessages(opts)
		}
		if err != nil {
			return errResult("searching messages: " + err.Error()), nil, nil
		}

		return jsonListResult(renderMessages(database, msgs))
	})
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
// matching user ids. Returns a human-readable error message (non-empty) when
// the reference cannot be resolved or is ambiguous beyond a workable set.
func resolvePerson(database *db.DB, person string) (userIDs []string, errMsg string) {
	// A Slack user id (U…/W…) is taken verbatim — LLM callers that already have
	// an id from another tool should not be re-fuzzed against names.
	if looksLikeUserID(person) {
		return []string{person}, ""
	}
	users, err := database.SearchUsersByName(person, 10)
	if err != nil {
		return nil, "resolving person: " + err.Error()
	}
	if len(users) == 0 {
		return nil, "no person matches " + strconv.Quote(person)
	}
	for _, u := range users {
		userIDs = append(userIDs, u.ID)
	}
	return userIDs, ""
}

// resolveChannel turns a channel reference (channel id or name) into a channel
// id. Returns a human-readable error message (non-empty) when unresolved.
func resolveChannel(database *db.DB, channel string) (channelID, errMsg string) {
	if strings.HasPrefix(channel, "C") && !strings.ContainsAny(channel, " #") {
		if c, err := database.GetChannelByID(channel); err == nil && c != nil {
			return c.ID, ""
		}
	}
	name := strings.TrimPrefix(channel, "#")
	c, err := database.GetChannelByName(name)
	if err != nil || c == nil {
		return "", "no channel matches " + strconv.Quote(channel)
	}
	return c.ID, ""
}

// looksLikeUserID reports whether s is shaped like a bare Slack user id:
// a leading U or W followed by all-uppercase alphanumerics (e.g. U08UA26G342).
// The strict shape keeps ordinary names that merely start with U/W (e.g.
// "Ulyana") on the name-resolution path instead of being mistaken for an id.
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
func renderMessages(database *db.DB, msgs []db.Message) []messageResult {
	channelNames := map[string]string{}
	out := make([]messageResult, 0, len(msgs))
	for _, m := range msgs {
		sender, _ := database.UserNameByID(m.UserID)
		channel, ok := channelNames[m.ChannelID]
		if !ok {
			channel = m.ChannelID
			if c, err := database.GetChannelByID(m.ChannelID); err == nil && c != nil && c.Name != "" {
				channel = c.Name
			}
			channelNames[m.ChannelID] = channel
		}
		out = append(out, messageResult{
			Timestamp: m.TS,
			Channel:   channel,
			Sender:    sender,
			Text:      m.Text,
			Permalink: m.Permalink,
		})
	}
	return out
}
