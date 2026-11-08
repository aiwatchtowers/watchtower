package handlers

import (
	"testing"

	"watchtower/internal/agentkind"
)

// A kind that is no agent kind of this version is refused honestly for
// every phone action, never with an empty agent name.
func TestPhoneRefusal_UnknownKindIsAnHonestRefusal(t *testing.T) {
	want := agentkind.Unsupported("gemini").Error()
	for _, kind := range []string{"session_input", "session_finish_request", "permission_answer", "session_interrupt"} {
		msg, refused := PhoneRefusal(kind, "gemini")
		if !refused || msg != want {
			t.Errorf("%s: PhoneRefusal = %q, %v; want %q, true", kind, msg, refused, want)
		}
	}
}
