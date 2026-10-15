package daemon

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/historybackfill"
	"watchtower/internal/ideas"
	"watchtower/internal/imap"
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
func (d *Daemon) phaseHistoryBackfill(ctx context.Context) {
	if d.db == nil {
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
		err := r.Step(ctx)
		if err != nil {
			d.logger.Printf("history backfill: %v", err)
		}
		return pipelineRunStats{err: err}
	})
}

// historyBackfillDue reports whether the phase has work: a running or paused
// row, or slack rows whose one-time hooks have not stamped yet.
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
		if row.SourceKind == "slack" {
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

// accountState maps a row's account to the runner's states. A lookup error
// other than "not found" reads as OK: the chunk's fetch then fails on its own
// and is retried, while a wrong Gone would turn the backfill off for good.
func (d *Daemon) accountState(kind string, id int64) historybackfill.AccountState {
	var status string
	var err error
	switch kind {
	case "slack":
		var a db.SlackAccount
		a, err = d.db.GetSlackAccount(id)
		status = a.Status
		if err == nil && status == "removed" {
			return historybackfill.AccountGone
		}
	case "gmail":
		var a db.GoogleAccount
		a, err = d.db.GetGoogleAccount(id)
		status = a.Status
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
// on the next Step. Neither touches lastPeople nor the attempt budgets.
func (d *Daemon) onSlackBackfillDone(ctx context.Context, floor time.Time) error {
	if d.historyBackfillHooksDone() {
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
// ideas stream digests and consolidator over the chunk.
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
	release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon history backfill")
	if err != nil {
		return false, nil //nolint:nilerr // lock held: retry the chunk next cycle
	}
	defer release()
	if _, err := d.ideasPipe.Backfill(ctx, from, to, nil); err != nil {
		return false, err
	}
	return true, nil
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
