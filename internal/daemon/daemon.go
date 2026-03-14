// Package daemon provides background daemon and service management capabilities.
package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	gosync "sync"
	"time"

	"watchtower/internal/analysis"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/sessions"
	"watchtower/internal/sync"
	"watchtower/internal/tracks"
)

// minPollInterval is the minimum allowed poll interval. Values below this
// (e.g. nanosecond-scale durations from misconfigured integer values) are
// replaced with DefaultPollInterval. Tests may lower this for fast execution.
var minPollInterval = 1 * time.Second

// Daemon runs periodic incremental syncs on a timer and after wake-from-sleep events.
type Daemon struct {
	orchestrator *sync.Orchestrator
	config       *config.Config
	logger       *log.Logger
	wakeCh       <-chan struct{}
	pidPath      string
	pool         *sessions.SessionPool // session pool for reusable Claude sessions
	digestPipe   *digest.Pipeline
	analysisPipe *analysis.Pipeline
	tracksPipe   *tracks.Pipeline
	lastAnalysis time.Time // when analysis last ran (once per day)
	lastTracks   time.Time // when tracks last ran (throttled)
}

// New creates a Daemon that runs incremental syncs via the given orchestrator.
// The session pool is created immediately and should be closed after Run() completes.
// Pool size is determined by cfg.Digest.Workers (number of concurrent digest operations).
func New(orchestrator *sync.Orchestrator, cfg *config.Config) *Daemon {
	poolSize := cfg.Digest.Workers
	if poolSize <= 0 {
		poolSize = 1
	}
	return &Daemon{
		orchestrator: orchestrator,
		config:       cfg,
		logger:       log.New(os.Stderr, "[daemon] ", log.LstdFlags),
		pool:         sessions.NewSessionPool(poolSize),
	}
}

// SetLogger replaces the daemon's logger.
func (d *Daemon) SetLogger(l *log.Logger) {
	d.logger = l
}

// SetDigestPipeline sets the digest pipeline for post-sync digest generation.
func (d *Daemon) SetDigestPipeline(p *digest.Pipeline) {
	d.digestPipe = p
}

// SetAnalysisPipeline sets the people analysis pipeline for post-digest analysis.
func (d *Daemon) SetAnalysisPipeline(p *analysis.Pipeline) {
	d.analysisPipe = p
}

// SetTracksPipeline sets the tracks pipeline for post-digest extraction.
func (d *Daemon) SetTracksPipeline(p *tracks.Pipeline) {
	d.tracksPipe = p
}

// SetPIDPath sets the path where the daemon will write its PID file.
func (d *Daemon) SetPIDPath(path string) {
	d.pidPath = path
}

// SessionPool returns the daemon's session pool for use with generators.
func (d *Daemon) SessionPool() *sessions.SessionPool {
	return d.pool
}

// Run starts the daemon poll loop. It blocks until ctx is cancelled.
// The caller is responsible for wiring signal handling into the context.
// Each tick or wake event triggers an incremental sync.
func (d *Daemon) Run(ctx context.Context) error {
	if d.pidPath != "" {
		if err := WritePID(d.pidPath); err != nil {
			return fmt.Errorf("writing pid file: %w", err)
		}
		defer RemovePID(d.pidPath)
	}

	pollInterval := d.config.Sync.PollInterval
	if pollInterval < minPollInterval {
		pollInterval = config.DefaultPollInterval
	}

	if d.config.Sync.SyncOnWake {
		d.wakeCh = WatchWake(ctx, pollInterval)
	}

	// Restore last pipeline times from disk so throttle guards survive restarts.
	d.loadLastAnalysis()
	d.loadLastTracks()

	// Close session pool on shutdown
	defer d.pool.Close()

	d.logger.Printf("daemon started, polling every %s, session pool size: %d", pollInterval, d.pool.Size())

	// Run an initial sync immediately on startup.
	d.runSync(ctx)

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			d.logger.Println("shutting down")
			return nil
		case <-ticker.C:
			d.runSync(ctx)
		case <-d.wakeChannel():
			d.logger.Println("wake event detected, syncing")
			d.runSync(ctx)
			// Reset the ticker so the next poll is a full interval from now.
			ticker.Reset(pollInterval)
		}
	}
}

// wakeChannel returns the wake channel or a nil channel (blocks forever) when
// wake detection is disabled.
func (d *Daemon) wakeChannel() <-chan struct{} {
	if d.wakeCh != nil {
		return d.wakeCh
	}
	return nil
}

