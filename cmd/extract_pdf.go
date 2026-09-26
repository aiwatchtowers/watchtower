package cmd

import (
	"os"

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
		return extract.ServePDFHelper(cmd.OutOrStdout(), args[0])
	},
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
