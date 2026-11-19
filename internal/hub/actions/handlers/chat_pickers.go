package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"unicode/utf8"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
)

// The phone composer's pickers (unified chat §6.4): the `@` mention picker
// and the `/` skill picker read the engine and answer in the applied echo's
// result, so nothing is published for them. Both are idempotent reads.

// chatEntitySearch is `chat_entity_search` (params {query, kinds?}): the
// engine's EntitySearch — no kinds is the `@` picker, kinds the named kinds
// in order. Result {hits: [{kind, id, label, detail}]}, at most
// MaxChatEntityHits; an unknown kind or a query over 200 characters is
// invalid_params.
func (h *Handlers) chatEntitySearch(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_entity_search", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		q, ok := stringParam(r, "query")
		if !ok && !isNull(r, "query") {
			return failed(reasonInvalidParams, "query must be a text")
		}
		if utf8.RuneCountInString(q) > MaxChatSearchQuery {
			return failed(reasonInvalidParams, "The search is over 200 characters")
		}
		var kinds []string
		if !isNull(r, "kinds") {
			if err := json.Unmarshal(r.Action.Params["kinds"], &kinds); err != nil {
				return failed(reasonInvalidParams, "kinds must be a list of texts")
			}
		}
		hits, err := c.Engine.EntitySearch(ctx, q, kinds)
		switch {
		case errors.Is(err, chatstore.ErrInvalid):
			return failed(reasonInvalidParams, "kinds names a kind your Mac does not search")
		case err != nil:
			log.Printf("hub chat: an entity search failed (%s)", errClass(err))
			return failed(reasonWriteFailed, chatReadFailedMessage)
		}
		if hits == nil {
			hits = []chatengine.EntityHit{}
		}
		if len(hits) > MaxChatEntityHits {
			hits = hits[:MaxChatEntityHits]
		}
		return applied(map[string]any{"hits": hits})
	})
}

// chatSkillsList is `chat_skills_list` (params {}): the `/` picker's catalog
// (the engine's SkillsList: the workspace's enabled skills). Result
// {skills: [{name, description}]}.
func (h *Handlers) chatSkillsList(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_skills_list", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		list, err := c.Engine.SkillsList(ctx)
		if err != nil {
			log.Printf("hub chat: reading the skills failed (%s)", errClass(err))
			return failed(reasonWriteFailed, chatReadFailedMessage)
		}
		if list == nil {
			list = []chatengine.SkillSummary{}
		}
		return applied(map[string]any{"skills": list})
	})
}
