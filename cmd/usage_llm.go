package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// `watchtower usage llm` (spec
// docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md §5): the LLM
// usage ledger plus the workspace spool's not-yet-imported calls, read-only.
var usageLLMCmd = &cobra.Command{
	Use:   "llm",
	Short: "AI calls and their cost: Watchtower, your automations, chats and workbenches",
	Args:  cobra.NoArgs,
	RunE:  runUsageLLM,
}

var (
	flagUsageLLMSince string
	flagUsageLLMJSON  bool
)

// usageLLMBusy bounds a statement's wait for another process's lock.
const usageLLMBusy = 2 * time.Second

func init() {
	usageLLMCmd.Flags().StringVar(&flagUsageLLMSince, "since", "7d", "period: today, 7d or 30d")
	usageLLMCmd.Flags().BoolVar(&flagUsageLLMJSON, "json", false, "print JSON")
	usageCmd.AddCommand(usageLLMCmd)
}

// usageLLMTotals is the pinned totals shape of every section.
type usageLLMTotals struct {
	Calls            int64    `json:"calls"`
	Errors           int64    `json:"errors"`
	EstimatedCalls   int64    `json:"estimated_calls"`
	NoPriceCalls     int64    `json:"no_price_calls"`
	UntaggedCalls    int64    `json:"untagged_calls"`
	Input            int64    `json:"input"`
	CacheRead        int64    `json:"cache_read"`
	CacheWrite       int64    `json:"cache_write"`
	Output           int64    `json:"output"`
	CostUSD          *float64 `json:"cost_usd"` // null when no call had a cost
	CostIsEstimate   bool     `json:"cost_is_estimate"`
	CostIsLowerBound bool     `json:"cost_is_lower_bound"`
}

// usageLLMSessionTotals is the workbench agent sessions' total: the totals
// shape plus the number of sessions.
type usageLLMSessionTotals struct {
	usageLLMTotals
	Sessions int64 `json:"sessions"`
}

type usageLLMPurposeRow struct {
	Purpose          string   `json:"purpose"`
	Process          *string  `json:"process,omitempty"` // untagged rows only
	Models           []string `json:"models"`
	Calls            int64    `json:"calls"`
	Input            int64    `json:"input"`
	CacheRead        int64    `json:"cache_read"`
	CacheWrite       int64    `json:"cache_write"`
	Output           int64    `json:"output"`
	CostUSD          *float64 `json:"cost_usd"`
	CostIsEstimate   bool     `json:"cost_is_estimate"`
	CostIsLowerBound bool     `json:"cost_is_lower_bound"`
	PerCallTokens    int64    `json:"per_call_tokens"`
}

type usageLLMAutomationRow struct {
	AutomationID     int64    `json:"automation_id"`
	Name             string   `json:"name"`
	Runs             int64    `json:"runs"`
	Calls            int64    `json:"calls"`
	Input            int64    `json:"input"`
	Output           int64    `json:"output"`
	CostUSD          *float64 `json:"cost_usd"`
	CostIsEstimate   bool     `json:"cost_is_estimate"`
	CostIsLowerBound bool     `json:"cost_is_lower_bound"`
}

// usageLLMReport is the pinned --json shape (TestUsageLLM_JSONKeysPinned);
// the Desktop's LLMUsageReport decodes it.
type usageLLMReport struct {
	Chats          usageLLMTotals `json:"chats"`
	LedgerSince    string         `json:"ledger_since"` // RFC 3339, "" while nothing is recorded
	OwnAutomations struct {
		Totals usageLLMTotals          `json:"totals"`
		Rows   []usageLLMAutomationRow `json:"rows"`
	} `json:"own_automations"`
	PageTotal  usageLLMTotals `json:"page_total"` // Watchtower + own automations + chats
	Period     string         `json:"period"`
	Watchtower struct {
		Totals usageLLMTotals       `json:"totals"`
		Rows   []usageLLMPurposeRow `json:"rows"`
	} `json:"watchtower"`
	Workbenches struct {
		Totals       usageLLMTotals        `json:"totals"`
		Sessions     usageLLMSessionTotals `json:"sessions"`
		Helpers      usageLLMTotals        `json:"helpers"`
		AnalyticsOff []string              `json:"analytics_off"`
	} `json:"workbenches"`
}

// usageAcc accumulates calls into a total.
type usageAcc struct {
	calls, errors, estimated, noPrice, untagged int64
	input, cacheRead, cacheWrite, output        int64
	estCost                                     int64 // calls whose cost is their estimate
	cost                                        float64
}

