package daemon

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/historybackfill"
	"watchtower/internal/ideas"
	"watchtower/internal/imap"
	"watchtower/internal/planusage"
	"watchtower/internal/sync"
)

// historyBackfillBudget is the phase's wall-clock budget per cycle.
const historyBackfillBudget = 5 * time.Minute

// startHistoryBackfill records a source's backfill right after its first
// sync (docs/features/history-backfill.md). from is that sync's window start.
// A repeat is harmless: only the first call for a source inserts its row.
func (d *Daemon) startHistoryBackfill(kind string, accountID int64, from time.Time) {
	days := d.config.Sync.BackfillDays
	if days <= 0 || d.db == nil {
		return
	}
	now := time.Now()
	floor := now.AddDate(0, 0, -days)
	if !from.After(floor) {
		return // the first sync already reached the floor
	}
	created, err := d.db.StartHistoryBackfill(kind, accountID, float64(floor.Unix()), float64(from.Unix()), now)
	if err != nil {
		d.logger.Printf("history backfill: start %s account %d: %v", kind, accountID, err)
		return
	}
	if created {
		d.logger.Printf("history backfill: %s account %d — loading %s back to %s", kind, accountID,
			from.Format("2006-01-02"), floor.Format("2006-01-02"))
	}
}

// phaseHistoryBackfill walks each new source's history back one chunk per
// cycle. It is the last phase of runSync: it shares the digest pipeline and
// the ideas lock with the forward phases, so it never runs beside them. It
// also runs once all rows are done until the one-time Slack-done hooks have
// stamped (R14), so a hook failure is retried on later cycles.
// sync.backfill_days <= 0 is the kill switch (R20): the phase does not run
// and the rows stay as they are; setting it back resumes them. Memory keeps
// waiting while a row is still running or paused.
func (d *Daemon) phaseHistoryBackfill(ctx context.Context) {
	if d.db == nil || d.config.Sync.BackfillDays <= 0 {
		return
	}
	if !d.historyBackfillDue() {
		return
	}
	r := &historybackfill.Runner{
		Store:       d.db,
		Sources:     d.historyBackfillSources(),
		Account:     d.accountState,
		OnSlackDone: d.onSlackBackfillDone,
		Budget:      historyBackfillBudget,
		Now:         time.Now,
		Logger:      d.logger,
	}
	d.trackedPipelineRun("history-backfill", func() pipelineRunStats {
		// The digest and ideas pipelines are shared with the forward phases,
		// so their counters are running totals: report this Step's delta
		// (the phaseIdeas pattern). The phase runs alone, after them.
		u0 := d.historyBackfillUsage()
		err := r.Step(ctx)
		if err != nil {
			d.logger.Printf("history backfill: %v", err)
		}
		u := d.historyBackfillUsage()
		return pipelineRunStats{inTok: u.inTok - u0.inTok, outTok: u.outTok - u0.outTok,
			cost: u.cost - u0.cost, totalAPI: u.totalAPI - u0.totalAPI, err: err}
	})
}

// historyBackfillUsage sums the AI usage counters of the pipelines the
// backfill sources call.
func (d *Daemon) historyBackfillUsage() pipelineRunStats {
	var s pipelineRunStats
	if d.digestPipe != nil {
		in, out, cost, api := d.digestPipe.AccumulatedUsage()
		s.inTok, s.outTok, s.cost, s.totalAPI = s.inTok+in, s.outTok+out, s.cost+cost, s.totalAPI+api
	}
	if d.ideasPipe != nil {
		in, out, cost, api := d.ideasPipe.AccumulatedUsage()
		s.inTok, s.outTok, s.cost, s.totalAPI = s.inTok+in, s.outTok+out, s.cost+cost, s.totalAPI+api
	}
	return s
}

// historyBackfillDue reports whether the phase has work: a running or paused
// row, or a done slack row whose one-time hooks have not stamped yet (R24:
// slack rows that are all off give the hooks nothing to do, as in the
// runner's slackDone).
func (d *Daemon) historyBackfillDue() bool {
	active, err := d.db.HasActiveHistoryBackfill()
	if err != nil {
		d.logger.Printf("history backfill: %v", err)
		return false
	}
	if active {
		return true
	}
	if d.historyBackfillHooksDone() {
		return false
	}
	rows, err := d.db.ListHistoryBackfills()
	if err != nil {
		d.logger.Printf("history backfill: %v", err)
		return false
	}
	for _, row := range rows {
		if row.SourceKind == "slack" && row.Status == "done" {
			return true
		}
	}
	return false
}

