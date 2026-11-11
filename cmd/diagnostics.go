package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/daemon"
	"watchtower/internal/db/lockmetrics"
	"watchtower/internal/diagnostics"
	"watchtower/internal/policy"
)

var (
	diagnosticsFlagJSON       bool
	diagnosticsFlagAppVersion string
	diagnosticsFlagIPhone     string
)

// Seams for tests: the budgets, the config/workspace resolution, the
// database read and its opener (given the busy timeout), the sysctl reader
// and the pid-file peek.
var (
	diagnosticsBudgets = diagnostics.DefaultBudgets
	diagnosticsResolve = diagnostics.Resolve
	diagnosticsReadDB  = diagnostics.ReadDB
	diagnosticsOpener  = diagnostics.Opener
	diagnosticsSysctl  = diagnosticsSysctlString
	diagnosticsPeek    = daemon.PeekProcess
)

var diagnosticsCmd = &cobra.Command{
	Use:   "diagnostics",
	Short: "Print a privacy-safe summary for a bug report",
	Long: `Prints the summary Help → Report a Problem… shows: versions, the Mac,
config and AI state, enabled features, connected source kinds and counts,
the daemon, recent error classes, crashes, log sizes and the database schema.

It never prints a name, email, id, path, error text or log line, and writes
nothing: no schema upgrade, no config change, no pid-file cleanup, no temp
sweep; the database is read query_only with no checkpoint on close. Every
input that fails prints "unknown (<reason>)" in its place and the command
exits 0, within about 8 seconds however busy the database is.

--json prints one object with the keys text, version, macos, chip, provider,
sources, flavor and partial as the last stdout line. --app-version and
--iphone on|off are passed by the app.`,
	Args: cobra.NoArgs,
	// Not the root's ensureSchemaFormat: the report never migrates,
	// upgrades or rewrites the config.
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	RunE:              runDiagnostics,
}

func init() {
	diagnosticsCmd.Flags().BoolVar(&diagnosticsFlagJSON, "json", false, "print the report as one JSON object")
	diagnosticsCmd.Flags().StringVar(&diagnosticsFlagAppVersion, "app-version", "", "the app's version (passed by the app)")
	diagnosticsCmd.Flags().StringVar(&diagnosticsFlagIPhone, "iphone", "", "iPhone companion state, on|off (passed by the app)")
	rootCmd.AddCommand(diagnosticsCmd)
}

func runDiagnostics(cmd *cobra.Command, _ []string) error {
	// No dblock.jsonl line, not even for an open that waits on a busy
	// database (OpenExistingContext turns the sink off only after its open).
	lockmetrics.Configure("")
	r := collectDiagnostics(cmd.Context(), diagnostics.Env{ConfigPath: flagConfig, WorkspaceFlag: flagWorkspace})
	out := cmd.OutOrStdout()
	if !diagnosticsFlagJSON {
		_, err := fmt.Fprintln(out, r.Text())
		return err
	}
	b, err := r.JSON()
	if err != nil {
		return fmt.Errorf("encoding the report: %w", err)
	}
	_, err = fmt.Fprintln(out, string(b))
	return err
}

// Line positions, in the spec's template order.
const (
	diagLineVersion = iota
	diagLineMachine
	diagLineConfig
	diagLineWorkspace
	diagLineAI
	diagLineFeatures
	diagLineSources
	diagLineDaemon
	diagLineRecentErrors
	diagLineCrash
	diagLineLogs
	diagLineDatabase
)

// Positions of the parts sharing a line (Slot.Pos), whatever stage they ran
// in: `Sources: <kinds> · iPhone companion …`, `Database: schema … · <size>
// · managed by organization: …`.
const (
	diagPosDB = iota
	diagPosSize
	diagPosLocal
)

// recentErrorsStopLabel titles the Recent errors block when the runner
// replaces it (`Recent errors: unknown (timed out)`); its own text carries
// its title.
const recentErrorsStopLabel = "Recent errors: "

