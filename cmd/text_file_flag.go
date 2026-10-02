package cmd

import (
	"fmt"
	"os"
)

// textFlagValue returns --text, or the contents of --text-file when that is
// set — how the Desktop ships pasted free text: off argv, so a large paste
// cannot hit ARG_MAX and meeting content is not readable through `ps`.
func textFlagValue(text, textFile string) (string, error) {
	if textFile == "" {
		return text, nil
	}
	if text != "" {
		return "", fmt.Errorf("--text and --text-file are mutually exclusive")
	}
	raw, err := os.ReadFile(textFile)
	if err != nil {
		return "", fmt.Errorf("reading --text-file: %w", err)
	}
	return string(raw), nil
}
