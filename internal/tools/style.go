package tools

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

type getWritingStyleArgs struct{}

// NewGetWritingStyle returns the owner's communication style profile — what
// the assistant drafts in before proposing a message sent as the owner
// (send_slack_message). Registered beside that tool, never in ReadTools(): it
// serves only the surfaces that can send, and dev-mode MCP stays unchanged.
func NewGetWritingStyle() *Tool {
	return &Tool{
		Name: "get_writing_style",
		Description: "Get how the owner writes — their language, tone for each audience, typical phrases — so a message " +
			"you draft to be sent as them (send_slack_message) sounds like them. Call it before drafting.",
		InputSchema: mustSchema[getWritingStyleArgs]("get_writing_style"),
		Access:      AccessRead,
		Surfaces:    []string{"main", WorkbenchSurface},
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			profile, err := d.GetStyleProfile()
			if err != nil {
				return nil, fmt.Errorf("reading the style profile: %w", err)
			}
			updated, err := d.GetStyleProfileUpdatedAt()
			if err != nil {
				return nil, fmt.Errorf("reading the style profile: %w", err)
			}
			out := map[string]any{"style_profile": profile, "updated_at": updated}
			if strings.TrimSpace(profile) == "" {
				out["note"] = "No style profile yet (the owner can build one with 'watchtower inbox style-sample' or the " +
					"Profile tab). Match the language and tone of the owner's own recent messages in that conversation instead."
			}
			return out, nil
		},
	}
}
