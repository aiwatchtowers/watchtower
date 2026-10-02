package cmd

import (
	"fmt"
	"os"
)

// textFlagValue returns --text, or the contents of --text-file when that is
// set — how the Desktop ships pasted free text: off argv, so a large paste
// cannot hit ARG_MAX and meeting content is not readable through `ps`. The
// two flags are registered mutually exclusive.
func textFlagValue(text, textFile string) (string, error) {
	if textFile == "" {
		return text, nil
	}
	raw, err := os.ReadFile(textFile)
	if err != nil {
		return "", fmt.Errorf("reading --text-file: %w", err)
	}
	return string(raw), nil
}
