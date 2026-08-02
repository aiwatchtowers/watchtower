package cmd

import "testing"

func TestGmailCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "gmail" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			for _, want := range []string{"login", "logout", "sync", "status"} {
				if !names[want] {
					t.Errorf("missing subcommand %s", want)
				}
			}
		}
	}
	if !found {
		t.Fatal("gmail command not registered")
	}
}
