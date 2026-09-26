package cmd

import (
	"os"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/extract"
)

// extractPDFTextCmd is the out-of-process PDF parser the attachment
// extractor runs (extract.Extractor.PDFHelper): the PDF library can loop
// forever on a crafted file, and only killing a process can stop that.
// Internal plumbing, hidden from help; it needs no config or database.
var extractPDFTextCmd = &cobra.Command{
	Use:    "extract-pdf-text <path>",
	Short:  "Parse one PDF's text layer (internal helper)",
	Hidden: true,
	Args:   cobra.ExactArgs(1),
	// No schema/config work: this runs once per PDF attachment.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	RunE: func(cmd *cobra.Command, args []string) error {
		defer armPDFHelperDeadline(extract.PDFHelperDeadline())()
		return extract.ServePDFHelper(cmd.OutOrStdout(), args[0])
	},
}

// armPDFHelperDeadline makes the helper exit on its own after d: the parent
// kills it at its 60 s timeout, but a parent that was itself SIGKILLed
// leaves the helper orphaned, and a crafted PDF can keep the parse looping
// forever. It returns the timer's Stop, so running the command in process
// (tests) leaves no timer behind. A variable so tests can observe it.
var armPDFHelperDeadline = func(d time.Duration) func() bool {
	return time.AfterFunc(d, func() { os.Exit(2) }).Stop
}

func init() {
	rootCmd.AddCommand(extractPDFTextCmd)
}

// pdfHelperArgv is the PDFHelper argv prefix: this executable's hidden
// extract-pdf-text command.
func pdfHelperArgv() []string {
	exe, err := os.Executable()
	if err != nil {
		exe = os.Args[0]
	}
	return []string{exe, extractPDFTextCmd.Name()}
}
