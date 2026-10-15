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
	"watchtower/internal/digest"
	"watchtower/internal/historybackfill"
	"watchtower/internal/ideas"
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
// Gmail syncer, IMAP syncer and Jira syncer.
func (d *Daemon) historyBackfillSources() []historybackfill.Source {
	out := make([]historybackfill.Source, 0, len(d.orchestrators)+len(d.gmailSyncers)+len(d.imapSyncers)+len(d.jiraSyncers))
	for _, o := range d.orchestrators {
		out = append(out, slackSource{o: o, id: o.AccountID(), d: d})
	}
	for _, s := range d.gmailSyncers {
		out = append(out, gmailSource{s: s, id: s.AccountID(), d: d})
	}
	for _, s := range d.jiraSyncers {
		out = append(out, jiraSource{id: s.AccountID(), d: d})
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
// backfill off for good. Jira reads as Gone also when jira.enabled is off.
// IMAP accounts have no enabled flag and no revoked
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
	case "jira":
		var a db.JiraAccount
		a, err = d.db.GetJiraAccount(id)
		status = a.Status
		if err == nil && (!d.config.Jira.Enabled || status == "removed" || !a.Enabled) {
			return historybackfill.AccountGone
		}
	default:
		return historybackfill.AccountGone
	}
	switch {
	case errors.Is(err, sql.ErrNoRows), errors.Is(err, db.ErrJiraAccountNotFound):
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
	o  *sync.Orchestrator
	id int64
	d  *Daemon
}

func (s slackSource) Kind() string     { return "slack" }
func (s slackSource) AccountID() int64 { return s.id }

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
	res, _, err := d.digestPipe.RunBackfillWindow(ctx, s.id, fromTS, toTS)
	if err != nil || !res.Complete {
		return false, err
	}
	if err := d.digestPipe.RunBackfillRollups(ctx, fromTS, toTS); err != nil {
		return false, slackRollupErr(err)
	}
	return true, nil
}

// slackRollupErr maps the rollups' digest-lock contention to the runner's
// hold, like the window's (which reports it as incomplete): another digest
// run holds the lock, so the chunk is retried without a strike. Any other
// error is a failure.
func slackRollupErr(err error) error {
	if errors.Is(err, digest.ErrDigestLocked) {
		return fmt.Errorf("%w: %w", historybackfill.ErrHold, err)
	}
	return err
}

// gmailSource backfills one Google account's mail: range fetch, then that
// account's ideas stream digests over the chunk (R28). The stream digests
// are consolidated by the regular ideas run, which keeps the ideas.enabled
// gate.
type gmailSource struct {
	s  mailSyncer
	id int64
	d  *Daemon
}

func (g gmailSource) Kind() string     { return "gmail" }
func (g gmailSource) AccountID() int64 { return g.id }

func (g gmailSource) Fetch(ctx context.Context, from, to time.Time) error {
	_, err := g.s.FetchRange(ctx, from, to)
	return err
}

func (g gmailSource) Process(ctx context.Context, from, to time.Time) (bool, error) {
	return g.d.backfillStreams(backfillResumeKey{"gmail", g.id, from.Unix()}, from,
		func(start time.Time) (time.Time, bool, error) {
			return g.d.ideasPipe.BackfillEmail(ctx, g.id, start, to)
		})
}

// jiraSource backfills one Jira account's stream digests (R29). Fetch is a
// no-op: Jira's first sync is a full scan, so every issue is already stored.
type jiraSource struct {
	id int64
	d  *Daemon
}

func (j jiraSource) Kind() string                                    { return "jira" }
func (j jiraSource) AccountID() int64                                { return j.id }
func (jiraSource) Fetch(context.Context, time.Time, time.Time) error { return nil }

func (j jiraSource) Process(ctx context.Context, from, to time.Time) (bool, error) {
	return j.d.backfillStreams(backfillResumeKey{"jira", j.id, from.Unix()}, from,
		func(start time.Time) (time.Time, bool, error) {
			return j.d.ideasPipe.BackfillJira(ctx, j.id, start, to)
		})
}

// backfillResumeKey names one chunk of one account's stage-1 drain: the
// source kind, the account and the chunk's start (unix seconds).
type backfillResumeKey struct {
	kind    string
	account int64
	from    int64
}

// backfillStreams runs one account's stage-1 stream drain under the ideas
// backfill lock, gated on streams.enabled. A held lock is not an error: the
// chunk is retried next cycle. The drain starts at the chunk's resume point
// when an earlier attempt was held or failed part-way (F2), so a chunk cut by
// the budget deadline or the drain's cycle cap does not re-pay the stage-1
// calls it already made; the point is dropped once the chunk completes.
func (d *Daemon) backfillStreams(key backfillResumeKey, from time.Time, drain func(start time.Time) (time.Time, bool, error)) (bool, error) {
	if d.ideasPipe == nil || !d.config.Streams.Enabled {
		return true, nil
	}
	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon history backfill")
	if errors.Is(err, ideas.ErrBackfillLockHeld) {
		d.logger.Printf("history backfill: %s chunk waits — %v", key.kind, err)
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer release()
	start := from
	if r, ok := d.backfillResume[key]; ok {
		start = r
	}
	reached, complete, err := drain(start)
	if complete {
		delete(d.backfillResume, key)
		return true, err
	}
	if reached.After(start) {
		if d.backfillResume == nil {
			d.backfillResume = map[backfillResumeKey]time.Time{}
		}
		d.backfillResume[key] = reached
	}
	return false, err
}

// imapSource backfills one IMAP mailbox: fetch only (no AI step).
type imapSource struct {
	s mailSyncer
}

func (m imapSource) Kind() string     { return "imap" }
func (m imapSource) AccountID() int64 { return m.s.AccountID() }

func (m imapSource) Fetch(ctx context.Context, from, to time.Time) error {
	_, err := m.s.FetchRange(ctx, from, to)
	return err
}

func (imapSource) Process(context.Context, time.Time, time.Time) (bool, error) { return true, nil }
