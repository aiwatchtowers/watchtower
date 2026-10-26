package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The Desktop pipes the text: --text-file - reads stdin (#604 S6), nothing
// is written to a temp file.
func TestTextFlagValue_Stdin(t *testing.T) {
	got, err := textFlagValue(strings.NewReader("piped -- text\nwith lines"), "", "-")
	require.NoError(t, err)
	assert.Equal(t, "piped -- text\nwith lines", got)
}

func TestTextFlagValue(t *testing.T) {
	file := filepath.Join(t.TempDir(), "paste.txt")
	require.NoError(t, os.WriteFile(file, []byte("pasted -- text\nwith lines"), 0o600))

	got, err := textFlagValue(nil, "", file)
	require.NoError(t, err)
	assert.Equal(t, "pasted -- text\nwith lines", got)

	got, err = textFlagValue(nil, "inline", "")
	require.NoError(t, err)
	assert.Equal(t, "inline", got)

	_, err = textFlagValue(nil, "", filepath.Join(t.TempDir(), "missing.txt"))
	assert.ErrorContains(t, err, "reading --text-file")
}

// The Desktop passes --text-file to each of these; cobra rejects an unknown
// flag before RunE runs, so every one must register it — and refuse it
// together with --text.
func TestTextFileFlagRegisteredOnDesktopCommands(t *testing.T) {
	for _, c := range []*cobra.Command{meetingRecapCmd, meetingExtractTopicsCmd, targetsExtractCmd, tracksCreateCmd} {
		require.NotNil(t, c.Flags().Lookup("text-file"), c.CommandPath())
		assert.Equal(t, []string{"text text-file"},
			c.Flags().Lookup("text-file").Annotations["cobra_annotation_mutually_exclusive"], c.CommandPath())
	}
}

func TestMeetingRecapReadsTextFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "empty.txt")
	require.NoError(t, os.WriteFile(file, nil, 0o600))
	meetingRecapFlagText, meetingRecapFlagTextFile, meetingRecapFlagEventID = "", file, "evt-1"
	t.Cleanup(func() { meetingRecapFlagText, meetingRecapFlagTextFile, meetingRecapFlagEventID = "", "", "" })

	err := runMeetingRecap(meetingRecapCmd, nil)
	assert.ErrorContains(t, err, "--text or --text-file is required", "an empty file is no text")
}
