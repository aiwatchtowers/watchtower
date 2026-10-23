package builtin

import (
	"fmt"
	"strconv"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// CostDays is the window the card's Costs covers.
const CostDays = 7

// CardInfo is a built-in's card: the "builtin" block of `automations show
// --json`. Its keys are pinned by testdata/show_morning_brief.json, which the
// Desktop's tests read too; slices are never null.
type CardInfo struct {
	ID              string            `json:"id"`
	Slot            Slot              `json:"slot"`
	Overridden      bool              `json:"overridden"`
	ShippedHash     string            `json:"shipped_hash"`
	BaseHash        string            `json:"base_hash"`
	UpdateAvailable bool              `json:"update_available"`
	ShippedText     string            `json:"shipped_text"`
	DefaultPrompts  map[string]string `json:"default_prompts"`
	When            string            `json:"when"`
	Reads           []string          `json:"reads"`
	Sends           []string          `json:"sends"`
	Parameters      []ParameterValue  `json:"parameters"`
	FeatureIDs      []string          `json:"feature_ids"`
	Enabled         bool              `json:"enabled"`
	RunNow          bool              `json:"run_now"`
	CopyError       string            `json:"copy_error"`
	Costs           Costs             `json:"costs"`
}

// ParameterValue is a card parameter with its current config value.
type ParameterValue struct {
	Key   string    `json:"key"`
	Kind  ParamKind `json:"kind"`
	Label string    `json:"label"`
	Value string    `json:"value"`
}

// Costs is what the built-in cost over the last Days days. Tokens is the
// input plus output tokens of the same runs (the pipelines report tokens but
// no cost, so the card says tokens when no cost was reported).
type Costs struct {
	USD      float64 `json:"usd"`
	Days     int     `json:"days"`
	Reported bool    `json:"reported"`
	Tokens   int64   `json:"tokens"`
}

// Card builds e's card from its row a (nil before its first sync): the
// shipped text and its default prompts for the owner's role, the When
// parameters read from cfg, whether an overridden copy's base is behind the
// shipped text (UpdateAvailable), why the owner's copy in workspaceDir is not
// used (CopyError: not a regular file or not readable at all, read with
// lstat as Sync does, or the row's parse error) and the last CostDays days of
// costs.
func Card(d *db.DB, cfg *config.Config, workspaceDir string, e Entry, a *db.Automation, now time.Time) (CardInfo, error) {
	c := CardInfo{
		ID: e.ID, Slot: e.Slot, ShippedHash: e.ShippedContentHash(), ShippedText: string(e.Recipe),
		DefaultPrompts: map[string]string{}, Reads: nonNil(e.Reads), Sends: nonNil(e.Sends),
		Parameters: []ParameterValue{}, FeatureIDs: nonNil(e.FeatureIDs),
		Enabled: e.Enabled(cfg), RunNow: e.RunNow, Costs: Costs{Days: CostDays},
	}
	if e.When != nil {
		c.When = e.When(cfg)
	}
	role, err := automations.OwnerRole(d)
	if err != nil {
		return c, fmt.Errorf("built-in %s card: %w", e.ID, err)
	}
	for _, p := range e.Prompts {
		if c.DefaultPrompts[p.Name], err = e.DefaultPrompt(p.Name, role); err != nil {
			return c, err
		}
	}
	for _, p := range e.Parameters {
		c.Parameters = append(c.Parameters, ParameterValue{Key: p.Key, Kind: p.Kind, Label: p.Label, Value: paramValue(cfg, p.Key)})
	}
	// A copy that cannot even be lstat'ed (a permission error) is the card's
	// copy_error, not a failed card: the panel still shows the built-in.
	_, note, err := copyState(OwnerCopyPath(workspaceDir, e.ID))
	if err != nil {
		note = err.Error()
	}
	c.CopyError = note
	if a == nil {
		return c, nil
	}
	// A built-in the daemon stopped (AUTO-08) shows off, so the card offers
	// Turn On, which clears the stop.
	c.Enabled = c.Enabled && a.DisabledReason == ""
	c.Overridden, c.BaseHash = a.Overridden, a.BuiltinBaseHash
	if c.CopyError == "" {
		c.CopyError = a.ParseError
	}
	c.UpdateAvailable = a.Overridden && a.BuiltinBaseHash != "" && a.BuiltinBaseHash != c.ShippedHash
	sum, err := d.BuiltinCost(a.ID, e.Pipelines, now.AddDate(0, 0, -CostDays))
	if err != nil {
		return c, err
	}
	c.Costs.USD, c.Costs.Reported, c.Costs.Tokens = sum.USD, sum.Reported, sum.Tokens
	return c, nil
}

// paramValue is the current value of a card parameter's config key, as
// text ("" for a key the card does not know).
func paramValue(cfg *config.Config, key string) string {
	if cfg == nil {
		return ""
	}
	switch key {
	case "briefing.hour":
		return strconv.Itoa(cfg.Briefing.Hour)
	case "day_plan.working_hours_start":
		return cfg.DayPlan.WorkingHoursStart
	case "day_plan.working_hours_end":
		return cfg.DayPlan.WorkingHoursEnd
	case "day_plan.max_timeblocks":
		return strconv.Itoa(cfg.DayPlan.MaxTimeblocks)
	case "day_plan.min_backlog":
		return strconv.Itoa(cfg.DayPlan.MinBacklog)
	case "day_plan.max_backlog":
		return strconv.Itoa(cfg.DayPlan.MaxBacklog)
	case "ideas.mine_interval_hours":
		return strconv.Itoa(ideasIntervalHours(cfg))
	case "reaction_command_map":
		return "[]" // a dictionary: the Desktop reads the table
	}
	return ""
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
