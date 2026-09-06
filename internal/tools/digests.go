package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
)

type getTodayBriefingArgs struct{}

type listDigestsArgs struct {
	Type    string `json:"type,omitempty" jsonschema:"digest type: channel|daily|weekly"`
	Channel string `json:"channel,omitempty" jsonschema:"channel id to filter by"`
	Since   string `json:"since,omitempty" jsonschema:"only digests whose period starts on/after this date (YYYY-MM-DD or RFC3339)"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getDigestArgs struct {
	ID int `json:"id" jsonschema:"digest id"`
}

// parseSince accepts a date (YYYY-MM-DD, local midnight) or an RFC3339 timestamp.
func parseSince(s string) (time.Time, error) {
	if t, err := time.ParseInLocation("2006-01-02", s, time.Local); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, s)
}

// mustSchema builds the input schema for a read tool's args, panicking on the
// impossible failure — a tool author's struct that jsonschema cannot describe is
// a build-time bug, not a runtime condition.
func mustSchema[T any](tool string) *jsonschema.Schema {
	schema, err := jsonschema.For[T](nil)
	if err != nil {
		panic(tool + " schema: " + err.Error())
	}
	return schema
}

// NewGetTodayBriefing returns today's daily briefing (null when it has not been
// generated yet). Thin adapter over db.GetBriefing for the current user.
func NewGetTodayBriefing() *Tool {
	return &Tool{
		Name:        "get_today_briefing",
		Description: "Get today's daily briefing (your personalized roll-up of what needs attention). Returns null if today's briefing hasn't been generated yet.",
		InputSchema: mustSchema[getTodayBriefingArgs]("get_today_briefing"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			userID, err := d.GetCurrentUserID()
			if err != nil {
				return nil, fmt.Errorf("getting current user: %w", err)
			}
			today := time.Now().Format("2006-01-02")
			briefing, err := d.GetBriefing(userID, today)
			if err != nil {
				return nil, fmt.Errorf("getting briefing: %w", err)
			}
			// GetBriefing returns (nil, nil) when today's briefing doesn't exist
			// yet; a nil result marshals to JSON null, never a stale older one.
			return briefing, nil
		},
	}
}

// NewListDigests lists channel/daily/weekly digests, most recent first.
func NewListDigests() *Tool {
	return &Tool{
		Name:        "list_digests",
		Description: "List channel/daily/weekly digests (AI summaries of Slack activity), most recent first.",
		InputSchema: mustSchema[listDigestsArgs]("list_digests"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listDigestsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if a.Type != "" && !slices.Contains([]string{"channel", "daily", "weekly"}, a.Type) {
				return nil, &ValidationError{Msg: fmt.Sprintf("invalid type %q: must be one of channel|daily|weekly", a.Type)}
			}
			var fromUnix float64
			if a.Since != "" {
				ts, err := parseSince(a.Since)
				if err != nil {
					return nil, &ValidationError{Msg: fmt.Sprintf("invalid since %q: use YYYY-MM-DD or RFC3339", a.Since)}
				}
				fromUnix = float64(ts.Unix())
			}
			digests, err := d.GetDigests(db.DigestFilter{
				Type: a.Type, ChannelID: a.Channel, FromUnix: fromUnix, Limit: listLimit(a.Limit),
			})
			if err != nil {
				return nil, fmt.Errorf("listing digests: %w", err)
			}
			if digests == nil {
				digests = []db.Digest{}
			}
			return digests, nil
		},
	}
}

// NewGetDigest fetches one digest by id, including its full summary.
func NewGetDigest() *Tool {
	return &Tool{
		Name:        "get_digest",
		Description: "Get a single digest by id, including its full summary.",
		InputSchema: mustSchema[getDigestArgs]("get_digest"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getDigestArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			digest, err := d.GetDigestByID(a.ID)
			if err != nil {
				return nil, fmt.Errorf("getting digest: %w", err)
			}
			if digest == nil {
				return nil, fmt.Errorf("no digest with id %d", a.ID)
			}
			return digest, nil
		},
	}
}
