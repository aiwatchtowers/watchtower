// Package lockstats reads the SQLite lock-metrics log (dblock.jsonl and its
// rotated .1 generation, written by internal/db/lockmetrics and the Desktop
// app) and summarises it for `watchtower db lockstats`: the slowest write
// transactions and autocommit writes per site, busy errors, which other
// processes held the lock when each busy happened, WAL size and checkpoint
// results, connection-pool waits and each process role's newest event.
package lockstats

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"sort"
	"time"

	"watchtower/internal/db/lockmetrics"
)

// unknownSite names events written without a site.
const unknownSite = "(unknown)"

// Parsed is the content of the log files, in file order.
type Parsed struct {
	Events    []lockmetrics.Event
	Malformed int      // lines that are not a known event; blank lines are not counted
	Files     []string // the files that existed and were read
}

// ReadFiles parses each path in order (oldest generation first). A missing
// file is skipped; any other open or read error is returned. A line that is
// not a JSON object, has no ts, or names an unknown kind is counted as
// malformed and skipped — a writer may be mid-append, or a future writer may
// add kinds this reader does not know.
func ReadFiles(paths []string) (Parsed, error) {
	var p Parsed
	for _, path := range paths {
		f, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return Parsed{}, fmt.Errorf("opening %s: %w", path, err)
		}
		err = readLines(f, &p)
		_ = f.Close() // read-only; the read error is the one that matters
		if err != nil {
			return Parsed{}, fmt.Errorf("reading %s: %w", path, err)
		}
		p.Files = append(p.Files, path)
	}
	return p, nil
}

