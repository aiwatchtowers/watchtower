package cmd

import (
	"fmt"
	"io"
	"os"
)

// textFlagValue returns --text, or the contents of --text-file when that is
// set — how the Desktop ships pasted free text: off argv, so a large paste
// cannot hit ARG_MAX and meeting content is not readable through `ps`.
// --text-file - reads in (the command's stdin): the Desktop pipes the text,
// so no temp file holds it (#604 S6). The two flags are registered mutually
// exclusive.
func textFlagValue(in io.Reader, text, textFile string) (string, error) {
	if textFile == "" {
		return text, nil
	}
	raw, err := readFileOrStdin(in, textFile)
	if err != nil {
		return "", fmt.Errorf("reading --text-file: %w", err)
	}
	return string(raw), nil
}

// readFileOrStdin reads path, or in when path is "-": how the Desktop hands a
// command its text without a temp file (#604 S6).
func readFileOrStdin(in io.Reader, path string) ([]byte, error) {
	if path == "-" {
		return io.ReadAll(in)
	}
	return os.ReadFile(path)
}
