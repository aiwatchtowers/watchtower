package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestFeedCommandRegistered(t *testing.T) {
	found := false
	for _, cmd := range rootCmd.Commands() {
		if cmd.Name() == "feed" {
			found = true
			break
		}
	}
	assert.True(t, found, "feed command should be registered")
}

func TestFeedPublishSubcommandRegistered(t *testing.T) {
	found := false
	for _, sub := range feedCmd.Commands() {
		if sub.Name() == "publish" {
			found = true
			break
		}
	}
	assert.True(t, found, "feed publish subcommand should be registered")
}
