package chatengine

import (
	"context"
	"log"

	"watchtower/internal/config"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
)

// routingStatusUnreadable is the catalog's fixed error when the availability
// read fails: the cause's text (a path, a store error) never crosses the
// relay.
const routingStatusUnreadable = "Couldn't read provider availability"

// RoutingProvider is one provider the chat's routing pill offers: its
// display name, its fallback peer and the capabilities the composer and
// the fallback card read (the transport capability table's row).
type RoutingProvider struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	ReservePeer string `json:"reserve_peer,omitempty"`
	Images      bool   `json:"images"`
	PDFs        bool   `json:"pdfs"`
	ReadFolder  bool   `json:"read_folder"`
	ClaudeAI    bool   `json:"claude_ai_tools"`
}

// RoutingCatalog is the chat_list record's optional `routing`: what the
// phone's pill needs beside `models[]` (the Mac reads the same through `ai
// models` and `ai routing-status`).
type RoutingCatalog struct {
	Providers []RoutingProvider       `json:"providers"`        // policy-allowed only (providers.Allowed)
	Status    *providerrouting.Output `json:"status,omitempty"` // the `ai routing-status` DTO, without the command's application fields
	Error     string                  `json:"error,omitempty"`  // fixed copy; never the cause's text
}

// ReadRoutingCatalog reads the providers the policy allows, their pair and
// capability rows, and the routing status over r (stored health only, never
// a check). A failed status read leaves Status nil and sets the fixed Error;
// the providers are listed either way.
func ReadRoutingCatalog(ctx context.Context, cfg *config.Config, r *providerrouting.Router) *RoutingCatalog {
	out := &RoutingCatalog{Providers: []RoutingProvider{}}
	allowed := map[string]bool{}
	for _, p := range providers.All() {
		allowed[p.ID] = providers.Allowed(p.ID) == nil
	}
	for _, p := range providers.All() {
		if !allowed[p.ID] {
			continue
		}
		row := RoutingProvider{ID: p.ID, DisplayName: p.DisplayName, Images: p.Caps.Images, PDFs: p.Caps.PDFs,
			ReadFolder: p.Caps.ReadsFolder(), ClaudeAI: p.Caps.ClaudeAITools}
		if peer := p.Caps.ReservePeer; peer != "" && allowed[peer] && providers.Pairs(p.ID, peer) {
			row.ReservePeer = peer
		}
		out.Providers = append(out.Providers, row)
	}
	status, err := providerrouting.ReadStatus(ctx, cfg, r, false)
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("chatengine: reading the routing status failed (%s)", errClass(err))
		}
		out.Error = routingStatusUnreadable
		return out
	}
	out.Status = &status
	return out
}
