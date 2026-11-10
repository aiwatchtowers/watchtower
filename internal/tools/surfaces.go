package tools

import "slices"

// SurfaceTuning is the tuning chat (spec 2026-11-03-tuning-chat-design §4.1):
// Analytics' chat about the owner's LLM setup. Its proposal tool files coach
// proposals, so its binding is DirectApply and every change still waits for
// the owner's press on the card.
const SurfaceTuning = "tuning"

// ChatSurfaces are the surfaces a chat's `ai query --tools chat` and `mcp
// --chat` server bind to, in a fixed order pinned by
// testdata/chat_surfaces.txt (Swift's AssistantToolSurface.chatSurfaces reads
// the same file). AutomationSurface is not one: only the automations executor
// binds it.
func ChatSurfaces() []string {
	return []string{"main", "target", AutomationEditorSurface, SurfaceTuning}
}

// KnownChatSurface reports whether s is one of ChatSurfaces.
func KnownChatSurface(s string) bool {
	return slices.Contains(ChatSurfaces(), s)
}