// historyBackfillSources builds one source per wired Slack orchestrator,
// Gmail syncer and IMAP syncer.
func (d *Daemon) historyBackfillSources() []historybackfill.Source {
	out := make([]historybackfill.Source, 0, len(d.orchestrators)+len(d.gmailSyncers)+len(d.imapSyncers))
	for _, o := range d.orchestrators {
		out = append(out, slackSource{o: o, d: d})
	}
	for _, s := range d.gmailSyncers {
		out = append(out, gmailSource{s: s, d: d})
	}
	for _, s := range d.imapSyncers {
		out = append(out, imapSource{s: s})
	}
	return out
}

// accountState maps a row's account to the runner's states. An account whose
// source is turned off reads as Gone (R15): it is never wired, so its row
// would otherwise stay running forever and hold memory extraction back. A
// lookup error other than "not found" reads as OK: the chunk's fetch then
// fails on its own and is retried, while a wrong Gone would turn the
// backfill off for good. IMAP accounts have no enabled flag and no revoked
// state, so only a deleted mailbox ends theirs.
func (d *Daemon) accountState(kind string, id int64) historybackfill.AccountState {
	var status string
	var err error
	switch kind {
	case "slack":
		var a db.SlackAccount
		a, err = d.db.GetSlackAccount(id)
		status = a.Status
		if err == nil && (status == "removed" || !a.Enabled) {
			return historybackfill.AccountGone
		}
	case "gmail":
		var a db.GoogleAccount
		a, err = d.db.GetGoogleAccount(id)
		status = a.Status
		if err == nil && (!d.config.Gmail.Enabled || !a.GmailEnabled) {
			return historybackfill.AccountGone
		}
	case "imap":
		_, err = d.db.GetEmailAccount(id) // IMAP has no revoked state
	default:
		return historybackfill.AccountGone
	}
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return historybackfill.AccountGone
	case err != nil:
		d.logger.Printf("history backfill: %s account %d lookup: %v", kind, id, err)
		return historybackfill.AccountOK
	case status == "revoked":
		return historybackfill.AccountRevoked
	}
	return historybackfill.AccountOK
}

func (d *Daemon) historyBackfillHooksStampPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "history_backfill_hooks_done.txt")
}

func (d *Daemon) historyBackfillHooksDone() bool {
	_, err := os.Stat(d.historyBackfillHooksStampPath())
	return err == nil
}

// onSlackBackfillDone runs the one-time follow-ups once every Slack backfill
// is done: the mention backfill and a people-card run over [floor, now]. The
// runner calls it on every Step while that holds; the stamp file makes it
// run-once, and is written only when both succeeded, so a failure is retried
// on the next Step. Neither touches lastPeople nor the attempt budgets. The
// runner calls it under its budget ctx, and while the Claude plan limit is
// near the hooks wait — held, not failed, no stamp — for a later Step (R21).
func (d *Daemon) onSlackBackfillDone(ctx context.Context, floor time.Time) error {
	if d.historyBackfillHooksDone() {
		return nil
	}
	st, err := d.db.GetPlanUsageStatus()
	if err != nil {
		d.logger.Printf("history backfill: plan usage status: %v", err) // unreadable: does not block
	} else if planusage.NearLimit(st) {
		d.logger.Printf("history backfill: Claude plan limit near, the Slack-done follow-ups wait")
		return nil
	}
	var firstErr error
	if d.config.Inbox.Enabled && d.inboxPipe != nil {
		res, err := d.inboxPipe.BackfillMentions(ctx, floor, false)
		if err != nil {
			d.logger.Printf("history backfill: mention backfill: %v", err)
			firstErr = err
		} else {
			d.logger.Printf("history backfill: mention backfill created %d item(s) from %d candidate(s)",
				res.TotalCreated, res.TotalCandidates)
		}
	}
	if d.config.People.Enabled && d.config.Digest.Enabled && d.peoplePipe != nil {
		d.trackedPipelineRun("people-backfill", func() pipelineRunStats {
			inTok0, outTok0, cost0, totalAPI0 := d.peoplePipe.AccumulatedUsage()
			n, err := d.peoplePipe.RunForWindow(ctx, float64(floor.Unix()), float64(time.Now().Unix()))
			if err != nil {
				d.logger.Printf("history backfill: people cards: %v", err)
				if firstErr == nil {
					firstErr = err
				}
			}
			inTok, outTok, cost, totalAPI := d.peoplePipe.AccumulatedUsage()
			return pipelineRunStats{items: n, inTok: inTok - inTok0, outTok: outTok - outTok0,
				cost: cost - cost0, totalAPI: totalAPI - totalAPI0, err: err}
		})
	}
	if firstErr != nil {
		return firstErr
	}
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	if err := os.WriteFile(d.historyBackfillHooksStampPath(), []byte(stamp), 0o600); err != nil {
		d.logger.Printf("history backfill: writing hooks stamp: %v", err)
		return err
	}
	return nil
}

