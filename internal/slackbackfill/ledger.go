package slackbackfill

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"

	"watchtower/internal/fsutil"
)

// LedgerFile keeps, per Slack account and UTC day, what `slack backfill`
// decided before its first fetch over that day: which channel digests
// overlapping the day had seen none of its messages (a forward digest that
// spans a sync gap), the highest digest id then, and whether the day's
// daily rollup still has to be rebuilt. A rerun (after a rate limit, a held digest lock, a failed AI call)
// must decide the same way, and by then an earlier run's fetch — with digests
// on or off — has stored the messages the decision looked for, so it cannot
// be recomputed. Ids and dates only, no content.
//
// An account purge (PURGE-02) deletes the account's digests and messages but
// not this file: a day decided before the account's latest finished purge is
// decided again from what the database holds then (Run.freeze), so the file
// needs no purge step.
const LedgerFile = "slack_backfill_ledger.json"

// ledgerDay is one account day's frozen decision.
type ledgerDay struct {
	// Excluded are the channel digests overlapping the day that held none of
	// its messages before the first fetch: their periods do not count as
	// covering the day.
	Excluded []int64 `json:"excluded"`
	// DigestIDMax is the highest digest id when the day was decided; a
	// digest above it was written later (coverage.go has the rule).
	DigestIDMax   int64  `json:"digest_id_max"`
	RollupPending bool   `json:"rollup_pending"` // digests may have been written, the rollup not rebuilt yet
	DecidedAt     string `json:"decided_at"`     // RFC 3339 UTC
}

// Ledger is the loaded LedgerFile. A command holds LockLedger from Load to
// its last save.
type Ledger struct {
	path string
	Days map[string]*ledgerDay `json:"days"` // key "<account>:<YYYY-MM-DD UTC>"
}

// ErrRunning refuses a second `slack backfill` while one runs in the
// workspace: each holds the ledger from load to its last save, and two would
// overwrite each other's decisions.
var ErrRunning = errors.New("another `watchtower slack backfill` is running in this workspace; run this one after it")

// LockLedger takes the workspace's ledger lock for the whole command. A lock
// another run holds is ErrRunning; any other failure is returned as itself.
func LockLedger(workspaceDir string) (release func(), err error) {
	unlock, ok, err := fsutil.TryLockFile(filepath.Join(workspaceDir, LedgerFile+".lock"))
	if err != nil {
		return nil, fmt.Errorf("locking the slack backfill ledger: %w", err)
	}
	if !ok {
		return nil, ErrRunning
	}
	return unlock, nil
}

// LoadLedger reads the workspace's ledger; a missing file is an empty one.
func LoadLedger(workspaceDir string) (*Ledger, error) {
	l := &Ledger{path: filepath.Join(workspaceDir, LedgerFile), Days: map[string]*ledgerDay{}}
	b, err := os.ReadFile(l.path)
	if errors.Is(err, fs.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the slack backfill ledger %s: %w", l.path, err)
	}
	if err := json.Unmarshal(b, l); err != nil {
		return nil, fmt.Errorf("the slack backfill ledger %s is unreadable; deleting it lets the next run decide its days again, "+
			"but a day an earlier run already fetched may then keep undigested messages: %w", l.path, err)
	}
	if l.Days == nil {
		l.Days = map[string]*ledgerDay{}
	}
	return l, nil
}

func ledgerKey(accountID int64, day string) string {
	return strconv.FormatInt(accountID, 10) + ":" + day
}

// save writes the ledger atomically.
func (l *Ledger) save() error {
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	if err := fsutil.WriteFileAtomic(l.path, b, 0o600); err != nil {
		return fmt.Errorf("writing the slack backfill ledger: %w", err)
	}
	return nil
}