// readLines uses ReadBytes rather than a Scanner so no line length is fatal.
func readLines(r io.Reader, p *Parsed) error {
	br := bufio.NewReader(r)
	for {
		line, err := br.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			if e, ok := parseLine(line); ok {
				p.Events = append(p.Events, e)
			} else {
				p.Malformed++
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func parseLine(line []byte) (lockmetrics.Event, bool) {
	var e lockmetrics.Event
	if err := json.Unmarshal(line, &e); err != nil || e.TS.IsZero() {
		return lockmetrics.Event{}, false
	}
	switch e.Kind {
	case lockmetrics.KindTx, lockmetrics.KindExec, lockmetrics.KindBusy,
		lockmetrics.KindPoolWait, lockmetrics.KindWAL:
		return e, true
	}
	return lockmetrics.Event{}, false
}

// Report is the summary; its JSON keys are the `db lockstats --json`
// contract (pinned by TestReport_JSONKeysPinned).
type Report struct {
	Window      Window      `json:"window"`
	Malformed   int         `json:"malformed"`
	Sites       []Site      `json:"sites"`
	ExecSites   []ExecSite  `json:"exec_sites"`
	Busy        []BusyGroup `json:"busy"`
	BusyHolders []BusyEvent `json:"busy_holders"`
	WAL         WAL         `json:"wal"`
	PoolWait    []PoolWait  `json:"pool_wait"`
	Procs       []ProcLast  `json:"procs"`
}

// Window is the time range the report covers.
type Window struct {
	From         time.Time `json:"from"`
	To           time.Time `json:"to"`
	SinceSeconds int64     `json:"since_seconds"`
	Events       int       `json:"events"` // events inside the window
	Files        []string  `json:"files"`
}

// Site aggregates the slow tx events of one call site, across processes.
// A tx's hold_ms is a true hold (BEGIN done → COMMIT/ROLLBACK done); exec
// events are kept apart in ExecSite because theirs is not.
type Site struct {
	Site        string `json:"site"`
	Count       int    `json:"count"`
	TotalHoldMS int64  `json:"total_hold_ms"`
	MaxHoldMS   int64  `json:"max_hold_ms"`
	MaxWaitMS   int64  `json:"max_wait_ms"`
	Over1s      int    `json:"over_1s"` // holds > 1000 ms
	Over5s      int    `json:"over_5s"` // holds > 5000 ms
}

// ExecSite aggregates the slow autocommit writes (exec events) of one call
// site. An exec's duration is its wait for the write lock and its hold
// together — the driver cannot split them — so a slow exec may have spent
// all of it queued behind another process: it is never summed with holds.
type ExecSite struct {
	Site    string `json:"site"`
	Count   int    `json:"count"`
	TotalMS int64  `json:"total_ms"` // wait+hold, summed
	MaxMS   int64  `json:"max_ms"`   // wait+hold of the slowest one
}

// BusyGroup counts busy/locked errors per process role and site.
type BusyGroup struct {
	Proc           string   `json:"proc"`
	Site           string   `json:"site"`
	Count          int      `json:"count"`
	BusyTimeoutsMS []int64  `json:"busy_timeouts_ms"` // distinct, ascending
	Errs           []string `json:"errs"`             // distinct, ascending
}

// BusyEvent is one busy error with the other processes' slow transactions
// that overlapped its wait, and their slow autocommit writes that did.
type BusyEvent struct {
	TS            time.Time     `json:"ts"`
	PID           int           `json:"pid"`
	Proc          string        `json:"proc"`
	Site          string        `json:"site"`
	Err           string        `json:"err"`
	WaitMS        int64         `json:"wait_ms"` // measured wait; 0 = not recorded
	BusyTimeoutMS int64         `json:"busy_timeout_ms"`
	Holders       []Holder      `json:"holders"`
	Execs         []ExecOverlap `json:"execs"`
}

// Holder is a tx of another pid that held the write lock during a busy
// wait. Only holds at or above the writer's threshold are logged, so an
// empty list means no slow holder was recorded, not that nobody held it.
type Holder struct {
	TS     time.Time `json:"ts"` // when the tx ended
	PID    int       `json:"pid"`
	Proc   string    `json:"proc"`
	Kind   string    `json:"kind"`
	Site   string    `json:"site"`
	HoldMS int64     `json:"hold_ms"`
}

// ExecOverlap is a slow autocommit write of another pid whose duration
// overlapped a busy wait. Its ms is wait+hold, so it may have been a waiter
// itself, not the holder.
type ExecOverlap struct {
	TS   time.Time `json:"ts"` // when the exec ended
	PID  int       `json:"pid"`
	Proc string    `json:"proc"`
	Site string    `json:"site"`
	MS   int64     `json:"ms"` // wait+hold
}

// WAL summarises the WAL size samples and their checkpoint results
// ("busy=N log=N ckpt=N", PRAGMA wal_checkpoint's three columns).
type WAL struct {
	Samples              int    `json:"samples"`
	MinBytes             int64  `json:"min_bytes"`
	MedianBytes          int64  `json:"median_bytes"`
	MaxBytes             int64  `json:"max_bytes"`
	Checkpoints          int    `json:"checkpoints"`           // parsed results
	CheckpointBusy       int    `json:"checkpoint_busy"`       // busy != 0
	CheckpointIncomplete int    `json:"checkpoint_incomplete"` // ckpt < log
	CheckpointUnparsed   int    `json:"checkpoint_unparsed"`
	LastCheckpoint       string `json:"last_checkpoint,omitempty"`
}

// PoolWait aggregates database/sql connection-pool waits per process role.
type PoolWait struct {
	Proc        string `json:"proc"`
	Count       int    `json:"count"`
	TotalWaitMS int64  `json:"total_wait_ms"`
	MaxWaitMS   int64  `json:"max_wait_ms"`
}

// ProcLast is a process role's newest event in the files read, whatever the
// window: a role whose last line is old has a dead or disabled sink (or has
// not run), which a quiet window alone cannot tell apart.
type ProcLast struct {
	Proc   string    `json:"proc"`
	LastTS time.Time `json:"last_ts"`
	Events int       `json:"events"` // inside the window
}

// Build summarises the events with ts in [now-since, now]; Procs looks at
// every event read.
func Build(p Parsed, now time.Time, since time.Duration) Report {
	from := now.Add(-since)
	r := Report{
		Window: Window{
			From: from, To: now, SinceSeconds: int64(since / time.Second),
			Files: p.Files,
		},
		Malformed: p.Malformed,
	}
	if r.Window.Files == nil {
		r.Window.Files = []string{}
	}

	var holds, execs, busies, walSamples, poolWaits []lockmetrics.Event
	r.Procs = buildProcs(p.Events, from, now)
	for _, e := range p.Events {
		if e.TS.Before(from) || e.TS.After(now) {
			continue
		}
		r.Window.Events++
		if e.Site == "" {
			e.Site = unknownSite
		}
		switch e.Kind {
		case lockmetrics.KindTx:
			holds = append(holds, e)
		case lockmetrics.KindExec:
			execs = append(execs, e)
		case lockmetrics.KindBusy:
			busies = append(busies, e)
		case lockmetrics.KindWAL:
			walSamples = append(walSamples, e)
		case lockmetrics.KindPoolWait:
			poolWaits = append(poolWaits, e)
		}
	}
	// Events from two files and several processes are not globally ordered.
	byTS := func(a, b lockmetrics.Event) int { return a.TS.Compare(b.TS) }
	slices.SortStableFunc(holds, byTS)
	slices.SortStableFunc(execs, byTS)
	slices.SortStableFunc(busies, byTS)
	slices.SortStableFunc(walSamples, byTS)

	r.Sites = buildSites(holds)
	r.ExecSites = buildExecSites(execs)
	r.Busy = buildBusyGroups(busies)
	r.BusyHolders = buildBusyHolders(busies, holds, execs)
	r.WAL = buildWAL(walSamples)
	r.PoolWait = buildPoolWaits(poolWaits)
	return r
}

func buildSites(holds []lockmetrics.Event) []Site {
	idx := map[string]int{}
	sites := []Site{}
	for _, e := range holds {
		i, ok := idx[e.Site]
		if !ok {
			i = len(sites)
			idx[e.Site] = i
			sites = append(sites, Site{Site: e.Site})
		}
		s := &sites[i]
		s.Count++
		s.TotalHoldMS += e.HoldMS
		s.MaxHoldMS = max(s.MaxHoldMS, e.HoldMS)
		s.MaxWaitMS = max(s.MaxWaitMS, e.WaitMS)
		if e.HoldMS > 1000 {
			s.Over1s++
		}
		if e.HoldMS > 5000 {
			s.Over5s++
		}
	}
	sort.Slice(sites, func(i, j int) bool {
		a, b := sites[i], sites[j]
		if a.TotalHoldMS != b.TotalHoldMS {
			return a.TotalHoldMS > b.TotalHoldMS
		}
		if a.MaxHoldMS != b.MaxHoldMS {
			return a.MaxHoldMS > b.MaxHoldMS
		}
		return a.Site < b.Site
	})
	return sites
}

func buildExecSites(execs []lockmetrics.Event) []ExecSite {
	idx := map[string]int{}
	sites := []ExecSite{}
	for _, e := range execs {
		i, ok := idx[e.Site]
		if !ok {
			i = len(sites)
			idx[e.Site] = i
			sites = append(sites, ExecSite{Site: e.Site})
		}
		s := &sites[i]
		s.Count++
		s.TotalMS += e.HoldMS
		s.MaxMS = max(s.MaxMS, e.HoldMS)
	}
	sort.Slice(sites, func(i, j int) bool {
		a, b := sites[i], sites[j]
		if a.TotalMS != b.TotalMS {
			return a.TotalMS > b.TotalMS
		}
		if a.MaxMS != b.MaxMS {
			return a.MaxMS > b.MaxMS
		}
		return a.Site < b.Site
	})
	return sites
}

func buildBusyGroups(busies []lockmetrics.Event) []BusyGroup {
	type key struct{ proc, site string }
	idx := map[key]int{}
	groups := []BusyGroup{}
	for _, e := range busies {
		k := key{e.Proc, e.Site}
		i, ok := idx[k]
		if !ok {
			i = len(groups)
			idx[k] = i
			groups = append(groups, BusyGroup{Proc: e.Proc, Site: e.Site, BusyTimeoutsMS: []int64{}, Errs: []string{}})
		}
		g := &groups[i]
		g.Count++
		if !slices.Contains(g.BusyTimeoutsMS, e.BusyTimeoutMS) {
			g.BusyTimeoutsMS = append(g.BusyTimeoutsMS, e.BusyTimeoutMS)
		}
		if !slices.Contains(g.Errs, e.Err) {
			g.Errs = append(g.Errs, e.Err)
		}
	}
	for i := range groups {
		slices.Sort(groups[i].BusyTimeoutsMS)
		slices.Sort(groups[i].Errs)
	}
	sort.Slice(groups, func(i, j int) bool {
		a, b := groups[i], groups[j]
		if a.Count != b.Count {
			return a.Count > b.Count
		}
		if a.Proc != b.Proc {
			return a.Proc < b.Proc
		}
		return a.Site < b.Site
	})
	return groups
}

// buildBusyHolders pairs each busy with the tx events of other pids whose
// hold overlaps the busy's wait, and separately with the exec events of
// other pids whose wait+hold does (an exec may itself have been waiting).
//
// Timing assumption: an event's ts is when it was recorded, and the
// instrumentation records a tx/exec after COMMIT/ROLLBACK (Record stamps
// time.Now() when ts is zero), so a hold ran [ts-hold_ms, ts]; a busy is
// recorded when the error returns, so its wait ran [ts-wait_ms, ts] — or
// [ts-busy_timeout_ms, ts] when the writer recorded no wait_ms. Both
// intervals are closed. holds and execs must be sorted by ts.
func buildBusyHolders(busies, holds, execs []lockmetrics.Event) []BusyEvent {
	out := []BusyEvent{}
	maxHold, maxExec := maxHoldOf(holds), maxHoldOf(execs)
	for _, b := range busies {
		wait := b.WaitMS
		if wait <= 0 {
			wait = b.BusyTimeoutMS
		}
		waitStart := b.TS.Add(-ms(wait))
		be := BusyEvent{
			TS: b.TS, PID: b.PID, Proc: b.Proc, Site: b.Site, Err: b.Err,
			WaitMS: b.WaitMS, BusyTimeoutMS: b.BusyTimeoutMS,
			Holders: []Holder{}, Execs: []ExecOverlap{},
		}
		for _, h := range overlapping(b, waitStart, holds, maxHold) {
			be.Holders = append(be.Holders, Holder{
				TS: h.TS, PID: h.PID, Proc: h.Proc, Kind: h.Kind, Site: h.Site, HoldMS: h.HoldMS,
			})
		}
		for _, x := range overlapping(b, waitStart, execs, maxExec) {
			be.Execs = append(be.Execs, ExecOverlap{TS: x.TS, PID: x.PID, Proc: x.Proc, Site: x.Site, MS: x.HoldMS})
		}
		out = append(out, be)
	}
	return out
}

func maxHoldOf(events []lockmetrics.Event) time.Duration {
	var m time.Duration
	for _, e := range events {
		m = max(m, ms(e.HoldMS))
	}
	return m
}

// overlapping returns the events of pids other than b's whose
// [ts-hold_ms, ts] overlaps [waitStart, b.TS]. events are sorted by ts and
// maxHold is their longest hold_ms.
func overlapping(b lockmetrics.Event, waitStart time.Time, events []lockmetrics.Event, maxHold time.Duration) []lockmetrics.Event {
	var out []lockmetrics.Event
	// An event ending before the wait began cannot overlap it; one ending
	// after b.TS+maxHold started after the wait ended.
	i := sort.Search(len(events), func(i int) bool { return !events[i].TS.Before(waitStart) })
	for ; i < len(events) && !events[i].TS.After(b.TS.Add(maxHold)); i++ {
		h := events[i]
		if h.PID == b.PID || h.TS.Add(-ms(h.HoldMS)).After(b.TS) {
			continue
		}
		out = append(out, h)
	}
	return out
}

func ms(n int64) time.Duration { return time.Duration(n) * time.Millisecond }

func buildWAL(samples []lockmetrics.Event) WAL {
	w := WAL{Samples: len(samples)}
	if len(samples) == 0 {
		return w
	}
	sizes := make([]int64, len(samples))
	for i, e := range samples {
		sizes[i] = e.WALBytes
		if e.Checkpoint == "" {
			continue
		}
		var busy, log, ckpt int64
		if _, err := fmt.Sscanf(e.Checkpoint, "busy=%d log=%d ckpt=%d", &busy, &log, &ckpt); err != nil {
			w.CheckpointUnparsed++
			continue
		}
		w.Checkpoints++
		w.LastCheckpoint = e.Checkpoint
		if busy != 0 {
			w.CheckpointBusy++
		}
		if ckpt < log {
			w.CheckpointIncomplete++
		}
	}
	slices.Sort(sizes)
	w.MinBytes, w.MaxBytes = sizes[0], sizes[len(sizes)-1]
	if n := len(sizes); n%2 == 1 {
		w.MedianBytes = sizes[n/2]
	} else {
		w.MedianBytes = (sizes[n/2-1] + sizes[n/2]) / 2
	}
	return w
}

func buildPoolWaits(events []lockmetrics.Event) []PoolWait {
	idx := map[string]int{}
	out := []PoolWait{}
	for _, e := range events {
		i, ok := idx[e.Proc]
		if !ok {
			i = len(out)
			idx[e.Proc] = i
			out = append(out, PoolWait{Proc: e.Proc})
		}
		p := &out[i]
		p.Count++
		p.TotalWaitMS += e.WaitMS
		p.MaxWaitMS = max(p.MaxWaitMS, e.WaitMS)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TotalWaitMS != out[j].TotalWaitMS {
			return out[i].TotalWaitMS > out[j].TotalWaitMS
		}
		return out[i].Proc < out[j].Proc
	})
	return out
}

func buildProcs(events []lockmetrics.Event, from, now time.Time) []ProcLast {
	idx := map[string]int{}
	out := []ProcLast{}
	for _, e := range events {
		i, ok := idx[e.Proc]
		if !ok {
			i = len(out)
			idx[e.Proc] = i
			out = append(out, ProcLast{Proc: e.Proc})
		}
		p := &out[i]
		if e.TS.After(p.LastTS) {
			p.LastTS = e.TS
		}
		if !e.TS.Before(from) && !e.TS.After(now) {
			p.Events++
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Proc < out[j].Proc })
	return out
}
