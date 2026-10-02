package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

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
	Short: "Code navigation for a workbench folder (symbol index)",
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

--files indexes only the paths given as arguments (relative to the folder).
--serve stays up: each stdin line is one run over its tab-separated paths,
answered with that run's lines and a done line; EOF exits 0.

SIGTERM/SIGINT stop a run at once: exit 0, no done line. Exit 2 for a usage
error or an unreadable folder.`,
	RunE: runCodeIndex,
}

var (
	flagCodeFolder string
	flagCodeFiles  bool
	flagCodeServe  bool
	flagCodeJSON   bool
)

func init() {
	codeIndexCmd.Flags().StringVar(&flagCodeFolder, "folder", "", "the workbench folder")
	codeIndexCmd.Flags().BoolVar(&flagCodeFiles, "files", false, "index only the paths given as arguments")
	codeIndexCmd.Flags().BoolVar(&flagCodeServe, "serve", false, "read path batches from stdin, one run per line")
	codeIndexCmd.Flags().BoolVar(&flagCodeJSON, "json", false, "JSON lines output (the only format)")
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
}

func runCodeIndex(cmd *cobra.Command, args []string) error {
	o := codeIndexOptions{folder: flagCodeFolder, serve: flagCodeServe}
	switch {
	case o.folder == "":
		return usageError("--folder is required")
	case o.serve && (flagCodeFiles || len(args) > 0):
		return usageError("--serve reads its paths from stdin; it takes no --files")
	case !o.serve && !flagCodeJSON:
		return usageError("JSON lines are the only output: pass --json (or --serve)")
	case flagCodeFiles && len(args) == 0:
		return usageError("--files needs at least one path")
	case !flagCodeFiles && len(args) > 0:
		return usageError("unexpected arguments %q (paths need --files)", args)
	case flagCodeFiles:
		o.paths = args
	}
	ctx, cancel := notifyShutdownContext(cmd.Context(), silentShutdownLogf)
	defer cancel()
	return codeIndex(ctx, o, cmd.InOrStdin(), cmd.OutOrStdout())
}

// codeIndex runs the index. A signal (ctx cancelled) returns nil at once —
// exit 0 with no done line — without waiting for the run in progress or a
// blocked stdin read: the process is about to exit.
func codeIndex(ctx context.Context, o codeIndexOptions, stdin io.Reader, stdout io.Writer) error {
	if err := checkFolder(o.folder); err != nil {
		return err
	}
	workers := codeindex.DefaultWorkers()
	errc := make(chan error, 1)
	go func() {
		if o.serve {
			errc <- codeindex.Serve(ctx, o.folder, workers, stdin, stdout)
			return
		}
		errc <- codeindex.Stream(ctx, o.folder, o.paths, workers, stdout)
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
