package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"watchtower/internal/codeindex"
)

// exitCodeError makes Execute exit with code instead of 1.
type exitCodeError struct {
	code int
	err  error
}

func (e *exitCodeError) Error() string { return e.err.Error() }
func (e *exitCodeError) Unwrap() error { return e.err }

// usageError is exit 2: a bad invocation or an unreadable folder.
func usageError(format string, args ...any) error {
	return &exitCodeError{code: 2, err: fmt.Errorf(format, args...)}
}

var codeCmd = &cobra.Command{
	Use:   "code",
	Short: "Code navigation for a workbench folder (symbol index, text search)",
	// No config or database: the Desktop runs these per workbench.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
}

var codeIndexCmd = &cobra.Command{
	Use:   "index --folder DIR (--json [--files PATH...] | --serve)",
	Short: "Stream a folder's symbols as JSON lines",
	Long: `Index the symbols of a workbench folder and stream them as JSON lines:
{"file","lang","symbols":[…]} per file ("lang":"" for a file this build cannot
index, {"file","deleted":true} for a --files path that is gone), then
{"done":true,"files":N,"symbols":M,"ms":T}.

--files indexes only the paths given as arguments (relative to the folder); a
path the full run would not list (.gitignore'd, binary, over 2 MB, outside the
folder) comes back with "lang":"", no symbols and "skipped":true. Each result echoes its path
exactly as given.
--serve stays up: each stdin line is one run over its tab-separated paths,
answered with that run's lines and a done line; EOF exits 0.

--rules names the owner's regex language rules (default
~/Library/Application Support/Watchtower/code-languages.yaml; a missing default
file is no rules, a missing --rules file exit 2). A file that cannot be used is ignored as a whole: its error is
printed once on stderr and carried by every done line as "rules_error".

SIGTERM/SIGINT stop a run at once: exit 0, no done line. Exit 2 for a usage
error or an unreadable folder.`,
	RunE: runCodeIndex,
}

var (
	flagCodeFolder string
	flagCodeFiles  bool
	flagCodeServe  bool
	flagCodeJSON   bool
	flagCodeRules  string
)

func init() {
	codeIndexCmd.Flags().StringVar(&flagCodeFolder, "folder", "", "the workbench folder")
	codeIndexCmd.Flags().BoolVar(&flagCodeFiles, "files", false, "index only the paths given as arguments")
	codeIndexCmd.Flags().BoolVar(&flagCodeServe, "serve", false, "read path batches from stdin, one run per line")
	codeIndexCmd.Flags().BoolVar(&flagCodeJSON, "json", false, "JSON lines output (the only format)")
	codeIndexCmd.Flags().StringVar(&flagCodeRules, "rules", "", "the regex language rules file (default: code-languages.yaml in the app's Application Support)")
	codeCmd.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		return &exitCodeError{code: 2, err: err}
	})
	codeCmd.AddCommand(codeIndexCmd)
	rootCmd.AddCommand(codeCmd)
}

// codeIndexOptions is one invocation of `code index`.
type codeIndexOptions struct {
	folder string
	// paths nil = the whole folder.
	paths []string
	serve bool
	// rules and rulesErr are the loaded rules file (nil, nil: none).
	rules    *codeindex.Rules
	rulesErr error
}

func runCodeIndex(cmd *cobra.Command, args []string) error {
	o, err := codeIndexArgs(args)
	if err != nil {
		return err
	}
	// The folder first: a usage error is not preceded by a rules note.
	if err := checkFolder(o.folder); err != nil {
		return err
	}
	if o.rules, o.rulesErr, err = loadCodeRules(flagCodeRules, cmd.ErrOrStderr()); err != nil {
		return err
	}
	ctx, cancel := notifyShutdownContext(cmd.Context(), silentShutdownLogf)
	defer cancel()
	return codeIndex(ctx, o, cmd.InOrStdin(), cmd.OutOrStdout())
}

// codeIndexArgs checks the flags and arguments of `code index`.
func codeIndexArgs(args []string) (codeIndexOptions, error) {
	o := codeIndexOptions{folder: flagCodeFolder, serve: flagCodeServe}
	switch {
	case o.folder == "":
		return o, usageError("--folder is required")
	case o.serve && (flagCodeFiles || len(args) > 0):
		return o, usageError("--serve reads its paths from stdin; it takes no --files")
	case !o.serve && !flagCodeJSON:
		return o, usageError("JSON lines are the only output: pass --json (or --serve)")
	case flagCodeFiles && len(args) == 0:
		return o, usageError("--files needs at least one path")
	case !flagCodeFiles && len(args) > 0:
		return o, usageError("unexpected arguments %q (paths need --files)", args)
	case flagCodeFiles:
		o.paths = args
	}
	return o, nil
}

// loadCodeRules loads the rules file: the --rules flag's when given (one
// that does not exist is a usage error), else the Desktop's Application
// Support copy (missing, or no home directory: no rules). rulesErr is why
// a file was ignored, noted once on stderr.
func loadCodeRules(flag string, stderr io.Writer) (rules *codeindex.Rules, rulesErr, err error) {
	path := flag
	if path == "" {
		if path = defaultRulesPath(); path == "" {
			return nil, nil, nil
		}
	} else if _, serr := os.Stat(path); errors.Is(serr, fs.ErrNotExist) {
		return nil, nil, usageError("--rules %s: no such file", path)
	}
	rules, rulesErr = codeindex.LoadRules(path)
	if rulesErr != nil {
		fmt.Fprintf(stderr, "code index: rules file ignored: %v\n", rulesErr)
	}
	return rules, rulesErr, nil
}

// defaultRulesPath is the Desktop's Application Support copy of the rules
// file; "" (no rules) without a home directory to find it in.
func defaultRulesPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Watchtower", "code-languages.yaml")
}

// codeIndex runs the index over a folder checkFolder accepted. A signal (ctx cancelled) returns nil at once —
// exit 0 with no done line — without waiting for the run in progress or a
// blocked stdin read: the process is about to exit.
func codeIndex(ctx context.Context, o codeIndexOptions, stdin io.Reader, stdout io.Writer) error {
	opts := codeindex.Options{Workers: codeindex.DefaultWorkers(), Rules: o.rules, RulesErr: o.rulesErr}
	errc := make(chan error, 1)
	go func() {
		if o.serve {
			errc <- codeindex.Serve(ctx, o.folder, opts, stdin, stdout)
			return
		}
		errc <- codeindex.Stream(ctx, o.folder, o.paths, opts, stdout)
	}()
	select {
	case err := <-errc:
		if ctx.Err() != nil && errors.Is(err, ctx.Err()) {
			return nil
		}
		return err
	case <-ctx.Done():
		return nil
	}
}

// checkFolder is exit 2 for a folder that is missing, not a directory or
// unreadable.
func checkFolder(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return usageError("reading folder: %w", err)
	}
	defer f.Close()
	if _, err := f.Readdirnames(1); err != nil && !errors.Is(err, io.EOF) {
		return usageError("reading folder %s: %w", dir, err)
	}
	return nil
}
