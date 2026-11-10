// Package diagnostics builds the privacy-safe summary printed by
// `watchtower diagnostics` (Help → Report a Problem…). See
// docs/superpowers/specs/2026-11-04-report-a-problem-design.md.
package diagnostics

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Every fixed text of the report. Each constant is a plain string literal
// pinned by TestDiagnosticsText_Pinned (testdata/text.golden); the format
// helpers below only fill numbers and already-mapped words into them.
// Nothing here may ever carry a name, id, path or error text (DIAG-01).

// Line labels.
const (
	LabelConfig       = "Config: "
	LabelWorkspace    = "Workspace: "
	LabelAI           = "AI: "
	LabelFeatures     = "Features on: "
	LabelSources      = "Sources: "
	LabelDaemon       = "Daemon: "
	LabelCrash        = "Crash: "
	LabelLogs         = "Logs: "
	LabelDatabase     = "Database: "
	RecentErrorsTitle = "Recent errors (last 20):"
	RecentErrorsNone  = "Recent errors: none"
	RowIndent         = "  "
	PartSep           = " · "
)

// Shared "unknown (<reason>)" parts.
const (
	UnknownNoConfig     = "unknown (no config)"
	UnknownNoWorkspace  = "unknown (no workspace)"
	UnknownNoHome       = "unknown (no home directory)"
	UnknownNoDatabase   = "unknown (no database)"
	UnknownDatabaseBusy = "unknown (database busy)"
	UnknownTimedOut     = "unknown (timed out)"
	UnknownInternal     = "unknown (internal error)"
	UnknownNoLogs       = "unknown (no logs)"
	UnknownWord         = "unknown"
	unknownFmt          = "unknown (%s)"
)

// Version and machine lines.
const (
	versionFmt    = "Watchtower %s (commit %s, flavor: %s)"
	appVersionFmt = "app %s"
	FlavorDefault = "default"
	FlavorCorp    = "corp"
	macOSFmt      = "macOS %s"
	MacOSUnknown  = "macOS unknown"
	ChipOther     = "Other"
)

// Config line.
const (
	ConfigOK                     = "ok"
	ConfigNone                   = "none (not set up)"
	ConfigUnreadableParse        = "unreadable (parse)"
	ConfigUnreadablePermission   = "unreadable (permission)"
	ConfigUnreadableInvalidValue = "unreadable (invalid value)"
	ConfigUnreadableOther        = "unreadable (other)"
)

// Workspace line (printed only when no workspace resolves).
const (
	workspaceNotChosenFmt = "not chosen (%d found)"
	WorkspaceNoneYet      = "none yet"
	WorkspaceInvalidName  = "unknown (invalid name)"
	WorkspaceNotFound     = "unknown (not found)"
	WorkspaceLookupFailed = "unknown (lookup failed)"
)

// AI line and the JSON `provider` form options.
const (
	ProviderClaude            = "Claude Code"
	ProviderCodex             = "Codex"
	ProviderOllama            = "Ollama"
	ProviderOllamaOption      = "Ollama (or another local server)"
	ProviderNotSetUpOption    = "Not set up yet"
	AIDefaultNotChosen        = " (default, not chosen)"
	AIFromEnvironment         = " (from environment)"
	AIUnknownProvider         = "unknown (not a known provider)"
	AINotSetUp                = "not set up (no config)"
	reserveFmt                = "reserve %s, %s"
	ReserveAutomatic          = "automatic"
	ReserveOff                = "off"
	AIReserveInvalid          = "reserve invalid"
	AIProviderSettingsInvalid = "provider settings invalid"
)

// FeaturesNotMigrated ends the Features line of a legacy, unmigrated config.
const FeaturesNotMigrated = " (not yet migrated)"

// Sources line.
const (
	StatusOK           = "ok"
	StatusNeedsSignIn  = "needs sign-in"
	StatusError        = "error"
	StatusPurged       = "purged"
	StatusOff          = "off"
	StatusUnknownState = "unknown state"
	ConfluenceSpaces   = "spaces"
	QuickConnections   = "Quick Connections"
	IPhoneCompanion    = "iPhone companion"
	OptionOn           = "on"
	OptionOff          = "off"
)

