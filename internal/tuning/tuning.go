// Package tuning holds the tools of the tuning chat (spec
// 2026-11-03-tuning-chat-design §4.1–§4.2): Analytics' chat about the owner's
// LLM setup, served on the tools.SurfaceTuning surface. It reads no chat
// table itself; every chat or conversation access goes through internal/db.
package tuning

// ChatPurpose is the llm_calls purpose of every tuning chat turn (`ai query
// --purpose`; owner, ask #1132, spec D53).
const ChatPurpose = "tuning.chat"

// ContextType is chat_conversations.context_type of a tuning chat; its
// context id is the workbench id.
const ContextType = "analytics_tuning"
