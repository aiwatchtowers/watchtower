package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/automations/watch"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/fsutil"
	"watchtower/internal/prompts"
)

// builtinUpgradeResult is one built-in's move in `automations
// upgrade-builtins --json` (the Desktop decodes exactly these keys): status
// db.BuiltinMigrationDone or db.BuiltinMigrationFailed, error "" when done.
type builtinUpgradeResult struct {
	BuiltinID string `json:"builtin_id"`
	Status    string `json:"status"`
	Error     string `json:"error"`
}

// upgradeBuiltinsJSON is `automations upgrade-builtins --json`.
type upgradeBuiltinsJSON struct {
	Results []builtinUpgradeResult `json:"results"`
}

// rolelessLegacyPrompts are the prompts their legacy pipeline resolved
// without the owner's role: the day plan always asked prompts.Resolve for
// the base id (dayplan.buildPrompt), so a role variant row never ran there.
var rolelessLegacyPrompts = map[string]bool{prompts.DayPlanGenerate: true}

// upgradeBuiltins is the one-time move of every built-in from its old
// pipeline settings (spec 2026-10-22 §5.4), run by the daemon at start after
// the built-ins' sync: active[id] is whether built-in id runs this daemon
// life — false (or no key) keeps its legacy phases. An entry already moved (a done
// record) is skipped; any other is moved now (upgradeBuiltin). The custom
// tracks' move (active[customTracksID], no built-in of its own) follows the
// same rule (upgradeCustomTracks). It runs under agent markers too: it
// carries only prompt text and watch instructions that were already running
// and introduces no code.
func upgradeBuiltins(cfg *config.Config, database *db.DB, now time.Time, logger *log.Logger) map[string]bool {
	active := map[string]bool{}
	for _, e := range builtin.All() {
		rec, err := database.GetBuiltinMigration(e.ID)
		if err != nil {
			logger.Printf("built-in %s: reading its settings move failed, its legacy phases run: %v", e.ID, err)
			active[e.ID] = false
			continue
		}
		if rec != nil && rec.Status == db.BuiltinMigrationDone {
			active[e.ID] = true
			continue
		}
		active[e.ID] = upgradeBuiltin(cfg, database, e, now, logger).Status == db.BuiltinMigrationDone
	}
	active[customTracksID] = upgradeCustomTracksOnce(cfg, database, now, logger)
	return active
}

// upgradeCustomTracksOnce is the custom-track move's half of
// upgradeBuiltins: true when it is done (already, or now). Until then the
// daemon's legacy scan covers the tracks still bound to no recipe.
func upgradeCustomTracksOnce(cfg *config.Config, database *db.DB, now time.Time, logger *log.Logger) bool {
	rec, err := database.GetBuiltinMigration(customTracksID)
	if err != nil {
		logger.Printf("custom tracks: reading their move failed, the legacy scan runs: %v", err)
		return false
	}
	if rec != nil && rec.Status == db.BuiltinMigrationDone {
		return true
	}
	return upgradeCustomTracks(cfg, database, now, logger).Status == db.BuiltinMigrationDone
}

// upgradeBuiltin moves built-in e and records the attempt: done, or failed
// with the error (logged; the legacy phases keep running).
func upgradeBuiltin(cfg *config.Config, database *db.DB, e builtin.Entry, now time.Time, logger *log.Logger) builtinUpgradeResult {
	res := recordUpgrade(database, e.ID, carryCustomPrompts(cfg, database, e, now, logger), now)
	if res.Status == db.BuiltinMigrationFailed {
		logger.Printf("built-in %s: the settings move failed, its legacy phases run: %s", e.ID, res.Error)
	}
	return res
}

// upgradeCustomTracks moves the custom tracks onto watch recipes and
// records the attempt: done, or failed with the first error (logged). The
// tracks bound before a failure stay bound and run as recipes; the daemon's
// legacy scan covers only the unbound rest, and a Retry continues with them.
func upgradeCustomTracks(cfg *config.Config, database *db.DB, now time.Time, logger *log.Logger) builtinUpgradeResult {
	res := recordUpgrade(database, customTracksID, startCustomTrackWatches(cfg, database, now, logger), now)
	if res.Status == db.BuiltinMigrationFailed {
		logger.Printf("custom tracks: the move to watch recipes failed, the legacy scan covers the tracks not moved: %s", res.Error)
	}
	return res
}