// diagSafe runs f and returns fallback when it panics.
func diagSafe[T any](fallback T, f func() T) (out T) {
	defer func() {
		if recover() != nil {
			out = fallback
		}
	}()
	return f()
}

type diagPair struct{ a, b string }

type diagTriple struct{ a, b, c string }

// diagPrep is the up-front work the other lines depend on, run in its own
// goroutine so the report's hard stop covers it too: the version and
// machine values (then early closes), the config and workspace resolution,
// the AI line and the start of the database read (then done closes). Each
// step falls back to `unknown (internal error)` on a panic. Fields are read
// only after their channel closed. stopped closes when the report stopped
// waiting, so a late resolution starts no database read.
type diagPrep struct {
	early, done, stopped chan struct{}
	version              string
	machine, macos, chip string
	res                  diagnostics.Resolved
	resolved             bool // false: Resolve panicked
	ai, provider         string
	dir, dbPath          string
	db                   *dbFuture
}

// diagInputs are the seams, the build info and the flags, read once on the
// command's goroutine: no worker goroutine reads a package variable.
type diagInputs struct {
	budgets diagnostics.Budgets
	build   diagnostics.Build
	iphone  string
	resolve func(diagnostics.Env) diagnostics.Resolved
	readDB  func(context.Context, diagnostics.Budgets, string, diagnostics.OpenFunc) diagnostics.DBParts
	opener  func(time.Duration) diagnostics.OpenFunc
	sysctl  func(string) (string, error)
	peek    func(string) (int, daemon.PeekState, error)
}

func currentDiagInputs() diagInputs {
	return diagInputs{
		budgets: diagnosticsBudgets,
		build: diagnostics.Build{
			Version: Version, Commit: Commit, Flavor: BuildFlavor, AppVersion: diagnosticsFlagAppVersion,
		},
		iphone:  diagnosticsFlagIPhone,
		resolve: diagnosticsResolve,
		readDB:  diagnosticsReadDB,
		opener:  diagnosticsOpener,
		sysctl:  diagnosticsSysctl,
		peek:    diagnosticsPeek,
	}
}

func startDiagPrep(ctx context.Context, in diagInputs, env diagnostics.Env) *diagPrep {
	p := &diagPrep{early: make(chan struct{}), done: make(chan struct{}), stopped: make(chan struct{})}
	go func() {
		defer close(p.done)
		closeEarly := sync.OnceFunc(func() { close(p.early) })
		defer closeEarly()

		version := diagSafe(diagnostics.UnknownInternal, func() string {
			text, _ := diagnostics.VersionLine(in.build) // the JSON flavor is set by collectDiagnostics
			return text
		})
		m := diagSafe(diagTriple{diagnostics.UnknownInternal, "", diagnostics.ChipOther}, func() diagTriple {
			text, macos, chip := diagnostics.MachineLine(in.sysctl)
			return diagTriple{text, macos, chip}
		})
		p.version = version
		p.machine, p.macos, p.chip = m.a, m.b, m.c
		closeEarly()

		p.res = diagSafe(diagnostics.Resolved{
			ConfigLine: diagnostics.UnknownInternal, WorkspaceReason: diagnostics.UnknownInternal,
		}, func() diagnostics.Resolved {
			r := in.resolve(env)
			p.resolved = true
			return r
		})
		p.ai = diagnostics.UnknownInternal
		if p.resolved {
			ai := diagSafe(diagPair{diagnostics.UnknownInternal, ""}, func() diagPair {
				text, provider := diagnostics.AILine(env, p.res)
				return diagPair{text, provider}
			})
			p.ai, p.provider = ai.a, ai.b
		}
		// A resolution that finished after the report stopped reads nothing.
		if p.res.Workspace != "" && ctx.Err() == nil && !isClosed(p.stopped) {
			p.dir = filepath.Join(p.res.Root, p.res.Workspace)
			p.dbPath = filepath.Join(p.dir, "watchtower.db")
			p.db = startDBRead(ctx, in, p.dbPath)
		}
	}()
	return p
}

