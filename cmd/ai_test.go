package cmd

import (
	"reflect"
	"testing"
)

func TestChatMCPArgs_Shape(t *testing.T) {
	aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "target", 7, "t1", "target", "42"
	t.Cleanup(func() {
		aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "main", 0, "", "", ""
	})
	got := chatMCPArgs()
	want := []string{"--chat", "--surface", "target", "--conversation", "7", "--turn", "t1", "--context-type", "target", "--context-id", "42"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}