// Daemon line.
const (
	DaemonRunning                 = "running"
	DaemonStopped                 = "stopped"
	DaemonStalePIDFile            = "stopped (stale pid file)"
	DaemonNotConfirmed            = "unknown (process not confirmed)"
	DaemonPIDCorrupt              = "unknown (pid file corrupt)"
	DaemonPIDUnreadablePermission = "unknown (pid file unreadable: permission)"
	DaemonPIDUnreadableOther      = "unknown (pid file unreadable: other)"
	lastCycleFmt                  = "last cycle %s ago, %s"
	NoCycleYet                    = "no cycle yet"
	LastCycleUnknown              = "last cycle unknown"
	CycleDone                     = "done"
	CycleError                    = "error"
	CycleRunning                  = "running"
)

// Recent errors block.
const (
	recentErrorRowFmt        = "%s  %s  %s"
	RecentErrorPhasePipeline = "pipeline"
	RecentErrorPhaseSync     = "sync"
	pipelineRunsUnknownFmt   = "pipeline runs %s"
	SyncResultUnknown        = "  sync result unknown"
	TimeLayout               = "2006-01-02 15:04Z"
)

// Crash and Logs lines.
const (
	CrashNone                = "none in the logs"
	crashFoundFmt            = "%d in the logs, last after %s, in %s"
	crashFoundTimeUnknownFmt = "%d in the logs, last time unknown, in %s"
	CrashLocationUnknown     = "location unknown"
	crashScanStoppedFmt      = " (scan stopped after %d MB)"
	crashNoneScanStoppedFmt  = "none in the first %d MB of the logs (scan stopped)"
	LogWatchtower            = "watchtower.log"
	LogDaemon                = "daemon.log"
	LogMissing               = "missing"
	LogUnreadable            = "unreadable"
	LogsNotAttached          = " (not attached)"
)

// Database line and the database open / read failures.
const (
	schemaFmt                    = "schema %d"
	schemaUnknownFmt             = "schema %s"
	SchemaUnknown                = "schema unknown"
	managedFmt                   = "managed by organization: %s"
	ManagedYes                   = "yes"
	ManagedYesWithErrors         = "yes (with errors)"
	ManagedNo                    = "no"
	DatabaseUnreadableNotADB     = "unknown (database unreadable: not a database)"
	DatabaseUnreadableCorrupt    = "unknown (database unreadable: corrupt)"
	DatabaseUnreadablePermission = "unknown (database unreadable: permission)"
	DatabaseUnreadableOther      = "unknown (database unreadable: other)"
	DatabaseNoCkptGuard          = "unknown (database not opened: checkpoint guard unavailable)"
)

// Partial report marker and its reasons, printed in this order.
const (
	PartialPrefix      = "Partial report: "
	ReasonDatabaseBusy = "database busy"
	ReasonLogScan      = "log scan stopped"
	ReasonTimedOut     = "timed out at 8 s"
)

// Unknown returns `unknown (<reason>)` for a reason word, e.g.
// Unknown(ReasonDatabaseBusy) == UnknownDatabaseBusy.
func Unknown(reason string) string { return fmt.Sprintf(unknownFmt, reason) }

// JoinParts joins the non-empty parts of one line with " · ".
func JoinParts(parts ...string) string {
	kept := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, PartSep)
}

// FormatTime prints t in UTC as `yyyy-MM-dd HH:mmZ`.
func FormatTime(t time.Time) string { return t.UTC().Format(TimeLayout) }

// Version is the first line; app is left out when empty (a terminal run).
func Version(version, commit, flavor, app string) string {
	line := fmt.Sprintf(versionFmt, version, commit, flavor)
	if app == "" {
		return line
	}
	return JoinParts(line, fmt.Sprintf(appVersionFmt, app))
}

// MacOS is the `macOS <x.y>` part.
func MacOS(v string) string { return fmt.Sprintf(macOSFmt, v) }

// WorkspaceNotChosen is `not chosen (<n> found)`.
func WorkspaceNotChosen(n int) string { return fmt.Sprintf(workspaceNotChosenFmt, n) }

// Reserve is `reserve <provider>, automatic|off`.
func Reserve(provider, mode string) string { return fmt.Sprintf(reserveFmt, provider, mode) }

// LastCycle is `last cycle <age> ago, done|error|running`.
func LastCycle(age, state string) string { return fmt.Sprintf(lastCycleFmt, age, state) }

