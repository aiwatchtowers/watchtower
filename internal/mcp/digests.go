package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listDigestsArgs struct {
	Type    string `json:"type,omitempty" jsonschema:"digest type: channel|daily|weekly"`
	Channel string `json:"channel,omitempty" jsonschema:"channel id to filter by"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getDigestArgs struct {
	ID int `json:"id" jsonschema:"digest id"`
}

func registerDigests(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_today_briefing",
		Description: "Get the most recent daily briefing (your personalized roll-up of what needs attention).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, _ struct{}) (*mcpsdk.CallToolResult, any, error) {
		userID, err := database.GetCurrentUserID()
		if err != nil {
			return errResult("getting current user: " + err.Error()), nil, nil
		}
		briefings, err := database.GetRecentBriefings(userID, 1)
		if err != nil {
			return errResult("getting briefing: " + err.Error()), nil, nil
		}
		if len(briefings) == 0 {
			return jsonResult(nil)
		}
		return jsonResult(briefings[0])
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_digests",
		Description: "List channel/daily/weekly digests (AI summaries of Slack activity), most recent first.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listDigestsArgs) (*mcpsdk.CallToolResult, any, error) {
		limit := args.Limit
		if limit == 0 {
			limit = 20
		}
		digests, err := database.GetDigests(db.DigestFilter{
			Type:      args.Type,
			ChannelID: args.Channel,
			Limit:     limit,
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
