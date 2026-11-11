package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
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

// Seams for tests: the budgets, the database opener (given the busy
// timeout), the sysctl reader and the pid-file peek.
var (
	diagnosticsBudgets = diagnostics.DefaultBudgets
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

// dbFuture is the database read running beside the report's stages. Its
// one result reaches the slots and the JSON `sources` only through done.
type dbFuture struct {
	done  chan struct{}
	parts diagnostics.DBParts
}

// startDBRead starts diagnostics.ReadDB under the parent ctx: ReadDB starts
// its own database deadline before the open and stops waiting at the
// fallback, so the read never runs past Budgets.DBFallback.
func startDBRead(ctx context.Context, b diagnostics.Budgets, path string) *dbFuture {
	f := &dbFuture{done: make(chan struct{})}
	open := diagnosticsOpener(b.Busy)
	go func() {
		defer close(f.done)
		f.parts = diagnostics.ReadDB(ctx, b, path, open)
	}()
	return f
}

// wait returns the database parts, or false when the report stopped first.
func (f *dbFuture) wait(ctx context.Context) (diagnostics.DBParts, bool) {
	select {
	case <-f.done:
		return f.parts, true
	case <-ctx.Done():
		return diagnostics.DBParts{}, false
	}
}

// ready returns the parts when the read has finished, without waiting.
func (f *dbFuture) ready() (diagnostics.DBParts, bool) {
	select {
	case <-f.done:
		return f.parts, true
	default:
		return diagnostics.DBParts{}, false
	}
}

// dbReason is the slot reason of the database parts (busy, or none).
func dbReason(p diagnostics.DBParts) string {
	if len(p.Reasons) > 0 {
		return p.Reasons[0]
	}
	return ""
}

// constPart is a part whose value was computed before the stages ran.
func constPart(text string) diagnostics.Part {
	return func(context.Context) (string, string) { return text, "" }
}

// collectDiagnostics resolves the config and workspace, then runs the
// report's stages under the hard stop: the values computed up front
// (version, machine, config, workspace, AI — the JSON needs them), the
// database parts (read beside the stages, see startDBRead), the local file
// parts, then the crash scan under its own budget. Stage order is also the
// order of the parts sharing a line (Sources: kinds · iPhone; Database:
// schema · size · policy). Nothing here writes a file.
func collectDiagnostics(ctx context.Context, env diagnostics.Env) diagnostics.Report {
	b := diagnosticsBudgets
	res := diagnostics.Resolve(env)
	versionText, flavor := diagnostics.VersionLine(diagnostics.Build{
		Version: Version, Commit: Commit, Flavor: BuildFlavor, AppVersion: diagnosticsFlagAppVersion,
	})
	machineText, macos, chip := diagnostics.MachineLine(diagnosticsSysctl)
	aiText, provider := diagnostics.AILine(env, res)
	iphone := diagnostics.IPhonePart(diagnosticsFlagIPhone)

	upfront := []diagnostics.Slot{
		{Line: diagLineVersion, Part: constPart(versionText)},
		{Line: diagLineMachine, Part: constPart(machineText)},
		{Line: diagLineConfig, Label: diagnostics.LabelConfig, Part: constPart(res.ConfigLine)},
		{Line: diagLineAI, Label: diagnostics.LabelAI, Part: constPart(aiText)},
	}
	if res.WorkspaceLine != "" {
		upfront = append(upfront, diagnostics.Slot{
			Line: diagLineWorkspace, Label: diagnostics.LabelWorkspace, Part: constPart(res.WorkspaceLine),
		})
	}

	var (
		dir, dbPath string
		future      *dbFuture
	)
	if res.Workspace != "" {
		dir = filepath.Join(res.Root, res.Workspace)
		dbPath = filepath.Join(dir, "watchtower.db")
		future = startDBRead(ctx, b, dbPath)
	}
	stages := []diagnostics.Stage{
		{Name: "upfront", Parts: upfront},
		{Name: "database", Parts: diagDatabaseSlots(future, dir, res.WorkspaceReason)},
		{Name: "local", Parts: diagLocalSlots(res, env, dir, dbPath, iphone)},
		{Name: "crash", Parts: []diagnostics.Slot{diagCrashSlot(b, dir, res.WorkspaceReason)}},
	}
	r := diagnostics.Run(ctx, b, stages)
	r.Version, r.MacOS, r.Chip, r.Provider, r.Flavor = Version, macos, chip, provider, flavor
	if future != nil {
		if p, ok := future.ready(); ok {
			r.Sources = append(r.Sources, p.Kinds...)
		}
	}
	if diagnosticsFlagIPhone == diagnostics.OptionOn {
		r.Sources = append(r.Sources, diagnostics.IPhoneCompanion)
	}
	return r
}

// diagDatabaseSlots are the database parts: the Sources kinds with Quick
// Connections, the Recent errors block (pipeline runs, then the sync row
// from last_sync.json) and the schema. Without a workspace each says why.
func diagDatabaseSlots(future *dbFuture, dir, reason string) []diagnostics.Slot {
	if future == nil {
		return []diagnostics.Slot{
			{Line: diagLineSources, Label: diagnostics.LabelSources, Part: constPart(reason)},
			{Line: diagLineRecentErrors, Part: constPart(diagnostics.RecentErrors(diagnostics.PipelineRunsUnknown(reason)))},
			{Line: diagLineDatabase, Label: diagnostics.LabelDatabase, Part: constPart(diagnostics.SchemaUnknownBecause(reason))},
		}
	}
	part := func(pick func(diagnostics.DBParts) string) diagnostics.Part {
		return func(ctx context.Context) (string, string) {
			p, ok := future.wait(ctx)
			if !ok {
				return diagnostics.UnknownTimedOut, diagnostics.ReasonTimedOut
			}
			return pick(p), dbReason(p)
		}
	}
	lastSync := filepath.Join(dir, "last_sync.json")
	return []diagnostics.Slot{
		{Line: diagLineSources, Label: diagnostics.LabelSources, Part: part(func(p diagnostics.DBParts) string {
			return diagnostics.JoinParts(p.Sources, p.QuickConnections)
		})},
		{Line: diagLineRecentErrors, Part: part(func(p diagnostics.DBParts) string {
			row, _ := diagnostics.SyncRow(lastSync) // "" when there is no row
			return diagnostics.RecentErrors(p.PipelineRuns, row)
		})},
		{Line: diagLineDatabase, Label: diagnostics.LabelDatabase, Part: part(func(p diagnostics.DBParts) string {
			return p.Schema
		})},
	}
}

// diagLocalSlots are the parts read from local files, flags and the policy:
// features, the iPhone part, daemon, logs, the database file size and the
// managed-by-organization part.
func diagLocalSlots(res diagnostics.Resolved, env diagnostics.Env, dir, dbPath, iphone string) []diagnostics.Slot {
	slots := []diagnostics.Slot{
		{Line: diagLineFeatures, Label: diagnostics.LabelFeatures, Part: func(context.Context) (string, string) {
			return diagnostics.FeaturesLine(res, env), ""
		}},
		{Line: diagLineSources, Part: constPart(iphone)},
	}
	if dir == "" {
		slots = append(slots,
			diagnostics.Slot{Line: diagLineDaemon, Label: diagnostics.LabelDaemon, Part: constPart(res.WorkspaceReason)},
			diagnostics.Slot{Line: diagLineLogs, Label: diagnostics.LabelLogs, Part: constPart(res.WorkspaceReason)},
		)
	} else {
		slots = append(slots,
			diagnostics.Slot{Line: diagLineDaemon, Label: diagnostics.LabelDaemon, Part: func(context.Context) (string, string) {
				return diagnostics.DaemonLine(filepath.Join(dir, "daemon.pid"), filepath.Join(dir, "last_sync.json"),
					time.Now(), diagnosticsPeek), ""
			}},
			diagnostics.Slot{Line: diagLineLogs, Label: diagnostics.LabelLogs, Part: func(context.Context) (string, string) {
				return diagnostics.LogsLine(dir), ""
			}},
			diagnostics.Slot{Line: diagLineDatabase, Part: func(context.Context) (string, string) {
				st, err := os.Stat(dbPath)
				if err != nil {
					return "", "" // missing or unreadable: the size is left out
				}
				return diagnostics.Size(st.Size()), ""
			}},
		)
	}
	return append(slots, diagnostics.Slot{Line: diagLineDatabase, Part: func(context.Context) (string, string) {
		return diagnostics.PolicyPart(policy.Current()), ""
	}})
}

// diagCrashSlot scans the workspace's logs under Budgets.LogScan.
func diagCrashSlot(b diagnostics.Budgets, dir, reason string) diagnostics.Slot {
	if dir == "" {
		return diagnostics.Slot{Line: diagLineCrash, Label: diagnostics.LabelCrash, Part: constPart(reason)}
	}
	return diagnostics.Slot{Line: diagLineCrash, Label: diagnostics.LabelCrash, Part: diagnostics.CrashPart(dir, b, time.Now)}
}
