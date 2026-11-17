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
	Query string `json:"query" jsonschema:"Slack user id, raw (U…) or namespaced (1:U…), or a person's name (username, display or real name, partial match). A raw id with a people card in several workspaces is ambiguous — pass the namespaced id"`
}

type getTrackArgs struct {
	ID int `json:"id" jsonschema:"track id"`
}

type listUpcomingEventsArgs struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-ahead window in hours, default 48"`
	Limit int `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

// personOutput is what list_people and get_person return for a people card:
// today's db.PeopleCard record minus the four fields dropped by #1769 (A12,
// A24) — AvgMessageLength, ActiveHoursJSON, VolumeChangePct, RedFlags. No
// json tags, so the remaining keys keep their Go field names and order for
// every reader (the chat's person source, gallery templates, owners' recipes,
// MCP clients).
type personOutput struct {
	ID                  int
	UserID              string
	PeriodFrom          float64
	PeriodTo            float64
	MessageCount        int
	ChannelsActive      int
	ThreadsInitiated    int
	ThreadsReplied      int
	Summary             string
	CommunicationStyle  string
	DecisionRole        string
	Highlights          string
	Accomplishments     string
	CommunicationGuide  string
	DecisionStyle       string
	Tactics             string
	RelationshipContext string
	Status              string
	Model               string
	InputTokens         int
	OutputTokens        int
	CostUSD             float64
	PromptVersion       int
	CreatedAt           string
}

func newPersonOutput(c db.PeopleCard) personOutput {
	return personOutput{
		ID:                  c.ID,
		UserID:              c.UserID,
		PeriodFrom:          c.PeriodFrom,
		PeriodTo:            c.PeriodTo,
		MessageCount:        c.MessageCount,
		ChannelsActive:      c.ChannelsActive,
		ThreadsInitiated:    c.ThreadsInitiated,
		ThreadsReplied:      c.ThreadsReplied,
		Summary:             c.Summary,
		CommunicationStyle:  c.CommunicationStyle,
		DecisionRole:        c.DecisionRole,
		Highlights:          c.Highlights,
		Accomplishments:     c.Accomplishments,
		CommunicationGuide:  c.CommunicationGuide,
		DecisionStyle:       c.DecisionStyle,
		Tactics:             c.Tactics,
		RelationshipContext: c.RelationshipContext,
		Status:              c.Status,
		Model:               c.Model,
		InputTokens:         c.InputTokens,
		OutputTokens:        c.OutputTokens,
		CostUSD:             c.CostUSD,
		PromptVersion:       c.PromptVersion,
		CreatedAt:           c.CreatedAt,
	}
}

// NewListPeople lists people cards (per-person communication profiles).
func NewListPeople() *Tool {
	return &Tool{
		Name:        "list_people",
		Description: "List people cards (per-person communication and collaboration profiles).",
		InputSchema: mustSchema[listPeopleArgs]("list_people"),
		Access:      AccessRead,
		CompanyData: true,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listPeopleArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			cards, err := d.GetPeopleCards(db.PeopleCardFilter{Limit: listLimit(a.Limit)})
			if err != nil {
				return nil, fmt.Errorf("listing people: %w", err)
			}
			out := make([]personOutput, 0, len(cards))
			for _, c := range cards {
				out = append(out, newPersonOutput(c))
			}
			return out, nil
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
		CompanyData: true,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getPersonArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			card, err := personCardByID(d, a.Query)
			if err != nil {
				return nil, err
			}
			if card != nil {
				return newPersonOutput(*card), nil
			}
			users, err := d.SearchUsersByName(a.Query, 10)
			if err != nil {
				return nil, fmt.Errorf("searching users: %w", err)
			}
			u, err := resolvePersonByName(a.Query, users)
			if err != nil {
				return nil, err
			}
			c, err := d.GetLatestPeopleCard(u.ID)
			if err != nil {
				return nil, fmt.Errorf("getting person: %w", err)
			}
			if c != nil {
				return newPersonOutput(*c), nil
			}
			if err := stoppedCardError(d, []string{u.ID}); err != nil {
				return nil, err
			}
			return nil, fmt.Errorf("no people card for %s", strconv.Quote(a.Query))
		},
	}
}

// personCardByID looks query up as a Slack user id, raw or namespaced
// (slackIDForms). It returns (nil, nil) when no card matches, so the caller
// falls through to name search. A raw id with a people card under several Slack accounts
// is an ambiguity error naming each namespaced id: get_person returns one card,
// and silently picking an account would hide the other person.
func personCardByID(d *db.DB, query string) (*db.PeopleCard, error) {
	forms := []string{query}
	if looksLikeUserID(query) {
		var err error
		if forms, err = slackIDForms(d, query); err != nil {
			return nil, err
		}
	}
	var cards []*db.PeopleCard
	for _, id := range forms {
		c, err := d.GetLatestPeopleCard(id)
		if err != nil {
			return nil, fmt.Errorf("getting person: %w", err)
		}
		if c != nil {
			cards = append(cards, c)
		}
	}
	switch len(cards) {
	case 0:
		return nil, stoppedCardError(d, forms)
	case 1:
		return cards[0], nil
	default:
		ids := make([]string, 0, len(cards))
		for _, c := range cards {
			ids = append(ids, c.UserID)
		}
		return nil, fmt.Errorf("ambiguous user id %s: it exists in several Slack workspaces as %s — pass one of those", strconv.Quote(query), strings.Join(ids, ", "))
	}
}

// resolvePersonByName picks the one person a name query means among the
// substring matches of SearchUsersByName: the single exact (case-insensitive)
// name, display name or real name match, else the only match. Several
// matches with no single exact one are an ambiguity error naming each id,
// so a card — or "the owner stopped it" — is never reported for someone
// else whose name merely contains the query.
func resolvePersonByName(query string, users []db.User) (db.User, error) {
	var exact []db.User
	for _, u := range users {
		for _, n := range []string{u.Name, u.DisplayName, u.RealName} {
			if n != "" && strings.EqualFold(n, query) {
				exact = append(exact, u)
				break
			}
		}
	}
	switch {
	case len(exact) == 1:
		return exact[0], nil
	case len(exact) == 0 && len(users) == 1:
		return users[0], nil
	case len(users) == 0:
		return db.User{}, fmt.Errorf("no people card for %s", strconv.Quote(query))
	}
	candidates := exact
	if len(candidates) == 0 {
		candidates = users
	}
	opts := make([]string, 0, len(candidates))
	for _, u := range candidates {
		opts = append(opts, u.ID+" ("+u.Name+")")
	}
	return db.User{}, fmt.Errorf("ambiguous query %s: matches %s — pass a user id", strconv.Quote(query), strings.Join(opts, ", "))
}

// stoppedCardError answers a person with no card whom the owner stopped
// cards for (people exclude, #1769 A14): "no card for <id>: the owner
// stopped it", naming the first excluded id of ids. It is nil when none of
// ids is excluded.
func stoppedCardError(d *db.DB, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	excluded, err := d.PeopleExclusions()
	if err != nil {
		return fmt.Errorf("getting person: %w", err)
	}
	for _, id := range ids {
		if excluded[id] {
			return fmt.Errorf("no card for %s: the owner stopped it", id)
		}
	}
	return nil
}

// NewListTracks lists work/narrative tracks (active by default), filterable by
// priority or ownership.
func NewListTracks() *Tool {
	return &Tool{
		Name:        "list_tracks",
		Description: "List work/narrative tracks (active by default), optionally filtered by priority or ownership.",
		InputSchema: mustSchema[listTracksArgs]("list_tracks"),
		Access:      AccessRead,
		CompanyData: true,
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
		CompanyData: true,
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
		CompanyData: true,
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
