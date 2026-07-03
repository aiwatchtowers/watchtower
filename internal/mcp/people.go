package mcp

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"strings"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listPeopleArgs struct {
	Limit int `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getPersonArgs struct {
	Query string `json:"query" jsonschema:"Slack user id (U…) or a person's name (username, display or real name, partial match)"`
}

type listTracksArgs struct {
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getTrackArgs struct {
	ID int `json:"id" jsonschema:"track id"`
}

type listUpcomingEventsArgs struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-ahead window in hours, default 48"`
	Limit int `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

func registerPeople(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_people",
		Description: "List people cards (per-person communication and collaboration profiles).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listPeopleArgs) (*mcpsdk.CallToolResult, any, error) {
		cards, err := database.GetPeopleCards(db.PeopleCardFilter{Limit: listLimit(args.Limit)})
		if err != nil {
			return errResult("listing people: " + err.Error()), nil, nil
		}
		return jsonListResult(cards)
	})

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

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_tracks",
		Description: "List work/narrative tracks (active by default), optionally filtered by priority or ownership.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTracksArgs) (*mcpsdk.CallToolResult, any, error) {
		if msg := firstError(
			validateEnum("priority", args.Priority, "high", "medium", "low"),
			validateEnum("ownership", args.Ownership, "mine", "delegated", "watching"),
		); msg != "" {
			return errResult(msg), nil, nil
		}
		tracks, err := database.GetTracks(db.TrackFilter{
			Priority:  args.Priority,
			Ownership: args.Ownership,
			Limit:     listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing tracks: " + err.Error()), nil, nil
		}
		return jsonListResult(tracks)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_track",
		Description: "Get a single track by id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTrackArgs) (*mcpsdk.CallToolResult, any, error) {
		track, err := database.GetTrackByID(args.ID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return errResult("no track with id " + itoa(args.ID)), nil, nil
			}
			return errResult("getting track: " + err.Error()), nil, nil
		}
		return jsonResult(track)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_upcoming_events",
		Description: "List calendar events in the next N hours (default 48).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listUpcomingEventsArgs) (*mcpsdk.CallToolResult, any, error) {
		hours := args.Hours
		if hours <= 0 {
			hours = 48
		}
		now := time.Now().UTC()
		events, err := database.GetCalendarEvents(db.CalendarEventFilter{
			FromTime: now.Format(time.RFC3339),
			ToTime:   now.Add(time.Duration(hours) * time.Hour).Format(time.RFC3339),
			Limit:    listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing events: " + err.Error()), nil, nil
		}
		return jsonListResult(events)
	})
}
