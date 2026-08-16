package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/features"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	featuresListFlagJSON              bool
	featuresDisableFlagDryRun         bool
	featuresDisableFlagWithDependents bool
	featuresDisableFlagJSON           bool
)

var featuresCmd = &cobra.Command{
	Use:   "features",
	Short: "Manage Watchtower's product-pillar feature toggles",
	// PersistentPreRunE runs the one-time legacy digest-gate migration before
	// any features subcommand. Log-only on error (the daemon's own call site
	// does the same) so a migration hiccup never blocks list/enable/disable.
	PersistentPreRunE: func(_ *cobra.Command, _ []string) error {
		if _, err := config.MigrateFeatureGates(flagConfig); err != nil {
			log.Printf("warning: legacy feature-gate migration failed: %v", err)
		}
		return nil
	},
}

var featuresListCmd = &cobra.Command{
	Use:   "list",
	Short: "List every feature and its current state",
	RunE:  runFeaturesList,
}

var featuresEnableCmd = &cobra.Command{
	Use:   "enable <id>",
	Short: "Enable a feature and fast-forward its watermarks to now",
	Args:  cobra.ExactArgs(1),
	RunE:  runFeaturesEnable,
}

var featuresDisableCmd = &cobra.Command{
	Use:   "disable <id>",
	Short: "Disable a feature, optionally cascading to its dependents",
	Args:  cobra.ExactArgs(1),
	RunE:  runFeaturesDisable,
}

func init() {
	rootCmd.AddCommand(featuresCmd)
	featuresCmd.AddCommand(featuresListCmd)
	featuresCmd.AddCommand(featuresEnableCmd)
	featuresCmd.AddCommand(featuresDisableCmd)

	featuresListCmd.Flags().BoolVar(&featuresListFlagJSON, "json", false, "output as JSON (the Desktop Feature Manager contract)")
	featuresDisableCmd.Flags().BoolVar(&featuresDisableFlagDryRun, "dry-run", false, "preview the currently-enabled dependents without writing anything")
	featuresDisableCmd.Flags().BoolVar(&featuresDisableFlagWithDependents, "with-dependents", false, "also disable every currently-enabled dependent")
	featuresDisableCmd.Flags().BoolVar(&featuresDisableFlagJSON, "json", false, "output as JSON")
}

// featureJSON is the Desktop Feature Manager wire contract ("features list
// --json") — field names are load-bearing, Desktop decodes them verbatim.
type featureJSON struct {
	ID          string          `json:"id"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	State       string          `json:"state"` // enabled | disabled | core
	Core        bool            `json:"core"`
	Parent      string          `json:"parent"`
	ConfigKey   string          `json:"config_key"`
	Cost        string          `json:"cost"`
	FeedsInto   []string        `json:"feeds_into"`
	SubToggles  []subToggleJSON `json:"sub_toggles"`
}

type subToggleJSON struct {
	Key         string `json:"key"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
}

type featuresListJSON struct {
	Features []featureJSON `json:"features"`
}

// featureRefJSON is the minimal id+title a cascade dialog needs to render a
// dependent's name.
type featureRefJSON struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

// disableResultJSON is `disable`'s JSON output. For --dry-run, Dependents is
// every currently-enabled dependent (informational, nothing written yet —
// the input for the Desktop cascade dialog). For a real run, Dependents is
// whatever was actually disabled alongside Feature: empty unless
// --with-dependents was also passed (FEAT-04).
type disableResultJSON struct {
	Feature    string           `json:"feature"`
	Dependents []featureRefJSON `json:"dependents"`
}

func runFeaturesList(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}

	all := features.All()
	out := cmd.OutOrStdout()

	if featuresListFlagJSON {
		list := make([]featureJSON, 0, len(all))
		for _, f := range all {
			list = append(list, toFeatureJSON(f, cfg))
		}
		data, err := json.Marshal(featuresListJSON{Features: list})
		if err != nil {
			return fmt.Errorf("encoding json: %w", err)
		}
		fmt.Fprintln(out, string(data))
		return nil
	}

	fmt.Fprintf(out, "%-20s %-28s %-10s %-8s %-28s\n", "ID", "TITLE", "STATE", "COST", "CONFIG KEY")
	for _, f := range all {
		fmt.Fprintf(out, "%-20s %-28s %-10s %-8s %-28s\n", f.ID, f.Title, featureState(f, cfg), string(f.Cost), f.ConfigKey)
		for _, st := range f.SubToggles {
			state := "disabled"
			if subToggleEnabled(cfg, st.Key) {
				state = "enabled"
			}
			fmt.Fprintf(out, "    - %-40s %-10s %s\n", st.Title, state, st.Key)
		}
	}
	return nil
}

