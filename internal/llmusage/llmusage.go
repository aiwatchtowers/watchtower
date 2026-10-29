// Package llmusage records one ledger row per LLM call made by a Watchtower
// process (spec docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md).
// The daemon installs a database Sink; every other process appends to the
// workspace spool, falling back to a direct insert and, failing that, to a
// "call not recorded" line in the log and on stderr.
package llmusage

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"watchtower/internal/pricing"
)

// Call is one finished (or failed) model call; the JSON tags are the
// llm_calls column names and the spool's line keys.
type Call struct {
	CallID          string   `json:"call_id"`
	At              string   `json:"at"`
	Surface         string   `json:"surface"`
	Purpose         string   `json:"purpose"`
	Process         string   `json:"process"`
	Provider        string   `json:"provider"`
	Model           string   `json:"model"`
	Input           int64    `json:"input_tokens"`
	CacheRead       int64    `json:"cache_read_tokens"`
	CacheWrite5m    int64    `json:"cache_write_5m_tokens"`
	CacheWrite1h    int64    `json:"cache_write_1h_tokens"`
	Output          int64    `json:"output_tokens"`
	Estimated       bool     `json:"usage_estimated"`
	ReportedCostUSD *float64 `json:"reported_cost_usd"`
	EstCostUSD      *float64 `json:"est_cost_usd"`
	DurationMS      int64    `json:"duration_ms"`
	OK              bool     `json:"ok"`
	AutomationID    *int64   `json:"automation_id"`
	AutomationRunID *int64   `json:"automation_run_id"`
}

// Sink stores a recorded call (the daemon's database writer).
type Sink interface {
	Write(Call) error
}

// defaultSurface is the surface of a call whose ctx and process name none.
const defaultSurface = "watchtower"

type config struct {
	process, surface string
	sink             Sink
	spoolPath        string
	logPath          string
	fallback         func(Call) error
}

var (
	mu    sync.RWMutex
	state config

	// stderr receives the "call not recorded" line; a test seam.
	stderr io.Writer = os.Stderr
)

// SetProcess names this process (daemon, cli:<path>, mcp:<surface>, …) and
// its default surface ("" = watchtower).
func SetProcess(role, defaultSurface string) {
	mu.Lock()
	defer mu.Unlock()
	state.process, state.surface = role, defaultSurface
}

// SetSpoolPath sets the spool file calls are appended to when no Sink is set.
func SetSpoolPath(path string) {
	mu.Lock()
	defer mu.Unlock()
	state.spoolPath = path
}

// SetSink installs the process's writer; nil restores the spool.
func SetSink(s Sink) {
	mu.Lock()
	defer mu.Unlock()
	state.sink = s
}

// SetFallback sets the writer used when the spool (or Sink) fails: the
// direct insert into the workspace database.
func SetFallback(f func(Call) error) {
	mu.Lock()
	defer mu.Unlock()
	state.fallback = f
}

// SetLogPath sets the log file (watchtower.log) that gets the "call not
// recorded" line.
func SetLogPath(path string) {
	mu.Lock()
	defer mu.Unlock()
	state.logPath = path
}

// EstimateTokens is the length/4 estimate for a provider that reports no
// usage; at least 1 for non-empty text.
func EstimateTokens(s string) int64 {
	if s == "" {
		return 0
	}
	return max(int64(len(s)/4), 1)
}

// Record fills c's call id, time, surface, purpose, process, automation ids
// and price estimate, then stores it: the Sink if set, else the spool; on
// failure the fallback; on its failure a "call not recorded" line. It never
// fails the caller.
func Record(ctx context.Context, c Call) {
	mu.RLock()
	cfg := state
	mu.RUnlock()

	if c.CallID == "" {
		c.CallID = newCallID()
	}
	if c.At == "" {
		c.At = time.Now().UTC().Format(time.RFC3339)
	}
	if c.Surface == "" {
		if s, ok := SurfaceFrom(ctx); ok {
			c.Surface = s
		} else if cfg.surface != "" {
			c.Surface = cfg.surface
		} else {
			c.Surface = defaultSurface
		}
	}
	if c.Purpose == "" {
		c.Purpose, _ = PurposeFrom(ctx)
	}
	if c.Process == "" {
		c.Process = cfg.process
	}
	if c.AutomationID == nil {
		if aid, rid, ok := AutomationFrom(ctx); ok {
			c.AutomationID, c.AutomationRunID = &aid, &rid
		}
	}
	if c.EstCostUSD == nil {
		if usd, known := pricing.Cost(pricing.Resolve(c.Model), "", c.Input, c.Output,
			c.CacheRead, c.CacheWrite5m, c.CacheWrite1h); known {
			c.EstCostUSD = &usd
		}
	}

	err := store(cfg, c)
	if err == nil {
		return
	}
	if cfg.fallback != nil {
		if err = cfg.fallback(c); err == nil {
			return
		}
	}
	reportLoss(cfg, c, err)
}

// store writes c through the Sink, else the spool; a failing Sink still
// tries the spool, which the daemon imports later.
func store(cfg config, c Call) error {
	var err error
	if cfg.sink != nil {
		if err = cfg.sink.Write(c); err == nil {
			return nil
		}
	}
	if cfg.spoolPath == "" {
		if err == nil {
			err = errors.New("no spool")
		}
		return err
	}
	return appendSpool(cfg.spoolPath, c)
}

// reportLoss writes the one "call not recorded" line to the log (when set)
// and to stderr. The error is reduced to its class: no paths or text.
func reportLoss(cfg config, c Call, err error) {
	line := fmt.Sprintf("llmusage: call not recorded (%s, %s): %s\n", c.Purpose, c.Process, errClass(err))
	if cfg.logPath != "" {
		_ = os.MkdirAll(filepath.Dir(cfg.logPath), 0o700) // the open below reports a failure
		if f, oerr := os.OpenFile(cfg.logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); oerr == nil {
			_, _ = io.WriteString(f, time.Now().Format("2006/01/02 15:04:05 ")+line)
			_ = f.Close()
		}
	}
	_, _ = io.WriteString(stderr, line)
}

func errClass(err error) string {
	switch {
	case errors.Is(err, syscall.ENOSPC):
		return "disk full"
	case errors.Is(err, syscall.EROFS):
		return "read-only file system"
	case errors.Is(err, fs.ErrPermission):
		return "permission denied"
	case errors.Is(err, fs.ErrNotExist):
		return "not found"
	default:
		return "write failed"
	}
}

func newCallID() string {
	var b [8]byte
	_, _ = rand.Read(b[:]) // crypto/rand.Read never fails (Go 1.24+)
	return hex.EncodeToString(b[:])
}
