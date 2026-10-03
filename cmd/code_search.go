package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"watchtower/internal/codesearch"
)

var codeSearchCmd = &cobra.Command{
	Use:   "search --folder DIR --query Q [--word] [--case] [--regex] [--max N] [--context N] [--json]",
	Short: "Search a folder's text, streaming matches as JSON lines",
	Long: `Search the text of a workbench folder and stream the matches as JSON lines:
{"path","line","col","text","text_col","before":[…],"after":[…]} per match
(line and col 1-based, col in UTF-16 units of the line; text cut to 400
characters around the match, text_col the match's 1-based UTF-16 column in
text), then {"done":true,"files":N,"matches":M,"truncated":bool}. "files"
counts the files searched (not those skipped as binary or over 5 MB);
"truncated" says --max stopped the search.

Smart case: case-insensitive unless the query has an upper-case letter; --case
forces sensitive. --word keeps whole identifiers ([A-Za-z0-9_$], so "$x" is one
word). --regex reads the query as a Go regexp, matched within each line.
JSON lines are the only output; --json is accepted for symmetry with "code index".

SIGTERM/SIGINT stop the search at once: exit 0, no done line. Exit 0 for any
search that ran (no matches included); 2 for a usage error, an invalid query or
an unreadable folder.`,
	RunE: runCodeSearch,
}

var (
	flagSearchFolder  string
	flagSearchQuery   string
	flagSearchWord    bool
	flagSearchCase    bool
	flagSearchRegex   bool
	flagSearchMax     int
	flagSearchContext int
	flagSearchJSON    bool
)

func init() {
	f := codeSearchCmd.Flags()
	f.StringVar(&flagSearchFolder, "folder", "", "the workbench folder")
	f.StringVar(&flagSearchQuery, "query", "", "the text (or with --regex, the pattern) to find")
	f.BoolVar(&flagSearchWord, "word", false, "match whole identifiers only")
	f.BoolVar(&flagSearchCase, "case", false, "case-sensitive even for an all-lower-case query")
	f.BoolVar(&flagSearchRegex, "regex", false, "the query is a Go regexp")
	f.IntVar(&flagSearchMax, "max", 2000, "stop after this many matches")
	f.IntVar(&flagSearchContext, "context", 2, "lines of context before and after each match")
	f.BoolVar(&flagSearchJSON, "json", false, "JSON lines output (the only format)")
	codeCmd.AddCommand(codeSearchCmd)
}

// searchDoneLine ends a search's stream (spec §5).
type searchDoneLine struct {
	Done      bool `json:"done"`
	Files     int  `json:"files"`
	Matches   int  `json:"matches"`
	Truncated bool `json:"truncated"`
}

func runCodeSearch(cmd *cobra.Command, args []string) error {
	switch {
	case flagSearchFolder == "":
		return usageError("--folder is required")
	case len(args) > 0:
		return usageError("unexpected arguments %q", args)
	}
	opt := codesearch.Options{
		Query: flagSearchQuery, Word: flagSearchWord, Case: flagSearchCase, Regex: flagSearchRegex,
		Max: flagSearchMax, Context: flagSearchContext,
	}
	ctx, cancel := notifyShutdownContext(cmd.Context(), silentShutdownLogf)
	defer cancel()
	return codeSearch(ctx, flagSearchFolder, opt, cmd.OutOrStdout())
}

// codeSearch runs the search. Each match is one write, so a reader sees it
// as soon as its file is done. A signal (ctx cancelled) returns nil at
// once — exit 0 with no done line — without waiting for the workers: the
// process is about to exit.
func codeSearch(ctx context.Context, folder string, opt codesearch.Options, stdout io.Writer) error {
	if err := checkFolder(folder); err != nil {
		return err
	}
	enc := json.NewEncoder(stdout)
	enc.SetEscapeHTML(false)
	errc := make(chan error, 1)
	go func() {
		sum, err := codesearch.Run(ctx, folder, opt, func(m codesearch.Match) error {
			if err := enc.Encode(m); err != nil {
				return fmt.Errorf("writing a match in %s: %w", m.Path, err)
			}
			return nil
		})
		if err == nil {
			if err = enc.Encode(searchDoneLine{Done: true, Files: sum.Files, Matches: sum.Matches, Truncated: sum.Truncated}); err != nil {
				err = fmt.Errorf("writing the done line: %w", err)
			}
		}
		errc <- err
	}()
	select {
	case err := <-errc:
		switch {
		case errors.Is(err, codesearch.ErrInvalidQuery):
			return &exitCodeError{code: 2, err: err}
		case ctx.Err() != nil && errors.Is(err, ctx.Err()):
			return nil
		}
		return err
	case <-ctx.Done():
		return nil
	}
}
