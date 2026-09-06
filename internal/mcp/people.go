package mcp

import (
	"context"
	"strconv"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type getPersonArgs struct {
	Query string `json:"query" jsonschema:"Slack user id (U…) or a person's name (username, display or real name, partial match)"`
}

// registerPeople mounts get_person — the last people read still living in
// internal/mcp. list_people/list_tracks/get_track/list_upcoming_events moved
// into the registry (internal/tools/people_read.go); get_person is HEAVY (a
// user-id hit, then a name search with ambiguity handling) and migrates in the
// heavy phase.
func registerPeople(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_person",
		Description: "Get the latest people card for a person by Slack user id or name.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getPersonArgs) (*mcpsdk.CallToolResult, any, error) {
		// Exact user-id hit first; fall back to name search for human callers
		// (LLM clients rarely know Slack ids).
		card, err := database.GetLatestPeopleCard(args.Query)
		if err != nil {
			return errResult("getting person: " + err.Error()), nil, nil
		}
		if card != nil {
			return jsonResult(card)
		}

		users, err := database.SearchUsersByName(args.Query, 10)
		if err != nil {
			return errResult("searching users: " + err.Error()), nil, nil
		}
		var cards []*db.PeopleCard
		var carded []db.User
		for _, u := range users {
			c, err := database.GetLatestPeopleCard(u.ID)
			if err != nil {
				return errResult("getting person: " + err.Error()), nil, nil
			}
			if c != nil {
				cards = append(cards, c)
				carded = append(carded, u)
			}
		}
		switch len(cards) {
		case 0:
			return errResult("no people card for " + strconv.Quote(args.Query)), nil, nil
		case 1:
			return jsonResult(cards[0])
		default:
			var opts []string
			for _, u := range carded {
				opts = append(opts, u.ID+" ("+u.Name+")")
			}
			return errResult("ambiguous query " + strconv.Quote(args.Query) +
				": matches " + strings.Join(opts, ", ") + " — pass a user id"), nil, nil
		}
	})
}