func (a *usageAcc) addGroup(g db.LLMUsageGroup) {
	a.calls += g.Calls
	a.errors += g.Errors
	a.estimated += g.Estimated
	a.noPrice += g.NoPrice
	if g.Purpose == "" {
		a.untagged += g.Calls
	}
	a.input += g.Input
	a.cacheRead += g.CacheRead
	a.cacheWrite += g.CacheWrite
	a.output += g.Output
	a.estCost += g.EstCostCalls
	a.cost += g.CostUSD
}

func (a *usageAcc) add(o usageAcc) {
	a.calls += o.calls
	a.errors += o.errors
	a.estimated += o.estimated
	a.noPrice += o.noPrice
	a.untagged += o.untagged
	a.input += o.input
	a.cacheRead += o.cacheRead
	a.cacheWrite += o.cacheWrite
	a.output += o.output
	a.estCost += o.estCost
	a.cost += o.cost
}

func (a usageAcc) tokens() int64 { return a.input + a.cacheRead + a.cacheWrite + a.output }

// costPtr is the total's cost, nil when no call in it had one.
func (a usageAcc) costPtr() *float64 {
	if a.calls-a.noPrice <= 0 {
		return nil
	}
	v := a.cost
	return &v
}

func (a usageAcc) totals() usageLLMTotals {
	return usageLLMTotals{
		Calls: a.calls, Errors: a.errors, EstimatedCalls: a.estimated, NoPriceCalls: a.noPrice,
		UntaggedCalls: a.untagged, Input: a.input, CacheRead: a.cacheRead, CacheWrite: a.cacheWrite,
		Output: a.output, CostUSD: a.costPtr(), CostIsEstimate: a.estCost > 0, CostIsLowerBound: a.noPrice > 0,
	}
}

// usageLLMSince parses --since: today is local midnight.
func usageLLMSince(period string, now time.Time) (time.Time, error) {
	switch period {
	case "today":
		y, m, d := now.Local().Date()
		return time.Date(y, m, d, 0, 0, 0, 0, time.Local), nil
	case "7d":
		return now.Add(-7 * 24 * time.Hour), nil
	case "30d":
		return now.Add(-30 * 24 * time.Hour), nil
	}
	return time.Time{}, fmt.Errorf("--since must be today, 7d or 30d, not %q", period)
}

func runUsageLLM(cmd *cobra.Command, _ []string) error {
	since, err := usageLLMSince(flagUsageLLMSince, time.Now())
	if err != nil {
		return err
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	rep, err := buildUsageLLMReport(cfg, flagUsageLLMSince, since)
	if err != nil {
		return err
	}
	w := cmd.OutOrStdout()
	if flagUsageLLMJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(rep)
	}
	return printUsageLLM(w, rep)
}

// usageLLMSources is what the report reads: the ledger's groups and run ids,
// the spool's unimported calls, and the workbenches.
type usageLLMSources struct {
	groups      []db.LLMUsageGroup
	runs        map[int64]map[int64]bool // automation id → run ids
	ledgerSince string
	sessions    agentlogdb.Totals
	off         []string
}

// buildUsageLLMReport reads everything without writing: the database opened
// read-only (a missing file or a missing llm_calls table is an empty ledger),
// the workspace spool parsed in place, agentlog.db opened read-only. The
// setup spool is never merged: the daemon's first cycle claims it.
func buildUsageLLMReport(cfg *config.Config, period string, since time.Time) (usageLLMReport, error) {
	src := usageLLMSources{runs: map[int64]map[int64]bool{}}
	spool, err := readUsageSpool(llmusage.SpoolPath(cfg.WorkspaceDir()))
	if err != nil {
		return usageLLMReport{}, err
	}
	database, err := openUsageDB(cfg.DBPath())
	if err != nil {
		return usageLLMReport{}, err
	}
	if database != nil {
		defer database.Close()
		if spool, err = readUsageLedger(database, since, spool, &src); err != nil {
			return usageLLMReport{}, err
		}
		if err := readUsageWorkbenches(database, agentlogdb.PathFor(cfg.DBPath()), since, &src); err != nil {
			return usageLLMReport{}, err
		}
	}
	if err := addSpoolGroups(database, spool, since, &src); err != nil {
		return usageLLMReport{}, err
	}
	return assembleUsageLLMReport(period, src), nil
}

