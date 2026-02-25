//go:build tools

package main

// This file ensures all project dependencies are tracked in go.mod.
// These blank imports are only compiled with the "tools" build tag.
import (
	_ "github.com/anthropics/anthropic-sdk-go"
	_ "github.com/charmbracelet/bubbletea"
	_ "github.com/charmbracelet/glamour"
	_ "github.com/charmbracelet/lipgloss"
	_ "github.com/dustin/go-humanize"
	_ "github.com/slack-go/slack"
	_ "github.com/spf13/cobra"
	_ "github.com/spf13/viper"
	_ "github.com/stretchr/testify"
	_ "golang.org/x/time/rate"
	_ "modernc.org/sqlite"
)