func (d *Daemon) runSync(ctx context.Context) {
	// Pre-sync: reactivate snoozed tracks whose snooze_until has passed.
	if d.tracksPipe != nil {
		if n, err := d.tracksPipe.ReactivateSnoozed(ctx); err != nil {
			d.logger.Printf("snooze reactivation error: %v", err)
		} else if n > 0 {
			d.logger.Printf("reactivated %d snoozed track(s)", n)
		}
	}

	opts := sync.SyncOptions{}
	syncErr := d.orchestrator.Run(ctx, opts)
	if syncErr != nil {
		d.logger.Printf("sync error: %v", syncErr)
	}

	// Persist last sync result for `watchtower status`.
	snap := d.orchestrator.Progress().Snapshot()
	resultPath := filepath.Join(d.config.WorkspaceDir(), "last_sync.json")
	if err := sync.WriteSyncResult(resultPath, sync.ResultFromSnapshot(snap, syncErr)); err != nil {
		d.logger.Printf("failed to write sync result: %v", err)
	}

	// Run pipelines even if sync had a non-fatal error (e.g. rate-limited,
	// partial fetch). The DB still has messages that need processing.
	// Only skip pipelines if the context itself was cancelled (shutdown).
	if ctx.Err() != nil {
		d.logger.Printf("context cancelled, skipping pipelines")
		return
	}

	if syncErr != nil {
		d.logger.Printf("sync had errors, but running pipelines on existing data")
	}

	// Phase 1: Digests + People in parallel (independent pipelines).
	// People analysis runs once per day; digests run every sync.
	var wg gosync.WaitGroup

	if d.digestPipe != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			n, usage, err := d.digestPipe.Run(ctx)
			if err != nil {
				d.logger.Printf("digest error: %v", err)
			} else if n > 0 {
				if usage != nil && (usage.InputTokens > 0 || usage.OutputTokens > 0) {
					d.logger.Printf("generated %d digest(s) (%d+%d tokens, $%.4f)",
						n, usage.InputTokens, usage.OutputTokens, usage.CostUSD)
				} else {
					d.logger.Printf("generated %d digest(s)", n)
				}
			}
		}()
	}

	if d.analysisPipe != nil {
		now := time.Now()
		if d.lastAnalysis.IsZero() || now.Sub(d.lastAnalysis) >= 24*time.Hour {
			wg.Add(1)
			go func() {
				defer wg.Done()
				n, err := d.analysisPipe.Run(ctx)
				if err != nil {
					d.logger.Printf("people analysis error: %v", err)
				} else {
					if n > 0 {
						d.logger.Printf("analyzed %d user(s)", n)
					}
					d.lastAnalysis = now
					d.saveLastAnalysis()
				}
			}()
		}
	}

	wg.Wait()

	// Phase 2: Tracks (depend on digests for related_digest_ids).
	// Throttled to run at most once per tracks interval (default 1h).
	if d.tracksPipe != nil {
		interval := d.config.Digest.TracksInterval
		if interval <= 0 {
			interval = config.DefaultTracksInterval
		}
		now := time.Now()
		if d.lastTracks.IsZero() || now.Sub(d.lastTracks) >= interval {
			n, err := d.tracksPipe.Run(ctx)
			if err != nil {
				d.logger.Printf("tracks error: %v", err)
			} else {
				if n > 0 {
					d.logger.Printf("extracted %d track(s)", n)
				}
				d.lastTracks = now
				d.saveLastTracks()
			}
		}
	}

	// Check for updates on existing items (lightweight, runs every sync).
	if d.tracksPipe != nil {
		n, err := d.tracksPipe.CheckForUpdates(ctx)
		if err != nil {
			d.logger.Printf("tracks update check error: %v", err)
		} else if n > 0 {
			d.logger.Printf("detected updates on %d track(s)", n)
		}
	}
}

// lastAnalysisPath returns the file path for persisting the last analysis time.
func (d *Daemon) lastAnalysisPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_analysis.txt")
}

// loadLastAnalysis restores lastAnalysis from disk so the 24h guard survives daemon restarts.
func (d *Daemon) loadLastAnalysis() {
	data, err := os.ReadFile(d.lastAnalysisPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastAnalysis = time.Unix(unix, 0)
	d.logger.Printf("restored last analysis time: %s", d.lastAnalysis.Format(time.RFC3339))
}

// saveLastAnalysis persists lastAnalysis to disk.
func (d *Daemon) saveLastAnalysis() {
	data := strconv.FormatInt(d.lastAnalysis.Unix(), 10)
	if err := os.WriteFile(d.lastAnalysisPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last analysis time: %v", err)
	}
}

// lastTracksPath returns the file path for persisting the last tracks time.
// Keeps the old filename "last_action_items.txt" for backward compatibility
// with existing daemon installations.
func (d *Daemon) lastTracksPath() string {
	return filepath.Join(d.config.WorkspaceDir(), "last_action_items.txt")
}

// loadLastTracks restores lastTracks from disk so the throttle survives restarts.
func (d *Daemon) loadLastTracks() {
	data, err := os.ReadFile(d.lastTracksPath())
	if err != nil {
		return
	}
	unix, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return
	}
	d.lastTracks = time.Unix(unix, 0)
	d.logger.Printf("restored last tracks time: %s", d.lastTracks.Format(time.RFC3339))
}

// saveLastTracks persists lastTracks to disk.
func (d *Daemon) saveLastTracks() {
	data := strconv.FormatInt(d.lastTracks.Unix(), 10)
	if err := os.WriteFile(d.lastTracksPath(), []byte(data), 0o600); err != nil {
		d.logger.Printf("failed to save last tracks time: %v", err)
	}
}
