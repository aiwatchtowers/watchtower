package mcp

import (
	"context"
	"fmt"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listDigestsArgs struct {
	Type    string `json:"type,omitempty" jsonschema:"digest type: channel|daily|weekly"`
	Channel string `json:"channel,omitempty" jsonschema:"channel id to filter by"`
	Since   string `json:"since,omitempty" jsonschema:"only digests whose period starts on/after this date (YYYY-MM-DD or RFC3339)"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

// parseSince accepts a date (YYYY-MM-DD, local midnight) or an RFC3339 timestamp.
func parseSince(s string) (time.Time, error) {
	if t, err := time.ParseInLocation("2006-01-02", s, time.Local); err == nil {
		return t, nil
	}
	return time.Parse(time.RFC3339, s)
}

type getDigestArgs struct {
	ID int `json:"id" jsonschema:"digest id"`
}

func registerDigests(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_today_briefing",
		Description: "Get today's daily briefing (your personalized roll-up of what needs attention). Returns null if today's briefing hasn't been generated yet.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, _ struct{}) (*mcpsdk.CallToolResult, any, error) {
		userID, err := database.GetCurrentUserID()
		if err != nil {
			return errResult("getting current user: " + err.Error()), nil, nil
		}
		today := time.Now().Format("2006-01-02")
		briefing, err := database.GetBriefing(userID, today)
		if err != nil {
			return errResult("getting briefing: " + err.Error()), nil, nil
		}
		// GetBriefing returns (nil, nil) when today's briefing doesn't exist yet;
		// jsonResult(nil) emits JSON null rather than a stale older briefing.
		return jsonResult(briefing)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_digests",
		Description: "List channel/daily/weekly digests (AI summaries of Slack activity), most recent first.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listDigestsArgs) (*mcpsdk.CallToolResult, any, error) {
		if msg := validateEnum("type", args.Type, "channel", "daily", "weekly"); msg != "" {
			return errResult(msg), nil, nil
		}
		var fromUnix float64
		if args.Since != "" {
			ts, err := parseSince(args.Since)
			if err != nil {
				return errResult(fmt.Sprintf("invalid since %q: use YYYY-MM-DD or RFC3339", args.Since)), nil, nil
			}
			fromUnix = float64(ts.Unix())
		}
		digests, err := database.GetDigests(db.DigestFilter{
			Type:      args.Type,
			ChannelID: args.Channel,
			FromUnix:  fromUnix,
			Limit:     listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing digests: " + err.Error()), nil, nil
		}
		return jsonListResult(digests)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_digest",
		Description: "Get a single digest by id, including its full summary.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getDigestArgs) (*mcpsdk.CallToolResult, any, error) {
		digest, err := database.GetDigestByID(args.ID)
		if err != nil {
			return errResult("getting digest: " + err.Error()), nil, nil
		}
		if digest == nil {
			return errResult("no digest with id " + itoa(args.ID)), nil, nil
		}
		return jsonResult(digest)
	})
}
