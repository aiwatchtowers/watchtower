// Package tuning holds the tools of the tuning chat (spec
// 2026-11-03-tuning-chat-design §4.1–§4.2): Analytics' chat about the owner's
// LLM setup, served on the tools.SurfaceTuning surface. It reads no chat
// table itself; every chat or conversation access goes through internal/db.
package tuning

import (
	"context"
	"time"

	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// ChatPurpose is the llm_calls purpose of every tuning chat turn (`ai query
// --purpose`; owner, ask #1132, spec D53).
const ChatPurpose = "tuning.chat"

// ContextType is chat_conversations.context_type of a tuning chat; its
// context id is the workbench id.
const ContextType = "analytics_tuning"

// Deps are the readers the tuning tools need beyond the database. cmd fills
// them (Task 3.11); tests pass fakes. Deps lives in this file because it
// names coach.Env: COACH-01's scan (TestCOACH01_NoGitWrites) lets only the
// tuning-named files spell the coach seams.
type Deps struct {
	// Store is the prompt store over the executing database.
	Store func(d *db.DB) *prompts.Store
	// AgentReport is `agents report --workbench wb --days days --agent agent
	// --json` (days 0 = the whole retention, agent "" = both agents).
	AgentReport func(ctx context.Context, wb int64, days int, agent string) (any, error)
	// AgentSession is `agents report --workbench wb --session uuid --json`;
	// an unknown session wraps ErrNotFound.
	AgentSession func(ctx context.Context, wb int64, uuid string) (any, error)
	// LLMUsage is `usage llm --since period --json` (today, 7d or 30d).
	LLMUsage func(ctx context.Context, period string) (any, error)
	// Home is the owner's home folder.
	Home func() (string, error)
	Now  func() time.Time
	// CoachEnv is where the coach reads the owner's files: Home, CodexHome
	// and the RepoState seam (cmd fills it over workbenchgit.PathStatus, the
	// read-only `git status`). The skill and instruction reads use it, and
	// the proposal tool passes it to coach.ValidateChatProposal.
	CoachEnv func() coach.Env
}
