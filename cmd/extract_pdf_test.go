package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestConfluenceExtractPDFTextHelper: the hidden helper command prints the
// parse result the extractor reads, and needs no config.
func TestConfluenceExtractPDFTextHelper(t *testing.T) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"extract-pdf-text", filepath.Join("..", "internal", "extract", "testdata", "sample.pdf")})
	t.Cleanup(func() { rootCmd.SetArgs(nil) })
	require.NoError(t, rootCmd.Execute())

	var res struct {
		OK    bool `json:"ok"`
		Pages []struct {
			Index int    `json:"index"`
			Text  string `json:"text"`
		} `json:"pages"`
	}
	require.NoError(t, json.Unmarshal(out.Bytes(), &res), out.String())
	assert.True(t, res.OK)
	require.Len(t, res.Pages, 1)
	assert.Equal(t, "Quarterly report: revenue grew twelve percent", res.Pages[0].Text)
	assert.True(t, extractPDFTextCmd.Hidden)
}

// TestExtractPDFTextArmsSelfDeadline (carried item a): the helper arms its
// own exit at the parent's timeout plus a margin, so an orphan left by a
// SIGKILLed daemon cannot spin forever; in process the timer is disarmed
// when the command returns.
func TestExtractPDFTextArmsSelfDeadline(t *testing.T) {
	var armed []time.Duration
	stopped := 0
	orig := armPDFHelperDeadline
	armPDFHelperDeadline = func(d time.Duration) func() bool {
		armed = append(armed, d)
		return func() bool { stopped++; return true }
	}
	t.Cleanup(func() { armPDFHelperDeadline = orig })

	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"extract-pdf-text", filepath.Join("..", "internal", "extract", "testdata", "sample.pdf")})
	t.Cleanup(func() { rootCmd.SetArgs(nil) })
	require.NoError(t, rootCmd.Execute())

	assert.Equal(t, []time.Duration{70 * time.Second}, armed)
	assert.Equal(t, 1, stopped, "the in-process timer is disarmed on return")
}

// TestPDFHelperArgvServedByTestBinary (carried item b): in cmd tests
// os.Executable is the test binary, so pdfHelperArgv re-execs it; TestMain
// must serve the parse instead of running the whole suite again.
func TestPDFHelperArgvServedByTestBinary(t *testing.T) {
	if os.Getenv("WATCHTOWER_PDF_HELPER_REEXEC") == "1" {
		t.Skip("inside a re-exec: never recurse")
	}
	argv := append(pdfHelperArgv(), filepath.Join("..", "internal", "extract", "testdata", "sample.pdf"))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...) //nolint:gosec // the test binary itself
	cmd.Env = append(os.Environ(), "WATCHTOWER_PDF_HELPER_REEXEC=1")
	start := time.Now()
	out, err := cmd.Output()
	require.NoError(t, err, string(out))
	var res struct {
		OK bool `json:"ok"`
	}
	require.NoError(t, json.Unmarshal(out, &res), "stdout is the helper's JSON, not test output: %s", out)
	assert.True(t, res.OK)
	assert.Less(t, time.Since(start), 20*time.Second)
}
