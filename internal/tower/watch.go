package tower

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"slices"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// PollInterval is the data_version poll's cadence while a watch is open.
const PollInterval = 250 * time.Millisecond

// subscriberBuffer is each watch's queue of events. A publish never blocks:
// when the queue is full the event is dropped, which loses nothing, because
// a queued event already makes the client read again after the dropped
// write committed.
const subscriberBuffer = 16

// pollBusy is how long a data_version read waits for another process's lock.
const pollBusy = time.Second

// Changes is the daemon's change watch, independent of the hub. A write made
// through Tower.Call publishes its command's ChangeTables at commit
// (Options.Changes). Writes by other processes are seen by a PRAGMA
// data_version poll every poll on a read-only handle of its own, published
// with no tables (data_version cannot tell tables apart). The poll runs only
// while at least one watch is subscribed. An own write may be seen by the
// poll too; a second read of the client is the cost.
type Changes struct {
	d    *db.DB
	poll time.Duration
	// open opens the poll's own connection and returns its close; the
	// daemon's pool has one connection, which the poll must never hold.
	open func(ctx context.Context) (*sql.Conn, func(), error)
	// readVersion reads data_version once (a seam: tests count the reads).
	readVersion func(ctx context.Context, c *sql.Conn) (int64, error)

	mu       sync.Mutex
	subs     map[*subscriber]struct{}
	stopPoll func() // non-nil while the poll runs
}

type subscriber struct {
	ch     chan api.ChangedEvent
	filter []string
}

// NewChanges returns a change watch over d whose poll reads data_version
// every poll while a watch is open.
func NewChanges(d *db.DB, poll time.Duration) *Changes {
	c := &Changes{d: d, poll: poll, subs: map[*subscriber]struct{}{}, readVersion: readDataVersion}
	c.open = c.openPollConn
	return c
}

// Publish delivers a changed event with tables to every watch whose filter
// they meet; nil tables reach every watch. It never blocks.
func (c *Changes) Publish(tables []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for s := range c.subs {
		if !meets(s.filter, tables) {
			continue
		}
		select {
		case s.ch <- api.ChangedEvent{Event: api.EventChanged, Tables: slices.Clone(tables)}:
		default:
		}
	}
}

// meets reports whether an event over tables reaches a watch with filter:
// an event with no tables, a watch with no filter, or one table in common.
func meets(filter, tables []string) bool {
	if len(tables) == 0 || len(filter) == 0 {
		return true
	}
	for _, t := range tables {
		if slices.Contains(filter, t) {
			return true
		}
	}
	return false
}

// Subscribe opens a watch: events delivers each event whose tables meet
// filter, or that has none (a nil filter takes every event). cancel closes
// the watch and its channel; the last cancel stops the poll and waits for it.
func (c *Changes) Subscribe(filter []string) (events <-chan api.ChangedEvent, cancel func()) {
	s := &subscriber{ch: make(chan api.ChangedEvent, subscriberBuffer), filter: slices.Clone(filter)}
	c.mu.Lock()
	c.subs[s] = struct{}{}
	if c.stopPoll == nil {
		c.stopPoll = c.startPoll()
	}
	c.mu.Unlock()
	var once sync.Once
	return s.ch, func() {
		once.Do(func() {
			c.mu.Lock()
			delete(c.subs, s)
			close(s.ch)
			var stop func()
			if len(c.subs) == 0 {
				stop, c.stopPoll = c.stopPoll, nil
			}
			c.mu.Unlock()
			if stop != nil {
				stop()
			}
		})
	}
}

// startPoll runs the poll in a goroutine; its stop cancels it and waits.
func (c *Changes) startPoll() (stop func()) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		c.runPoll(ctx)
	}()
	return func() {
		cancel()
		<-done
	}
}

// runPoll reads data_version at once (the baseline) and then every poll
// until ctx ends, publishing an event with no tables whenever it moved. A
// failed read is logged once per run of failures and retried at the next
// tick. Without its own handle (an in-memory database, an open failure) it
// logs and returns: own writes still publish.
func (c *Changes) runPoll(ctx context.Context) {
	conn, closeConn, err := c.open(ctx)
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("tower: change watch: no data_version poll (%v); writes by other processes are not seen", err)
		}
		return
	}
	defer closeConn()
	ticker := time.NewTicker(c.poll)
	defer ticker.Stop()
	var last int64
	started, failing := false, false
	for {
		v, err := c.readVersion(ctx, conn)
		switch {
		case ctx.Err() != nil:
			return
		case err != nil:
			if !failing {
				log.Printf("tower: change watch: data_version poll failed: %v (retried)", err)
			}
			failing = true
		default:
			failing = false
			if started && v != last {
				c.Publish(nil)
			}
			last, started = v, true
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func readDataVersion(ctx context.Context, conn *sql.Conn) (int64, error) {
	var v int64
	if err := conn.QueryRowContext(ctx, `PRAGMA data_version`).Scan(&v); err != nil {
		return 0, fmt.Errorf("data_version: %w", err)
	}
	return v, nil
}

// openPollConn opens a read-only handle (db.OpenExisting) on the database's
// file and takes its one connection.
func (c *Changes) openPollConn(ctx context.Context) (*sql.Conn, func(), error) {
	path, err := mainFile(ctx, c.d)
	if err != nil {
		return nil, nil, err
	}
	r, err := db.OpenExisting(path, pollBusy)
	if err != nil {
		return nil, nil, err
	}
	conn, err := r.Conn(ctx)
	if err != nil {
		_ = r.Close()
		return nil, nil, err
	}
	return conn, func() {
		_ = conn.Close()
		_ = r.Close()
	}, nil
}

// mainFile is the file of d's main schema; an in-memory database has none.
func mainFile(ctx context.Context, d *db.DB) (string, error) {
	rows, err := d.QueryContext(ctx, `PRAGMA database_list`)
	if err != nil {
		return "", fmt.Errorf("database_list: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return "", fmt.Errorf("database_list: %w", err)
		}
		if name == "main" {
			if file == "" {
				return "", errors.New("the database is in memory")
			}
			return file, nil
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("database_list: %w", err)
	}
	return "", errors.New("the database has no main schema")
}
