package cmd

import (
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
)

// automationsTokenWindow is the "7-day tokens" window of `automations list`.
const automationsTokenWindow = 7 * 24 * time.Hour

// automationListItem is one row of `automations list --json`.
type automationListItem struct {
	ID                int64      `json:"id"`
	Slug              string     `json:"slug"`
	Scope             string     `json:"scope"`
	ProjectID         int64      `json:"project_id"`
	Name              string     `json:"name"`
	TriggerKind       string     `json:"trigger_kind"`
	TriggerSpec       string     `json:"trigger_spec"`
	Enabled           bool       `json:"enabled"`
	Runnable          bool       `json:"runnable"`
	NeedsConfirmation bool       `json:"needs_confirmation"`
	ParseError        string     `json:"parse_error"`
	NextRunAt         *time.Time `json:"next_run_at"`
	LastStatus        string     `json:"last_status"`
	Tokens7d          int64      `json:"tokens_7d"`
}

func runAutomationsList(cmd *cobra.Command, _ []string) error {
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	filter := db.AutomationFilter{}
	if autoFlags.Workbench != 0 {
		scope, _, err := workbenchScope(database, autoFlags.Workbench)
		if err != nil {
			return err
		}
		filter.Scope, filter.ProjectID = string(scope.Kind), scope.WorkbenchID
	}
	rows, err := database.ListAutomations(filter)
	if err != nil {
		return err
	}
	stats, err := database.AutomationRunStatsSince(time.Now().Add(-automationsTokenWindow))
	if err != nil {
		return err
	}
	items := make([]automationListItem, 0, len(rows))
	for i := range rows {
		a := &rows[i]
		s := stats[a.ID]
		items = append(items, automationListItem{
			ID: a.ID, Slug: a.Slug, Scope: a.Scope, ProjectID: a.ProjectID, Name: a.Name,
			TriggerKind: a.TriggerKind, TriggerSpec: a.TriggerSpec, Enabled: a.Enabled, Runnable: a.Runnable(),
			NeedsConfirmation: automationNeedsConfirmation(a), ParseError: a.ParseError, NextRunAt: a.NextRunAt,
			LastStatus: s.LastStatus, Tokens7d: s.TokensSince,
		})
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, items)
	}
	printAutomationList(w, items)
	return nil
}

// automationListState is the one-word state `automations list` prints.
func automationListState(it automationListItem) string {
	switch {
	case it.ParseError != "":
		return "parse error"
	case it.NeedsConfirmation:
		return "needs your confirmation"
	case !it.Enabled:
		return "disabled"
	}
	return "runnable"
}

func printAutomationList(w io.Writer, items []automationListItem) {
	if len(items) == 0 {
		fmt.Fprintln(w, "No automations.")
		return
	}
	for _, it := range items {
		next := "-"
		if it.NextRunAt != nil {
			next = it.NextRunAt.Local().Format(time.DateTime)
		}
		fmt.Fprintf(w, "#%d %-24s %-9s %-24s next %s, last %s, %d tokens (7 days)\n",
			it.ID, it.Slug, it.TriggerKind, automationListState(it), next, orNone(it.LastStatus), it.Tokens7d)
	}
}

func runAutomationsRuns(cmd *cobra.Command, args []string) error {
	id, err := parseAutomationID("automation id", args[0])
	if err != nil {
		return err
	}
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetAutomation(id); err != nil {
		return err
	}
	limit := autoFlags.Limit
	if limit <= 0 {
		limit = defaultAutomationsListLimit
	}
	runs, err := database.ListAutomationRuns(id, limit)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, runs)
	}
	if len(runs) == 0 {
		fmt.Fprintln(w, "No runs.")
		return nil
	}
	for _, r := range runs {
		fmt.Fprintf(w, "run #%d %-9s %-16s %d tokens queued %s", r.ID, r.Trigger, r.Status,
			r.InputTokens+r.OutputTokens, r.QueuedAt.Local().Format(time.DateTime))
		if r.Error != "" {
			fmt.Fprintf(w, " — %s: %s", r.ErrorKind, r.Error)
		} else if r.Summary != "" {
			fmt.Fprintf(w, " — %s", r.Summary)
		}
		fmt.Fprintln(w)
	}
	return nil
}

func runAutomationsSteps(cmd *cobra.Command, args []string) error {
	runID, err := parseAutomationID("run id", args[0])
	if err != nil {
		return err
	}
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	if _, err := database.GetAutomationRun(runID); err != nil {
		return err
	}
	steps, err := database.ListAutomationRunSteps(runID)
	if err != nil {
		return err
	}
	if autoFlags.JSON {
		return writeJSON(cmd.OutOrStdout(), steps)
	}
	printAutomationSteps(cmd, steps)
	return nil
}

func printAutomationSteps(cmd *cobra.Command, steps []db.AutomationRunStep) {
	w := cmd.OutOrStdout()
	if len(steps) == 0 {
		fmt.Fprintln(w, "No steps.")
		return
	}
	for _, s := range steps {
		fmt.Fprintf(w, "%3d. %s %s [%s]", s.Seq, s.Kind, s.Name, s.Status)
		if s.Error != "" {
			fmt.Fprintf(w, " — %s", s.Error)
		} else if s.ResultSummary != "" {
			fmt.Fprintf(w, " — %s", s.ResultSummary)
		}
		fmt.Fprintln(w)
	}
}

func runAutomationsOutputs(cmd *cobra.Command, _ []string) error {
	_, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	limit := autoFlags.Limit
	if limit <= 0 {
		limit = defaultAutomationsListLimit
	}
	outs, err := database.ListAutomationOutputs(autoFlags.Kind, limit)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, outs)
	}
	if len(outs) == 0 {
		fmt.Fprintln(w, "No outputs.")
		return nil
	}
	for _, o := range outs {
		fmt.Fprintf(w, "#%d [%s] automation %d run %d %s: %s\n", o.ID, o.Kind, o.AutomationID, o.RunID,
			o.CreatedAt.Local().Format(time.DateTime), o.Title)
	}
	return nil
}