// RecentErrorRow is one indented `<time>  <phase>  <class>` row.
func RecentErrorRow(at time.Time, phase, class string) string {
	return RowIndent + fmt.Sprintf(recentErrorRowFmt, FormatTime(at), phase, class)
}

// PipelineRunsUnknown is the indented `pipeline runs unknown (…)` row.
func PipelineRunsUnknown(unknown string) string {
	return RowIndent + fmt.Sprintf(pipelineRunsUnknownFmt, unknown)
}

// Schema is `schema <goose version>`.
func Schema(version int64) string { return fmt.Sprintf(schemaFmt, version) }

// SchemaUnknownBecause is `schema unknown (…)` for an unknown(…) part.
func SchemaUnknownBecause(unknown string) string {
	return fmt.Sprintf(schemaUnknownFmt, unknown)
}

// Managed is `managed by organization: yes|yes (with errors)|no`.
func Managed(v string) string { return fmt.Sprintf(managedFmt, v) }

// CrashFound is `<n> in the logs, last after <time>, in <place>`.
func CrashFound(n int, at, place string) string { return fmt.Sprintf(crashFoundFmt, n, at, place) }

// CrashFoundTimeUnknown is `<n> in the logs, last time unknown, in <place>`.
func CrashFoundTimeUnknown(n int, place string) string {
	return fmt.Sprintf(crashFoundTimeUnknownFmt, n, place)
}

// CrashScanStopped is the ` (scan stopped after <N> MB)` suffix.
func CrashScanStopped(mb int) string { return fmt.Sprintf(crashScanStoppedFmt, mb) }

// CrashNoneScanStopped is `none in the first <N> MB of the logs (scan stopped)`.
func CrashNoneScanStopped(mb int) string { return fmt.Sprintf(crashNoneScanStoppedFmt, mb) }

// ---- Local lines (Task 10): version, machine, daemon, logs, crash, policy,
// iPhone. Kept as one block so parallel line tasks merge cleanly.

// Chip options of the GitHub form, `Apple M1`…`Apple M5`.
const chipAppleFmt = "Apple M%d"

// Ages of the last cycle and file sizes.
const (
	AgeUnderMinute = "under 1 min"
	ageMinutesFmt  = "%d min"
	ageHoursFmt    = "%d h"
	ageDaysFmt     = "%d d"
	sizeFmt        = "%s %s"
	SizeB          = "B"
	SizeKB         = "KB"
	SizeMB         = "MB"
	SizeGB         = "GB"
	logSizeFmt     = "%s %s"
	iPhoneFmt      = "%s %s"
)

// ChipApple is the form's `Apple M<n>` option.
func ChipApple(n int) string { return fmt.Sprintf(chipAppleFmt, n) }

// Age is the `<n> min|h|d` of `last cycle <age> ago`; under a minute (or a
// time in the future, a skewed clock) is `under 1 min`.
func Age(d time.Duration) string {
	switch {
	case d < time.Minute:
		return AgeUnderMinute
	case d < time.Hour:
		return fmt.Sprintf(ageMinutesFmt, int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf(ageHoursFmt, int(d/time.Hour))
	default:
		return fmt.Sprintf(ageDaysFmt, int(d/(24*time.Hour)))
	}
}

// Size prints a byte count as `<n> B|KB|MB|GB` (1024-based): one decimal
// below 10 of a unit (`1.2 GB`, `4 MB` when exact), whole numbers above.
func Size(n int64) string {
	if n < 1024 {
		return fmt.Sprintf(sizeFmt, strconv.FormatInt(max(n, 0), 10), SizeB)
	}
	v, unit := float64(n)/1024, SizeKB
	for _, u := range []string{SizeMB, SizeGB} {
		if v < 1024 {
			break
		}
		v, unit = v/1024, u
	}
	var num string
	if v < 10 {
		num = strings.TrimSuffix(strconv.FormatFloat(v, 'f', 1, 64), ".0")
	} else {
		num = strconv.FormatInt(int64(v), 10)
	}
	return fmt.Sprintf(sizeFmt, num, unit)
}

// LogSize is one `<file> <size|missing|unreadable>` part of the Logs line.
func LogSize(file, size string) string { return fmt.Sprintf(logSizeFmt, file, size) }

// IPhone is the `iPhone companion on|off` part.
func IPhone(state string) string { return fmt.Sprintf(iPhoneFmt, IPhoneCompanion, state) }
