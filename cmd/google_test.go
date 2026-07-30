package cmd

import (
	"strings"
	"testing"
)

func TestGoogleCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "google" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			if !names["login"] {
				t.Error("missing subcommand login")
			}
		}
	}
	if !found {
		t.Fatal("google command not registered")
	}
}

func TestGoogleLoginRequiresServiceFlag(t *testing.T) {
	for _, c := range rootCmd.Commands() {
		if c.Name() != "google" {
			continue
		}
		for _, sub := range c.Commands() {
			if sub.Name() != "login" {
				continue
			}
			// Neither --calendar nor --gmail nor --account set → must refuse before any OAuth.
			err := sub.RunE(sub, nil)
			if err == nil {
				t.Fatal("expected error when no service flag is set")
			}
		}
	}
}

func TestGoogleAddRequiresServiceFlag(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() != "google" {
			continue
		}
		for _, sub := range c.Commands() {
			if sub.Name() != "add" {
				continue
			}
			found = true
			// Neither --calendar nor --gmail set → must refuse before any OAuth.
			err := sub.RunE(sub, nil)
			if err == nil {
				t.Fatal("expected error when no service flag is set")
			}
			if !strings.Contains(err.Error(), "--calendar") || !strings.Contains(err.Error(), "--gmail") {
				t.Fatalf("expected error to mention both --calendar and --gmail, got: %v", err)
			}
		}
	}
	if !found {
		t.Fatal("google add command not registered")
	}
}

func TestGoogleAccountsAndRemoveCommandsRegistered(t *testing.T) {
	for _, c := range rootCmd.Commands() {
		if c.Name() != "google" {
			continue
		}
		names := map[string]bool{}
		for _, sub := range c.Commands() {
			names[sub.Name()] = true
		}
		for _, want := range []string{"login", "add", "accounts", "remove"} {
			if !names[want] {
				t.Errorf("missing subcommand %s", want)
			}
		}
	}
}
