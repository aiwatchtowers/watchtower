package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

type listPeopleArgs struct {
	Limit int `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type listTracksArgs struct {
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getPersonArgs struct {
	Query string `json:"query" jsonschema:"Slack user id (U…) or a person's name (username, display or real name, partial match)"`
}

type getTrackArgs struct {
	ID int `json:"id" jsonschema:"track id"`
}

type listUpcomingEventsArgs struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-ahead window in hours, default 48"`
	Limit int `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

// NewListPeople lists people cards (per-person communication profiles).
func NewListPeople() *Tool {
	return &Tool{
		Name:        "list_people",
		Description: "List people cards (per-person communication and collaboration profiles).",
		InputSchema: mustSchema[listPeopleArgs]("list_people"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listPeopleArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			cards, err := d.GetPeopleCards(db.PeopleCardFilter{Limit: listLimit(a.Limit)})
			if err != nil {
				return nil, fmt.Errorf("listing people: %w", err)
			}
			if cards == nil {
				cards = []db.PeopleCard{}
			}
			return cards, nil
		},
	}
}

// NewGetPerson fetches the latest people card for a person by Slack user id or
// name: an exact user-id hit first, then a name search with ambiguity handling
// (LLM clients rarely know Slack ids).
func NewGetPerson() *Tool {
	return &Tool{
		Name:        "get_person",
		Description: "Get the latest people card for a person by Slack user id or name.",
		InputSchema: mustSchema[getPersonArgs]("get_person"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getPersonArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			card, err := d.GetLatestPeopleCard(a.Query)
			if err != nil {
				return nil, fmt.Errorf("getting person: %w", err)
			}
			if card != nil {
				return card, nil
			}
			users, err := d.SearchUsersByName(a.Query, 10)
			if err != nil {
				return nil, fmt.Errorf("searching users: %w", err)
			}
			var cards []*db.PeopleCard
			var carded []db.User
			for _, u := range users {
				c, err := d.GetLatestPeopleCard(u.ID)
				if err != nil {
					return nil, fmt.Errorf("getting person: %w", err)
				}
				if c != nil {
					cards = append(cards, c)
					carded = append(carded, u)
				}
			}
			switch len(cards) {
			case 0:
				return nil, fmt.Errorf("no people card for %s", strconv.Quote(a.Query))
			case 1:
				return cards[0], nil
			default:
				opts := make([]string, 0, len(carded))
				for _, u := range carded {
					opts = append(opts, u.ID+" ("+u.Name+")")
				}
				return nil, fmt.Errorf("ambiguous query %s: matches %s — pass a user id", strconv.Quote(a.Query), strings.Join(opts, ", "))
			}
		},
	}
}

// NewListTracks lists work/narrative tracks (active by default), filterable by
// priority or ownership.
func NewListTracks() *Tool {
	return &Tool{
		Name:        "list_tracks",
		Description: "List work/narrative tracks (active by default), optionally filtered by priority or ownership.",
		InputSchema: mustSchema[listTracksArgs]("list_tracks"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listTracksArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if err := firstErr(
				validateEnum("priority", a.Priority, "high", "medium", "low"),
				validateEnum("ownership", a.Ownership, "mine", "delegated", "watching"),
			); err != nil {
				return nil, err
			}
			tracks, err := d.GetTracks(db.TrackFilter{Priority: a.Priority, Ownership: a.Ownership, Limit: listLimit(a.Limit)})
			if err != nil {
				return nil, fmt.Errorf("listing tracks: %w", err)
			}
			if tracks == nil {
				tracks = []db.Track{}
			}
			return tracks, nil
		},
	}
}

// NewGetTrack fetches one track by id.
func NewGetTrack() *Tool {
	return &Tool{
		Name:        "get_track",
		Description: "Get a single track by id.",
		InputSchema: mustSchema[getTrackArgs]("get_track"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getTrackArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			track, err := d.GetTrackByID(a.ID)
			if err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					return nil, fmt.Errorf("no track with id %d", a.ID)
				}
				return nil, fmt.Errorf("getting track: %w", err)
			}
			return track, nil
		},
	}
}

// NewListUpcomingEvents lists calendar events in the next N hours (default 48).
func NewListUpcomingEvents() *Tool {
	return &Tool{
		Name:        "list_upcoming_events",
		Description: "List calendar events in the next N hours (default 48).",
		InputSchema: mustSchema[listUpcomingEventsArgs]("list_upcoming_events"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listUpcomingEventsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			hours := a.Hours
			if hours <= 0 {
				hours = 48
			}
			now := time.Now().UTC()
			events, err := d.GetCalendarEvents(db.CalendarEventFilter{
				FromTime: now.Format(time.RFC3339),
				ToTime:   now.Add(time.Duration(hours) * time.Hour).Format(time.RFC3339),
				Limit:    listLimit(a.Limit),
			})
			if err != nil {
				return nil, fmt.Errorf("listing events: %w", err)
			}
			if events == nil {
				events = []db.CalendarEvent{}
			}
			return events, nil
		},
	}
}
