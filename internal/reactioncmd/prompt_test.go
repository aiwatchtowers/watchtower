package reactioncmd

import (
	"strings"
	"testing"
)

func TestArgGuide_Wave2Tools(t *testing.T) {
	for _, tool := range []string{"create_track", "create_idea", "remind_me", "brief_context"} {
		g := argGuide(tool)
		if g == "" || g == argGuide("some_unknown_tool") {
			t.Fatalf("%s should have a specific guide, got default/empty", tool)
		}
	}
	if !strings.Contains(argGuide("remind_me"), "remind_at") {
		t.Fatal("remind_me guide must mention remind_at")
	}
	if !strings.Contains(argGuide("brief_context"), "summary") {
		t.Fatal("brief_context guide must mention summary")
	}
}