// after is a part that waits for ch (or the hard stop) and then runs f.
func after(ch chan struct{}, f func() string) diagnostics.Part {
	return func(ctx context.Context) (string, string) {
		if !waitClosed(ctx, ch) {
			return diagnostics.UnknownTimedOut, diagnostics.ReasonTimedOut
		}
		return f(), ""
	}
}

// waitClosed waits for ch to close; false when ctx (the hard stop) ends
// first.
func waitClosed(ctx context.Context, ch chan struct{}) bool {
	select {
	case <-ch:
		return true
	case <-ctx.Done():
		return false
	}
}

// isClosed reports whether ch is closed, without waiting.
func isClosed(ch chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

// dbFuture is the database read running beside the report's stages. Its
// one result reaches the slots and the JSON `sources` only through done.
type dbFuture struct {
	done  chan struct{}
	parts diagnostics.DBParts
}

// startDBRead starts the database read under the parent ctx: ReadDB starts
// its own database deadline before the open and stops waiting at the
// fallback, so the read never runs past Budgets.DBFallback. A panic leaves
// every database part `unknown (internal error)`.
func startDBRead(ctx context.Context, in diagInputs, path string) *dbFuture {
	f := &dbFuture{done: make(chan struct{})}
	go func() {
		defer close(f.done)
		defer func() {
			if recover() != nil {
				f.parts = diagnostics.FailedParts(diagnostics.UnknownInternal)
			}
		}()
		f.parts = in.readDB(ctx, in.budgets, path, in.opener(in.budgets.Busy))
	}()
	return f
}

// dbPart waits for the up-front work and the database read, then picks one
// database part; without a workspace it prints noWS of the reason.
func (p *diagPrep) dbPart(pick func(diagnostics.DBParts) string, noWS func(reason string) string) diagnostics.Part {
	return func(ctx context.Context) (string, string) {
		if !waitClosed(ctx, p.done) {
			return diagnostics.UnknownTimedOut, diagnostics.ReasonTimedOut
		}
		if p.db == nil {
			return noWS(p.res.WorkspaceReason), ""
		}
		if !waitClosed(ctx, p.db.done) {
			return diagnostics.UnknownTimedOut, diagnostics.ReasonTimedOut
		}
		reason := ""
		if len(p.db.parts.Reasons) > 0 {
			reason = p.db.parts.Reasons[0]
		}
		return pick(p.db.parts), reason
	}
}

// wsPart runs f on the workspace folder once the up-front work is done;
// without a workspace it prints why.
func (p *diagPrep) wsPart(f func(dir string) string) diagnostics.Part {
	return after(p.done, func() string {
		if p.dir == "" {
			return p.res.WorkspaceReason
		}
		return f(p.dir)
	})
}

// collectDiagnostics runs the whole report under the hard stop: the
// up-front work in its own goroutine (startDiagPrep), the database read
// beside the stages (startDBRead), and four stages — the iPhone and policy
// parts (instant, so they survive any stop) and the up-front lines, the
// database parts, the local file parts, then the crash scan under its own
// budget. Nothing here writes a file.
func collectDiagnostics(ctx context.Context, env diagnostics.Env) diagnostics.Report {
	in := currentDiagInputs()
	b := in.budgets
	p := startDiagPrep(ctx, in, env)
	defer close(p.stopped)
	iphone := diagnostics.IPhonePart(in.iphone)
	reasonOnly := func(reason string) string { return reason }

	stages := []diagnostics.Stage{
		{Name: "upfront", Parts: []diagnostics.Slot{
			{Line: diagLineSources, Pos: diagPosLocal, Part: func(context.Context) (string, string) { return iphone, "" }},
			{Line: diagLineDatabase, Pos: diagPosLocal, Part: func(context.Context) (string, string) {
				return diagnostics.PolicyPart(policy.Current()), ""
			}},
			{Line: diagLineVersion, Part: after(p.early, func() string { return p.version })},
			{Line: diagLineMachine, Part: after(p.early, func() string { return p.machine })},
			{Line: diagLineConfig, Label: diagnostics.LabelConfig, Part: after(p.done, func() string { return p.res.ConfigLine })},
			{Line: diagLineWorkspace, Label: diagnostics.LabelWorkspace, Part: after(p.done, func() string { return p.res.WorkspaceLine })},
			{Line: diagLineAI, Label: diagnostics.LabelAI, Part: after(p.done, func() string { return p.ai })},
		}},
		{Name: "database", Parts: []diagnostics.Slot{
			{Line: diagLineSources, Pos: diagPosDB, Label: diagnostics.LabelSources, Part: p.dbPart(func(d diagnostics.DBParts) string {
				return diagnostics.JoinParts(d.Sources, d.QuickConnections)
			}, reasonOnly)},
			{Line: diagLineRecentErrors, StopLabel: recentErrorsStopLabel, Part: p.dbPart(func(d diagnostics.DBParts) string {
				row, _ := diagnostics.SyncRow(filepath.Join(p.dir, "last_sync.json")) // "" when there is no row
				return diagnostics.RecentErrors(d.PipelineRuns, row)
			}, func(reason string) string { return diagnostics.RecentErrors(diagnostics.PipelineRunsUnknown(reason)) })},
			{Line: diagLineDatabase, Pos: diagPosDB, Label: diagnostics.LabelDatabase, Part: p.dbPart(func(d diagnostics.DBParts) string {
				return d.Schema
			}, diagnostics.SchemaUnknownBecause)},
		}},
		{Name: "local", Parts: []diagnostics.Slot{
			{Line: diagLineFeatures, Label: diagnostics.LabelFeatures, Part: after(p.done, func() string {
				if !p.resolved {
					return diagnostics.UnknownInternal
				}
				return diagnostics.FeaturesLine(p.res, env)
			})},
			{Line: diagLineDaemon, Label: diagnostics.LabelDaemon, Part: p.wsPart(func(dir string) string {
				return diagnostics.DaemonLine(filepath.Join(dir, "daemon.pid"), filepath.Join(dir, "last_sync.json"),
					time.Now(), in.peek)
			})},
			{Line: diagLineLogs, Label: diagnostics.LabelLogs, Part: p.wsPart(diagnostics.LogsLine)},
			{Line: diagLineDatabase, Pos: diagPosSize, Part: after(p.done, func() string {
				if p.dbPath == "" {
					return "" // the schema part already says why
				}
				st, err := os.Stat(p.dbPath)
				if err != nil {
					return "" // missing or unreadable: the size is left out
				}
				return diagnostics.Size(st.Size())
			})},
		}},
		{Name: "crash", Parts: []diagnostics.Slot{
			{Line: diagLineCrash, Label: diagnostics.LabelCrash, Part: func(ctx context.Context) (string, string) {
				if !waitClosed(ctx, p.done) {
					return diagnostics.UnknownTimedOut, diagnostics.ReasonTimedOut
				}
				if p.dir == "" {
					return p.res.WorkspaceReason, ""
				}
				return diagnostics.CrashPart(p.dir, b, time.Now)(ctx)
			}},
		}},
	}
	r := diagnostics.Run(ctx, b, stages)

	// The JSON values of the up-front work that finished; the defaults
	// (empty, chip Other) for what the hard stop cut off.
	r.Version, r.Flavor, r.Chip = in.build.Version, diagnostics.Flavor(in.build.Flavor), diagnostics.ChipOther
	if isClosed(p.early) {
		r.MacOS, r.Chip = p.macos, p.chip
	}
	if isClosed(p.done) {
		r.Provider = p.provider
		if p.db != nil && isClosed(p.db.done) {
			r.Sources = append(r.Sources, p.db.parts.Kinds...)
		}
	}
	if in.iphone == diagnostics.OptionOn {
		r.Sources = append(r.Sources, diagnostics.IPhoneCompanion)
	}
	return r
}