// recordUpgrade records one move attempt of id: done when err is nil, else
// failed with err; a failed record write is a failure too.
func recordUpgrade(database *db.DB, id string, err error, now time.Time) builtinUpgradeResult {
	res := builtinUpgradeResult{BuiltinID: id, Status: db.BuiltinMigrationDone}
	if err != nil {
		res.Status, res.Error = db.BuiltinMigrationFailed, err.Error()
	}
	if rerr := database.RecordBuiltinMigration(id, res.Status, res.Error, now); rerr != nil {
		res.Status = db.BuiltinMigrationFailed
		res.Error = errors.Join(err, rerr).Error()
	}
	return res
}

// upgradeWatchStart is watch.Start behind a test seam.
var upgradeWatchStart = watch.Start

// startCustomTrackWatches makes every custom track the move covers a
// confirmed watch recipe (watch.Start with Confirm), in created order: the
// owner's track already scanned with exactly this instruction (AUTO-06: the
// step confirms only what watch.Start renders). Collecting or Paused carries
// over through the track's enabled; its events and link stay.
//
// The move covers the tracks created by its first attempt (the record's
// first_attempted_at, now on the first): a track made afterwards — an
// agent's `tracks create`, a reaction's track — is never confirmed by it.
// Of those it visits the ones bound to no recipe and not dismissed
// (db.ListUnboundCustomTracks) and, on a later attempt, the ones an earlier
// attempt bound but did not confirm (watchesLeftUnconfirmed). A track bound
// before the move, by `tracks start` or an agent's `tracks create`, stays
// the owner's to confirm.
//
// A start that failed after binding its track is tried once more, so the
// confirm gets a second chance. A recipe found edited since it was
// rendered (watch.ErrEditedSinceRendered) is left bound and unconfirmed for
// the owner; the move goes on. The first other error stops the move.
func startCustomTrackWatches(cfg *config.Config, database *db.DB, now time.Time, logger *log.Logger) error {
	rec, err := database.GetBuiltinMigration(customTracksID)
	if err != nil {
		return err
	}
	cutoff := now.UTC().Truncate(time.Second)
	if rec != nil {
		cutoff = rec.FirstAttemptedAt
	}
	list, err := database.ListUnboundCustomTracks()
	if err != nil {
		return err
	}
	if rec != nil {
		left, err := watchesLeftUnconfirmed(database, cutoff)
		if err != nil {
			return err
		}
		list = append(left, list...)
	}
	ix := automations.NewIndexer(database, cfg.WorkspaceDir(), automations.RealClock{})
	start := func(t db.Track) error {
		_, err := upgradeWatchStart(context.Background(), database, ix, cfg.WorkspaceDir(), t, watch.StartOptions{Confirm: true, Now: now})
		return err
	}
	for _, t := range list {
		created, err := time.Parse(time.RFC3339, t.CreatedAt)
		if err != nil {
			return fmt.Errorf("track #%d created_at %q: %w", t.ID, t.CreatedAt, err)
		}
		if created.After(cutoff) {
			continue
		}
		err = start(t)
		if err != nil && !errors.Is(err, watch.ErrEditedSinceRendered) && t.AutomationID == 0 {
			if cur, rerr := database.GetTrackByID(t.ID); rerr == nil && cur.AutomationID != 0 {
				if again := start(*cur); again == nil {
					err = nil
				} else {
					err = errors.Join(err, again)
				}
			}
		}
		if errors.Is(err, watch.ErrEditedSinceRendered) {
			logger.Printf("custom tracks: track #%d's watch recipe was edited since it was made; it is left for you to confirm in Automations", t.ID)
			continue
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// watchesLeftUnconfirmed is the custom tracks, not dismissed, whose watch
// recipe was written at cutoff or later (by an
// attempt of the move) and is not confirmed: a start that bound its track
// and failed before its confirm. watch.Start confirms one only while it is
// still the untouched template.
func watchesLeftUnconfirmed(database *db.DB, cutoff time.Time) ([]db.Track, error) {
	recipes, err := database.ListSlotRecipes(string(builtin.SlotCustomTracks))
	if err != nil {
		return nil, err
	}
	byRecipe, err := database.WatchTrackIDs()
	if err != nil {
		return nil, err
	}
	var out []db.Track
	for _, a := range recipes {
		id, ok := byRecipe[a.ID]
		if !ok || a.Confirmed() || a.CreatedAt.Before(cutoff) {
			continue
		}
		t, err := database.GetTrackByID(id)
		if err != nil {
			return nil, err
		}
		if t.Origin == "custom" && t.DismissedAt == "" {
			out = append(out, *t)
		}
	}
	return out, nil
}

// carryCustomPrompts carries e's customised prompt-store prompts into the
// owner's copy: when any prompt the legacy pipeline ran came from a row the
// owner customised, the copy is RenderOwnerCopy of exactly those prompts
// (the others keep the shipped default), indexed and confirmed — the owner's
// content already running (AUTO-06). On/off needs nothing: the config keys
// stay the truth. A copy already at the path is never overwritten: one with
// exactly the bytes this step renders (a move interrupted after its write)
// is indexed and confirmed, any other is the owner's and is left alone.
func carryCustomPrompts(cfg *config.Config, database *db.DB, e builtin.Entry, now time.Time, logger *log.Logger) error {
	role, err := automations.OwnerRole(database)
	if err != nil {
		return fmt.Errorf("reading the owner's role: %w", err)
	}
	store := prompts.New(database, nil)
	collected := map[string]string{}
	for _, p := range e.Prompts {
		pr := role
		if rolelessLegacyPrompts[p.PromptID] {
			pr = ""
		}
		text, ok, err := customisedLegacyPrompt(store, database, p.PromptID, pr, logger)
		if err != nil {
			return err
		}
		if ok {
			collected[p.Name] = text
		}
	}
	if len(collected) == 0 {
		return nil
	}
	data, err := builtin.RenderOwnerCopy(e, collected)
	if err != nil {
		return err
	}
	path := builtin.OwnerCopyPath(cfg.WorkspaceDir(), e.ID)
	fi, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := writeUpgradeCopy(path, data); err != nil {
			return err
		}
	case err != nil:
		return fmt.Errorf("checking the edited copy %s: %w", path, err)
	case !fi.Mode().IsRegular():
		return fmt.Errorf("%s is not a regular file; remove it so your customised prompt can be carried", path)
	default:
		existing, _, err := automations.ReadRecipeFile(path)
		if err != nil {
			return err
		}
		if !bytes.Equal(existing, data) {
			logger.Printf("built-in %s: an edited copy is already there; it is kept and the prompt store is not carried", e.ID)
			return nil
		}
	}
	row, err := builtin.SyncOne(context.Background(), database, cfg.WorkspaceDir(), cfg, e.ID, now)
	if err != nil {
		return err
	}
	if !row.Overridden || row.ParseError != "" || row.ContentHash != automations.ContentHash(data) {
		return fmt.Errorf("built-in %s: the carried copy was not indexed as written", e.ID)
	}
	if err := database.ConfirmAutomation(row.ID, row.ApprovalHash, now); err != nil {
		return fmt.Errorf("confirming the carried copy: %w", err)
	}
	logger.Printf("built-in %s: your customised prompts were carried into its edited copy %s", e.ID, path)
	return nil
}

// writeUpgradeCopy writes the carried copy atomically under its .builtin
// folder (created 0700; a folder that is a symlink or a file is refused).
func writeUpgradeCopy(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}
	if err := requireBuiltinCopyDir(dir); err != nil {
		return err
	}
	if err := fsutil.WriteFileAtomic(path, data, 0o600); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}

// customisedLegacyPrompt is the template the legacy pipeline resolved for id
// (prompts.Resolve with role, as briefing and day plan do) when it came from
// a row the owner customised: the role variant row when it exists, else the
// base row — a shipped role variant default with no row wins over the base
// row, as in Store.GetForRole. A blank customised template is not carried
// (Resolve ran the shipped default instead), nor one whose %s count is not
// the default's: the brief ran the default in its place, and the day plan
// ran it garbled (only its overrides fall back) — as an override in the
// built-in it would fall back to the default anyway.
func customisedLegacyPrompt(store *prompts.Store, database *db.DB, id, role string, logger *log.Logger) (string, bool, error) {
	var row *db.Prompt
	if role != "" {
		variant := id + "_" + role
		r, err := database.GetPrompt(variant)
		if err != nil {
			return "", false, err
		}
		if r == nil && prompts.Defaults[variant] != "" {
			return "", false, nil
		}
		row = r
	}
	if row == nil {
		r, err := database.GetPrompt(id)
		if err != nil {
			return "", false, err
		}
		row = r
	}
	if row == nil || !row.Customized || strings.TrimSpace(row.Template) == "" {
		return "", false, nil
	}
	tmpl, _, err := prompts.Resolve(store, id, role)
	if err != nil {
		return "", false, err
	}
	if tmpl != row.Template {
		return "", false, fmt.Errorf("prompt %s changed while it was read; try again", row.ID)
	}
	if countPromptVerbs(tmpl) != countPromptVerbs(prompts.Defaults[id]) {
		logger.Printf("prompt %s: its %%s placeholders differ from the default's; it is not carried", row.ID)
		return "", false, nil
	}
	return tmpl, true, nil
}

// countPromptVerbs counts %s verbs, not counting an escaped %%s (the
// pipelines' own check).
func countPromptVerbs(tmpl string) int {
	return strings.Count(tmpl, "%s") - strings.Count(tmpl, "%%s")
}

// runAutomationsUpgradeBuiltins is `automations upgrade-builtins`: the
// failed settings moves, the custom tracks' included, run again now (the
// Inbox's Retry). Each result is
// printed; a move that failed again is a result, not an error. Owner-only,
// like every CLI path to ConfirmAutomation: refused under an agent's markers
// (the daemon's step itself runs under them). The daemon
// picks its path at start, so the Desktop restarts it when a move is done.
func runAutomationsUpgradeBuiltins(cmd *cobra.Command, _ []string) error {
	if err := refuseUnderAgent("retry a built-in's settings move"); err != nil {
		return err
	}
	cfg, database, err := openAutomationsCmd()
	if err != nil {
		return err
	}
	defer database.Close()
	logger := log.New(cmd.ErrOrStderr(), "", 0)
	out := upgradeBuiltinsJSON{Results: []builtinUpgradeResult{}}
	for _, e := range builtin.All() {
		rec, err := database.GetBuiltinMigration(e.ID)
		if err != nil {
			return err
		}
		if rec == nil || rec.Status != db.BuiltinMigrationFailed {
			continue
		}
		out.Results = append(out.Results, upgradeBuiltin(cfg, database, e, time.Now(), logger))
	}
	rec, err := database.GetBuiltinMigration(customTracksID)
	if err != nil {
		return err
	}
	if rec != nil && rec.Status == db.BuiltinMigrationFailed {
		out.Results = append(out.Results, upgradeCustomTracks(cfg, database, time.Now(), logger))
	}
	w := cmd.OutOrStdout()
	if autoFlags.JSON {
		return writeJSON(w, out)
	}
	if len(out.Results) == 0 {
		fmt.Fprintln(w, "No built-in has a failed settings move.")
	}
	for _, r := range out.Results {
		if r.Status == db.BuiltinMigrationDone {
			fmt.Fprintf(w, "%s: moved; restart the daemon so it runs as a built-in.\n", r.BuiltinID)
		} else {
			fmt.Fprintf(w, "%s: failed again: %s\n", r.BuiltinID, r.Error)
		}
	}
	return nil
}
