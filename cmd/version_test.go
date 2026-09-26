package cmd

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestVersionCommand(t *testing.T) {
	buf := new(bytes.Buffer)
	versionCmd.SetOut(buf)

	err := versionCmd.RunE(versionCmd, nil)
	assert.NoError(t, err)

	output := buf.String()
	assert.Contains(t, output, "watchtower")
	assert.Contains(t, output, "commit:")
	assert.Contains(t, output, "built:")
}

func TestVersionVariablesExist(t *testing.T) {
	assert.NotEmpty(t, Version)
	assert.NotEmpty(t, Commit)
	assert.NotEmpty(t, BuildDate)
}

func TestVersionFlavorEmptyIsByteIdentical(t *testing.T) {
	orig := BuildFlavor
	t.Cleanup(func() { BuildFlavor = orig })
	BuildFlavor = ""

	buf := new(bytes.Buffer)
	versionCmd.SetOut(buf)
	assert.NoError(t, versionCmd.RunE(versionCmd, nil))

	want := fmt.Sprintf("watchtower %s (commit: %s, built: %s)\n", Version, Commit, BuildDate)
	assert.Equal(t, want, buf.String())
}

func TestVersionFlavorRendered(t *testing.T) {
	orig := BuildFlavor
	t.Cleanup(func() { BuildFlavor = orig })
	BuildFlavor = "b2"

	buf := new(bytes.Buffer)
	versionCmd.SetOut(buf)
	assert.NoError(t, versionCmd.RunE(versionCmd, nil))

	assert.Contains(t, buf.String(), ", flavor: b2)")
}