// slackSource backfills one Slack account: search fetch, then chunk digests
// and the chunk's daily rollups.
type slackSource struct {
	o *sync.Orchestrator
	d *Daemon
}

func (s slackSource) Kind() string     { return "slack" }
func (s slackSource) AccountID() int64 { return s.o.AccountID() }

func (s slackSource) Fetch(ctx context.Context, from, to time.Time) error {
	_, err := s.o.BackfillSearch(ctx, from, to)
	return slackFetchErr(err)
}

// slackFetchErr maps an incomplete search (a rate limit or partial pages) to
// the runner's hold: transient, so no strike (R23).
func slackFetchErr(err error) error {
	if errors.Is(err, sync.ErrBackfillIncomplete) {
		return fmt.Errorf("%w: %w", historybackfill.ErrHold, err)
	}
	return err
}

func (s slackSource) Process(ctx context.Context, from, to time.Time) (bool, error) {
	d := s.d
	if !d.config.Digest.Enabled || d.digestPipe == nil {
		return true, nil
	}
	fromTS, toTS := float64(from.Unix()), float64(to.Unix())
	res, _, err := d.digestPipe.RunBackfillWindow(ctx, fromTS, toTS)
	if err != nil || !res.Complete {
		return false, err
	}
	if err := d.digestPipe.RunBackfillRollups(ctx, fromTS, toTS); err != nil {
		return false, err
	}
	return true, nil
}

// gmailSource backfills one Google account's mail: range fetch, then the
// ideas stream digests (streams.enabled) and consolidator (ideas.enabled,
// gated inside ideas.Backfill) over the chunk. ideas.Backfill drains a
// window for every Google and Jira account at once, so a window already
// drained by another Gmail row is not drained again (M4).
type gmailSource struct {
	s *gmail.Syncer
	d *Daemon
}

func (g gmailSource) Kind() string     { return "gmail" }
func (g gmailSource) AccountID() int64 { return g.s.AccountID() }

func (g gmailSource) Fetch(ctx context.Context, from, to time.Time) error {
	_, err := g.s.FetchRange(ctx, from, to)
	return err
}

func (g gmailSource) Process(ctx context.Context, from, to time.Time) (bool, error) {
	d := g.d
	if d.ideasPipe == nil || !d.config.Streams.Enabled {
		return true, nil
	}
	from, to, ok := uncoveredSpan(d.ideasDrained, from, to)
	if !ok {
		return true, nil // another Gmail row's chunk already drained this window
	}
	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon history backfill")
	if errors.Is(err, ideas.ErrBackfillLockHeld) {
		d.logger.Printf("history backfill: gmail chunk waits — %v", err)
		return false, nil // held: retry the chunk next cycle
	}
	if err != nil {
		return false, err
	}
	defer release()
	if _, err := d.ideasPipe.Backfill(ctx, from, to, nil); err != nil {
		return false, err
	}
	d.ideasDrained = append(d.ideasDrained, timeSpan{from, to})
	return true, nil
}

// timeSpan is a [from, to) window.
type timeSpan struct{ from, to time.Time }

// uncoveredSpan clips [from, to) by the spans that cover either end of it
// and reports what is left; ok is false when nothing is. A span strictly
// inside the window leaves it whole: a hole in the middle is drained again
// rather than split.
func uncoveredSpan(spans []timeSpan, from, to time.Time) (time.Time, time.Time, bool) {
	for changed := true; changed && from.Before(to); {
		changed = false
		for _, s := range spans {
			switch {
			case !s.from.After(from) && s.to.After(from): // covers the bottom end
				from, changed = s.to, true
			case s.from.Before(to) && !s.to.Before(to): // covers the top end
				to, changed = s.from, true
			}
			if !from.Before(to) {
				break
			}
		}
	}
	return from, to, from.Before(to)
}

// imapSource backfills one IMAP mailbox: fetch only (no AI step).
type imapSource struct {
	s *imap.Syncer
}

func (m imapSource) Kind() string     { return "imap" }
func (m imapSource) AccountID() int64 { return m.s.AccountID() }

func (m imapSource) Fetch(ctx context.Context, from, to time.Time) error {
	_, err := m.s.FetchRange(ctx, from, to)
	return err
}

func (imapSource) Process(context.Context, time.Time, time.Time) (bool, error) { return true, nil }