func runFeaturesEnable(cmd *cobra.Command, args []string) error {
	id := args[0]
	f, err := validateToggleableFeature(id)
	if err != nil {
		return err
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	if err := setConfigKey(flagConfig, f.ConfigKey, true); err != nil {
		return fmt.Errorf("enabling %q: %w", id, err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	if err := features.FastForward(id, database, time.Now()); err != nil {
		return fmt.Errorf("fast-forwarding %q: %w", id, err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Enabled %q (%s = true).\n", id, f.ConfigKey)
	fmt.Fprintln(out, "Fast-forwarded any backlog watermarks to now, so it resumes from now instead of catching up on history.")
	return nil
}

func runFeaturesDisable(cmd *cobra.Command, args []string) error {
	id := args[0]
	f, err := validateToggleableFeature(id)
	if err != nil {
		return err
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}

	dependents := features.Dependents(id, cfg)
	out := cmd.OutOrStdout()

	if featuresDisableFlagDryRun {
		return printDisableResult(out, id, dependents, featuresDisableFlagJSON, true)
	}

	if err := setConfigKey(flagConfig, f.ConfigKey, false); err != nil {
		return fmt.Errorf("disabling %q: %w", id, err)
	}

	var disabled []features.Feature
	if featuresDisableFlagWithDependents {
		for _, dep := range dependents {
			if err := setConfigKey(flagConfig, dep.ConfigKey, false); err != nil {
				return fmt.Errorf("disabling dependent %q: %w", dep.ID, err)
			}
		}
		disabled = dependents
	}

	return printDisableResult(out, id, disabled, featuresDisableFlagJSON, false)
}

// printDisableResult renders `disable`'s outcome — see disableResultJSON for
// how dry-run vs. a real run assign different meaning to "deps".
func printDisableResult(out io.Writer, id string, deps []features.Feature, asJSON, dryRun bool) error {
	if asJSON {
		refs := make([]featureRefJSON, 0, len(deps))
		for _, d := range deps {
			refs = append(refs, featureRefJSON{ID: d.ID, Title: d.Title})
		}
		data, err := json.Marshal(disableResultJSON{Feature: id, Dependents: refs})
		if err != nil {
			return fmt.Errorf("encoding json: %w", err)
		}
		fmt.Fprintln(out, string(data))
		return nil
	}

	verb := "Disabled"
	if dryRun {
		verb = "Would disable"
	}
	if len(deps) == 0 {
		fmt.Fprintf(out, "%s %q.\n", verb, id)
		return nil
	}
	fmt.Fprintf(out, "%s %q. Also affects:\n", verb, id)
	for _, d := range deps {
		fmt.Fprintf(out, "  - %s (%s)\n", d.Title, d.ID)
	}
	return nil
}

func toFeatureJSON(f features.Feature, cfg *config.Config) featureJSON {
	subToggles := make([]subToggleJSON, 0, len(f.SubToggles))
	for _, st := range f.SubToggles {
		subToggles = append(subToggles, subToggleJSON{
			Key:         st.Key,
			Title:       st.Title,
			Description: st.Description,
			Enabled:     subToggleEnabled(cfg, st.Key),
		})
	}
	return featureJSON{
		ID:          f.ID,
		Title:       f.Title,
		Description: f.Description,
		State:       featureState(f, cfg),
		Core:        f.Core,
		Parent:      f.Parent,
		ConfigKey:   f.ConfigKey,
		Cost:        string(f.Cost),
		FeedsInto:   append([]string{}, f.FeedsInto...),
		SubToggles:  subToggles,
	}
}

func featureState(f features.Feature, cfg *config.Config) string {
	if f.Core {
		return "core"
	}
	if f.Enabled != nil && f.Enabled(cfg) {
		return "enabled"
	}
	return "disabled"
}

// subToggleEnabled maps a sub-toggle's config key to its live value on a
// loaded config. Memory's 13 keys (internal/features/registry.go's
// memorySubToggles) are the only sub-toggles any registry entry declares
// today.
func subToggleEnabled(cfg *config.Config, key string) bool {
	switch key {
	case "memory.semantic.enabled":
		return cfg.Memory.Semantic.Enabled
	case "memory.sources.gmail":
		return cfg.Memory.Sources.Gmail
	case "memory.sources.actions":
		return cfg.Memory.Sources.Actions
	case "memory.sources.calendar":
		return cfg.Memory.Sources.Calendar
	case "memory.sources.chats":
		return cfg.Memory.Sources.Chats
	case "memory.sources.operational":
		return cfg.Memory.Sources.Operational
	case "memory.sources.jira":
		return cfg.Memory.Sources.Jira
	case "memory.surfaces.chat":
		return cfg.Memory.Surfaces.Chat
	case "memory.surfaces.briefing":
		return cfg.Memory.Surfaces.Briefing
	case "memory.surfaces.disputes":
		return cfg.Memory.Surfaces.Disputes
	case "memory.surfaces.reflection":
		return cfg.Memory.Surfaces.Reflection
	case "memory.surfaces.day_plan":
		return cfg.Memory.Surfaces.DayPlan
	case "memory.surfaces.meeting_prep":
		return cfg.Memory.Surfaces.MeetingPrep
	default:
		return false
	}
}

// validateToggleableFeature resolves id to a non-core registry entry, or
// returns an error listing every toggleable id — core features (dashboard,
// targets, chat, feed) have no CLI toggle by design.
func validateToggleableFeature(id string) (features.Feature, error) {
	f, ok := features.ByID(id)
	if !ok {
		return features.Feature{}, fmt.Errorf("unknown feature %q; valid ids: %s", id, strings.Join(toggleableFeatureIDs(), ", "))
	}
	if f.Core {
		return features.Feature{}, fmt.Errorf("%q is a core feature and cannot be toggled; valid ids: %s", id, strings.Join(toggleableFeatureIDs(), ", "))
	}
	return f, nil
}

func toggleableFeatureIDs() []string {
	all := features.All()
	ids := make([]string, 0, len(all))
	for _, f := range all {
		if !f.Core {
			ids = append(ids, f.ID)
		}
	}
	return ids
}

// setConfigKey is the typed-write core shared by `config set` and the
// features CLI: read the existing yaml, set one key, write it back
// atomically. Requires configPath to already exist (config init / an OAuth
// login flow creates it) — the same constraint runConfigSet has always had.
func setConfigKey(configPath, key string, value any) error {
	v := viper.New()
	v.SetConfigFile(configPath)
	if err := v.ReadInConfig(); err != nil {
		return fmt.Errorf("reading config: %w", err)
	}
	v.Set(key, value)
	return writeConfigAtomic(v, configPath)
}