// openUsageDB opens the database read-only; nil when the file is missing.
func openUsageDB(path string) (*db.DB, error) {
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("checking database: %w", err)
	}
	d, err := db.OpenExisting(path, usageLLMBusy)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}
	return d, nil
}

// readUsageSpool returns the spool's calls (the .importing file and the live
// one, which overlap while an import runs) once per call_id, dropping the
// surfaces llm_calls would refuse and the lines without a parsable time.
func readUsageSpool(path string) ([]llmusage.Call, error) {
	calls, err := llmusage.ReadSpool(path)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := calls[:0]
	for _, c := range calls {
		if seen[c.CallID] {
			continue
		}
		seen[c.CallID] = true
		if c.Surface != "watchtower" && c.Surface != "chat" && c.Surface != "workbench" {
			continue
		}
		at, err := time.Parse(time.RFC3339, c.At)
		if err != nil {
			continue
		}
		c.At = at.UTC().Format(time.RFC3339)
		out = append(out, c)
	}
	return out, nil
}

// readUsageLedger fills src from llm_calls and returns the spool calls the
// table does not have yet; a database without the table leaves src empty.
func readUsageLedger(d *db.DB, since time.Time, spool []llmusage.Call, src *usageLLMSources) ([]llmusage.Call, error) {
	ok, err := d.HasTable("llm_calls")
	if err != nil || !ok {
		return spool, err
	}
	ids := make([]string, len(spool))
	for i, c := range spool {
		ids[i] = c.CallID
	}
	// One read snapshot: an import committing between separate reads would
	// count its calls twice or not at all.
	snap, err := d.ReadLLMUsage(context.Background(), since, ids)
	if err != nil {
		return nil, err
	}
	src.groups = snap.Groups
	for aid, runIDs := range snap.Runs {
		for _, rid := range runIDs {
			addUsageRun(src.runs, aid, rid)
		}
	}
	if snap.SinceFound {
		src.ledgerSince = snap.Since.UTC().Format(time.RFC3339)
	}
	fresh := spool[:0]
	for _, c := range spool {
		if !snap.Present[c.CallID] {
			fresh = append(fresh, c)
		}
	}
	return fresh, nil
}

func addUsageRun(runs map[int64]map[int64]bool, aid, rid int64) {
	if runs[aid] == nil {
		runs[aid] = map[int64]bool{}
	}
	runs[aid][rid] = true
}

// readUsageWorkbenches fills the agent sessions of the workbenches with
// agent analytics on and the names of those with it off. A database older
// than agent analytics, or no agentlog.db yet, reads as no sessions.
func readUsageWorkbenches(d *db.DB, agentLogPath string, since time.Time, src *usageLLMSources) error {
	ok, err := d.HasColumns("projects", "agent_analytics")
	if err != nil || !ok {
		return err
	}
	on, off, err := usageWorkbenches(d)
	if err != nil {
		return err
	}
	src.off = off
	if len(on) == 0 {
		return nil
	}
	if _, err := os.Stat(agentLogPath); errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return fmt.Errorf("checking agentlog.db: %w", err)
	}
	al, err := agentlogdb.OpenExisting(agentLogPath, usageLLMBusy)
	if err != nil {
		return fmt.Errorf("opening agentlog.db: %w", err)
	}
	defer al.Close()
	var hasEvents bool
	if err := al.QueryRow(`SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'agent_log_events')`).
		Scan(&hasEvents); err != nil {
		return fmt.Errorf("checking agentlog.db: %w", err)
	}
	if !hasEvents {
		return nil
	}
	src.sessions, err = al.TotalsSince(since, on)
	return err
}

