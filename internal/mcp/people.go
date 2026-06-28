package mcp

import (
	"context"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type getPersonArgs struct {
	UserID string `json:"user_id" jsonschema:"Slack user id of the person"`
}

type listTracksArgs struct {
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getTrackArgs struct {
	ID int `json:"id" jsonschema:"track id"`
}

type listUpcomingEventsArgs struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-ahead window in hours, default 48"`
}

func registerPeople(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_people",
		Description: "List people cards (per-person communication and collaboration profiles).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, _ struct{}) (*mcpsdk.CallToolResult, any, error) {
		cards, err := database.GetPeopleCards(db.PeopleCardFilter{})
		if err != nil {
			return errResult("listing people: " + err.Error()), nil, nil
		}
		return jsonListResult(cards)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_person",
		Description: "Get the latest people card for a person by Slack user id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getPersonArgs) (*mcpsdk.CallToolResult, any, error) {
		card, err := database.GetLatestPeopleCard(args.UserID)
		if err != nil {
			return errResult("getting person: " + err.Error()), nil, nil
		}
		if card == nil {
			return errResult("no people card for user " + args.UserID), nil, nil
		}
		return jsonResult(card)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_tracks",
		Description: "List work/narrative tracks (active by default), optionally filtered by priority or ownership.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTracksArgs) (*mcpsdk.CallToolResult, any, error) {
		tracks, err := database.GetTracks(db.TrackFilter{
			Priority:  args.Priority,
			Ownership: args.Ownership,
			Limit:     args.Limit,
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
			return errResult("getting track: " + err.Error()), nil, nil
		}
		if track == nil {
			return errResult("no track with id " + itoa(args.ID)), nil, nil
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
		})
		if err != nil {
			return errResult("listing events: " + err.Error()), nil, nil
		}
		return jsonListResult(events)
	})
}
