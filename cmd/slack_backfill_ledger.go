package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
)

// slackBackfillLedgerFile keeps, per Slack account and UTC day, what
// `slack backfill` decided at its first run over that day: which channels a
// digest had already covered before its fetch, and whether the day's daily
// rollup still has to be rebuilt. A rerun (after a rate limit, a held digest
// lock, a failed AI call) must decide the same way, and by then the earlier
// run's own fetch has stored the messages the first decision looked for, so
// the decision cannot be recomputed. Ids and dates only, no content.
const slackBackfillLedgerFile = "slack_backfill_ledger.json"

// backfillLedgerDay is one account day's frozen decision.
type backfillLedgerDay struct {
	Covered       []string `json:"covered"`        // channels whose day a digest had covered; never digested again
	RollupPending bool     `json:"rollup_pending"` // a digest was written, the rollup not rebuilt yet
}

type backfillLedger struct {
	path string
	Days map[string]*backfillLedgerDay `json:"days"` // key "<account>:<YYYY-MM-DD UTC>"
}

func loadBackfillLedger(workspaceDir string) (*backfillLedger, error) {
	l := &backfillLedger{path: filepath.Join(workspaceDir, slackBackfillLedgerFile), Days: map[string]*backfillLedgerDay{}}
	b, err := os.ReadFile(l.path)
	if errors.Is(err, fs.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the slack backfill ledger: %w", err)
	}
	if err := json.Unmarshal(b, l); err != nil {
		return nil, fmt.Errorf("reading the slack backfill ledger: %w", err)
	}
	if l.Days == nil {
		l.Days = map[string]*backfillLedgerDay{}
	}
	return l, nil
}

func backfillLedgerKey(accountID int64, day string) string {
	return strconv.FormatInt(accountID, 10) + ":" + day
}

// save writes the ledger through a temporary file and a rename, so a crash
// never leaves half a file.
func (l *backfillLedger) save() error {
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	tmp := l.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("writing the slack backfill ledger: %w", err)
	}
	if err := os.Rename(tmp, l.path); err != nil {
		return fmt.Errorf("writing the slack backfill ledger: %w", err)
	}
	return nil
}