// usageWorkbenches returns the ids of the workbenches with agent analytics
// on and the names of those with it off.
func usageWorkbenches(d *db.DB) (on []int64, off []string, err error) {
	rows, err := d.Query(`SELECT id, name, agent_analytics FROM projects ORDER BY name, id`)
	if err != nil {
		return nil, nil, fmt.Errorf("query workbenches: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var name string
		var analytics bool
		if err := rows.Scan(&id, &name, &analytics); err != nil {
			return nil, nil, fmt.Errorf("scan workbenches: %w", err)
		}
		if analytics {
			on = append(on, id)
		} else {
			off = append(off, name)
		}
	}
	return on, off, rows.Err()
}

// usageAutomation is an automation's name and origin.
type usageAutomation struct{ name, origin string }

// addSpoolGroups adds the spool's calls at or after since to src as
// one-call groups, with the automation names and origins the table rows
// get (a missing automation reads as an owner one named #<id>), and
// ledger_since moves back to the earliest spooled call.
func addSpoolGroups(d *db.DB, spool []llmusage.Call, since time.Time, src *usageLLMSources) error {
	bound := since.UTC().Format(time.RFC3339)
	var inPeriod []llmusage.Call
	var autoIDs []int64
	for _, c := range spool {
		if src.ledgerSince == "" || c.At < src.ledgerSince {
			src.ledgerSince = c.At
		}
		if c.At < bound {
			continue
		}
		inPeriod = append(inPeriod, c)
		if c.AutomationID != nil {
			autoIDs = append(autoIDs, *c.AutomationID)
		}
	}
	autos, err := usageAutomations(d, autoIDs)
	if err != nil {
		return err
	}
	for _, c := range inPeriod {
		g := spoolCallGroup(c)
		if c.AutomationID != nil {
			a := autos[*c.AutomationID]
			g.AutomationName, g.AutomationOrigin = a.name, a.origin
			if c.AutomationRunID != nil {
				addUsageRun(src.runs, *c.AutomationID, *c.AutomationRunID)
			}
		}
		src.groups = append(src.groups, g)
	}
	return nil
}

// usageAutomations reads the names and origins of ids in one query; nil d
// or a database without automations reads as none.
func usageAutomations(d *db.DB, ids []int64) (map[int64]usageAutomation, error) {
	out := map[int64]usageAutomation{}
	if d == nil || len(ids) == 0 {
		return out, nil
	}
	if ok, err := d.HasColumns("automations", "origin"); err != nil || !ok {
		return out, err
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	rows, err := d.Query(`SELECT id, COALESCE(NULLIF(name, ''), slug), origin FROM automations WHERE id IN (?`+
		strings.Repeat(",?", len(ids)-1)+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("query automations: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var a usageAutomation
		if err := rows.Scan(&id, &a.name, &a.origin); err != nil {
			return nil, fmt.Errorf("scan automations: %w", err)
		}
		out[id] = a
	}
	return out, rows.Err()
}

// spoolCallGroup is one spooled call as a group, under the per-call cost
// rule LLMUsageRows applies in SQL (db.LLMCallCost).
func spoolCallGroup(c llmusage.Call) db.LLMUsageGroup {
	g := db.LLMUsageGroup{
		Surface: c.Surface, Purpose: c.Purpose, Model: c.Model, AutomationID: c.AutomationID,
		Calls: 1, Input: c.Input, CacheRead: c.CacheRead, CacheWrite: c.CacheWrite5m + c.CacheWrite1h, Output: c.Output,
	}
	if c.Purpose == "" {
		g.Process = c.Process
	}
	if !c.OK {
		g.Errors = 1
	}
	if c.Estimated {
		g.Estimated = 1
	}
	usd, estimated, known := db.LLMCallCost(c.ReportedCostUSD, c.EstCostUSD)
	g.CostUSD = usd
	if estimated {
		g.EstCostCalls = 1
	}
	if !known {
		g.NoPrice = 1
	}
	return g
}

// usagePurposeAcc is one Watchtower row in the making.
type usagePurposeAcc struct {
	purpose, process string
	acc              usageAcc
	models           map[string]bool
}

type usageAutomationAcc struct {
	id   int64
	name string
	acc  usageAcc
}

// assembleUsageLLMReport sorts the groups into the sections: an owner
// automation's calls (any automation that is not a built-in, a deleted one
// included) are its own, else the surface decides; Watchtower rows are one
// per purpose (untagged ones one per process).
func assembleUsageLLMReport(period string, src usageLLMSources) usageLLMReport {
	var rep usageLLMReport
	rep.Period, rep.LedgerSince = period, src.ledgerSince
	var watchtower, own, chats, helpers usageAcc
	purposes := map[[2]string]*usagePurposeAcc{}
	autos := map[int64]*usageAutomationAcc{}
	for _, g := range src.groups {
		switch {
		case g.AutomationID != nil && g.AutomationOrigin != "builtin":
			own.addGroup(g)
			a := autos[*g.AutomationID]
			if a == nil {
				a = &usageAutomationAcc{id: *g.AutomationID}
				autos[a.id] = a
			}
			if a.name == "" {
				a.name = g.AutomationName
			}
			a.acc.addGroup(g)
		case g.Surface == "chat":
			chats.addGroup(g)
		case g.Surface == "workbench":
			helpers.addGroup(g)
		default:
			watchtower.addGroup(g)
			key := [2]string{g.Purpose, g.Process}
			p := purposes[key]
			if p == nil {
				p = &usagePurposeAcc{purpose: g.Purpose, process: g.Process, models: map[string]bool{}}
				purposes[key] = p
			}
			p.acc.addGroup(g)
			if g.Model != "" {
				p.models[g.Model] = true
			}
		}
	}

	rep.Watchtower.Totals = watchtower.totals()
	rep.Watchtower.Rows = usagePurposeRows(purposes)
	rep.OwnAutomations.Totals = own.totals()
	rep.OwnAutomations.Rows = usageAutomationRows(autos, src.runs)
	rep.Chats = chats.totals()

	page := watchtower
	page.add(own)
	page.add(chats)
	rep.PageTotal = page.totals()

	// Agent analytics prices every call from the table (an estimate); a call
	// whose model has no price adds nothing, so the cost is a lower bound.
	sessions := usageAcc{calls: src.sessions.Calls, noPrice: src.sessions.Unpriced, input: src.sessions.Input,
		cacheRead: src.sessions.CacheRead, cacheWrite: src.sessions.CacheWrite, output: src.sessions.Output,
		cost: src.sessions.CostUSD, estCost: src.sessions.Calls - src.sessions.Unpriced}
	rep.Workbenches.Sessions = usageLLMSessionTotals{usageLLMTotals: sessions.totals(), Sessions: src.sessions.Sessions}
	rep.Workbenches.Helpers = helpers.totals()
	bench := sessions
	bench.add(helpers)
	rep.Workbenches.Totals = bench.totals()
	rep.Workbenches.AnalyticsOff = src.off
	if rep.Workbenches.AnalyticsOff == nil {
		rep.Workbenches.AnalyticsOff = []string{}
	}
	return rep
}

// usagePurposeRows orders the Watchtower rows by cost, then tokens; untagged
// rows last.
func usagePurposeRows(purposes map[[2]string]*usagePurposeAcc) []usageLLMPurposeRow {
	list := make([]*usagePurposeAcc, 0, len(purposes))
	for _, p := range purposes {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool {
		a, b := list[i], list[j]
		if (a.purpose == "") != (b.purpose == "") {
			return b.purpose == ""
		}
		if a.acc.cost != b.acc.cost {
			return a.acc.cost > b.acc.cost
		}
		if a.acc.tokens() != b.acc.tokens() {
			return a.acc.tokens() > b.acc.tokens()
		}
		if a.purpose != b.purpose {
			return a.purpose < b.purpose
		}
		return a.process < b.process
	})
	rows := make([]usageLLMPurposeRow, 0, len(list))
	for _, p := range list {
		models := make([]string, 0, len(p.models))
		for m := range p.models {
			models = append(models, m)
		}
		sort.Strings(models)
		a := p.acc
		var process *string
		if p.purpose == "" {
			process = &p.process
		}
		rows = append(rows, usageLLMPurposeRow{
			Purpose: p.purpose, Process: process, Models: models, Calls: a.calls,
			Input: a.input, CacheRead: a.cacheRead, CacheWrite: a.cacheWrite, Output: a.output,
			CostUSD: a.costPtr(), CostIsEstimate: a.estCost > 0, CostIsLowerBound: a.noPrice > 0,
			PerCallTokens: a.tokens() / max(a.calls, 1),
		})
	}
	return rows
}

// usageAutomationRows orders the owner automations by cost, then name.
func usageAutomationRows(autos map[int64]*usageAutomationAcc, runs map[int64]map[int64]bool) []usageLLMAutomationRow {
	rows := make([]usageLLMAutomationRow, 0, len(autos))
	costs := map[int64]float64{}
	for _, a := range autos {
		name := a.name
		if name == "" {
			name = "#" + strconv.FormatInt(a.id, 10)
		}
		costs[a.id] = a.acc.cost
		rows = append(rows, usageLLMAutomationRow{
			AutomationID: a.id, Name: name, Runs: int64(len(runs[a.id])), Calls: a.acc.calls,
			Input: a.acc.input, Output: a.acc.output, CostUSD: a.acc.costPtr(), CostIsEstimate: a.acc.estCost > 0,
			CostIsLowerBound: a.acc.noPrice > 0,
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if ci, cj := costs[rows[i].AutomationID], costs[rows[j].AutomationID]; ci != cj {
			return ci > cj
		}
		if rows[i].Name != rows[j].Name {
			return rows[i].Name < rows[j].Name
		}
		return rows[i].AutomationID < rows[j].AutomationID
	})
	return rows
}

// usageCostText is a cost as the screen shows it: "—" when unknown, "≥"
// when some call had no price, "≈" when some cost is an estimate.
func usageCostText(usd *float64, estimate, lowerBound bool) string {
	if usd == nil {
		return "—"
	}
	s := fmt.Sprintf("$%.2f", *usd)
	switch {
	case lowerBound:
		return "≥ " + s
	case estimate:
		return "≈ " + s
	}
	return s
}

func usageTotalsLine(t usageLLMTotals) string {
	tokens := t.Input + t.CacheRead + t.CacheWrite + t.Output
	return fmt.Sprintf("%d calls · %d tokens (input %d, cache read %d, cache write %d, output %d) · %s",
		t.Calls, tokens, t.Input, t.CacheRead, t.CacheWrite, t.Output,
		usageCostText(t.CostUSD, t.CostIsEstimate, t.CostIsLowerBound))
}

func printUsageLLM(w io.Writer, rep usageLLMReport) error {
	since := "nothing recorded yet"
	if rep.LedgerSince != "" {
		since = "recording since " + rep.LedgerSince
	}
	fmt.Fprintf(w, "AI usage, period %s (%s)\n", rep.Period, since)
	fmt.Fprintf(w, "Watchtower:        %s\n", usageTotalsLine(rep.Watchtower.Totals))
	if t := rep.Watchtower.Totals; t.EstimatedCalls+t.NoPriceCalls+t.UntaggedCalls > 0 {
		fmt.Fprintf(w, "                   %d with estimated usage · %d without a price · %d untagged\n",
			t.EstimatedCalls, t.NoPriceCalls, t.UntaggedCalls)
	}
	fmt.Fprintf(w, "Your automations:  %s\n", usageTotalsLine(rep.OwnAutomations.Totals))
	fmt.Fprintf(w, "Chats:             %s\n", usageTotalsLine(rep.Chats))
	fmt.Fprintf(w, "Workbenches:       %s (sessions %d, Watchtower helpers %d calls)\n",
		usageTotalsLine(rep.Workbenches.Totals), rep.Workbenches.Sessions.Sessions, rep.Workbenches.Helpers.Calls)
	if len(rep.Workbenches.AnalyticsOff) > 0 {
		fmt.Fprintf(w, "                   agent analytics off, not counted: %s\n", strings.Join(rep.Workbenches.AnalyticsOff, ", "))
	}
	fmt.Fprintf(w, "Total (no workbenches): %s\n", usageTotalsLine(rep.PageTotal))

	if len(rep.Watchtower.Rows) > 0 {
		fmt.Fprintln(w)
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		fmt.Fprintln(tw, "PROCESS\tMODELS\tCALLS\tTOKENS\tOUTPUT\tCOST\tPER CALL")
		for _, r := range rep.Watchtower.Rows {
			name := r.Purpose
			if name == "" {
				name = "untagged"
				if r.Process != nil {
					name += " (" + *r.Process + ")"
				}
			}
			fmt.Fprintf(tw, "%s\t%s\t%d\t%d\t%d\t%s\t%d\n", name, strings.Join(r.Models, ","), r.Calls,
				r.Input+r.CacheRead+r.CacheWrite+r.Output, r.Output,
				usageCostText(r.CostUSD, r.CostIsEstimate, r.CostIsLowerBound), r.PerCallTokens)
		}
		if err := tw.Flush(); err != nil {
			return err
		}
	}
	if len(rep.OwnAutomations.Rows) > 0 {
		fmt.Fprintln(w)
		tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
		fmt.Fprintln(tw, "AUTOMATION\tRUNS\tCALLS\tINPUT\tOUTPUT\tCOST")
		for _, r := range rep.OwnAutomations.Rows {
			fmt.Fprintf(tw, "%s\t%d\t%d\t%d\t%d\t%s\n", r.Name, r.Runs, r.Calls, r.Input, r.Output,
				usageCostText(r.CostUSD, r.CostIsEstimate, r.CostIsLowerBound))
		}
		return tw.Flush()
	}
	return nil
}
