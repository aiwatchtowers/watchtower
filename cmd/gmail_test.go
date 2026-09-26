package cmd

import (
	"strings"
	"testing"
)

func TestGmailCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "gmail" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			for _, want := range []string{"login", "logout", "sync", "status", "purge"} {
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

// TestGmailPurgeRequiresAccount: the purge never operates on an implicit
// account. Omitting --account is an error rather than a silent default to
// account #1 the way the login aliases resolve it — a destructive action must
// name the account it destroys.
func TestGmailPurgeRequiresAccount(t *testing.T) {
	err := gmailPurgeCmd.RunE(gmailPurgeCmd, nil)
	if err == nil {
		t.Fatal("expected an error when --account is omitted")
	}
	if !strings.Contains(err.Error(), "--account") {
		t.Errorf("error %q does not mention --account", err)
	}
}
