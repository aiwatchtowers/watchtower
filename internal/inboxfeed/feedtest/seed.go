// Package feedtest seeds an Inbox of the size the speed gates are measured
// on (plan Global Constraints: 2 000 outputs, 200 approvals, 500 open
// items, 30 folders), for BenchmarkInboxFeedBuild and the socket
// round-trip benchmark. Test-only: nothing outside tests imports it.
package feedtest

import (
	"database/sql"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// The gate fixture's size.
const (
	Outputs   = 2000
	Approvals = 200
	OpenItems = 500
	Folders   = 30
)

// SeedGate writes the gate fixture into d in one transaction: Folders owner
// folders (ten top-level, each with two levels below), Outputs open inbox
// outputs over five automations (every fourth one a living card whose block
// document's rows point at open items), Approvals pending proposals and
// OpenItems open messages. now dates the rows.
func SeedGate(d *db.DB, now time.Time) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := seed(tx, now); err != nil {
		return err
	}
	return tx.Commit()
}

func seed(tx *sql.Tx, now time.Time) error {
	at := func(minutes int) string {
		return now.Add(-time.Duration(minutes) * time.Minute).UTC().Format(time.RFC3339)
	}
	exec := func(q string, args ...any) error {
		if _, err := tx.Exec(q, args...); err != nil {
			return fmt.Errorf("feedtest: %s: %w", q, err)
		}
		return nil
	}
	var folders []int64
	for i := range Folders {
		parent := "(SELECT id FROM inbox_folders WHERE kind = 'root')"
		if i%3 != 0 {
			parent = fmt.Sprintf("%d", folders[len(folders)-1])
		}
		res, err := tx.Exec(fmt.Sprintf(`INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
			VALUES ('owner', %s, ?, ?, ?)`, parent), fmt.Sprintf("folder-%d", i), fmt.Sprintf("Folder %d", i), i)
		if err != nil {
			return fmt.Errorf("feedtest: folder %d: %w", i, err)
		}
		id, _ := res.LastInsertId()
		folders = append(folders, id)
	}
	for a := 1; a <= 5; a++ {
		if err := exec(`INSERT INTO automations (id, slug, scope, path, name, enabled) VALUES (?, ?, 'personal', ?, ?, 1)`,
			a, fmt.Sprintf("auto-%d", a), fmt.Sprintf("/recipes/auto-%d.md", a), fmt.Sprintf("Automation %d", a)); err != nil {
			return err
		}
		if err := exec(`INSERT INTO automation_runs (id, automation_id, trigger, status) VALUES (?, ?, 'manual', 'succeeded')`, a, a); err != nil {
			return err
		}
	}
	for i := 1; i <= OpenItems; i++ {
		if err := exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, created_at)
			VALUES (?, 'C1', ?, 'U1', 'mention', ?)`, i, fmt.Sprintf("%d.0", i), at(i)); err != nil {
			return err
		}
	}
	for i := 1; i <= Outputs; i++ {
		automation := i%5 + 1
		var folder any
		if i%2 == 0 {
			folder = folders[i%Folders]
		}
		blocks, key := "", any(nil)
		if i%4 == 0 {
			item := i%OpenItems + 1
			blocks = fmt.Sprintf(`{"v":1,"blocks":[{"type":"list","rows":[{"title":"Item %d","ref":{"kind":"inbox_item","id":%d}}]}]}`, item, item)
			key = fmt.Sprintf("key-%d", i)
		}
		if err := exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, created_at,
				blocks_json, output_key, written_at, changed_at, folder_id)
			VALUES (?, ?, 'inbox', ?, ?, ?, ?, ?, ?, ?, ?)`,
			automation, automation, fmt.Sprintf("Card %d", i),
			fmt.Sprintf("Card %d: **something** happened in the [project](https://example.com/%d).", i, i),
			at(i), blocks, key, at(i), at(i), folder); err != nil {
			return err
		}
	}
	for i := 1; i <= Approvals; i++ {
		if err := exec(`INSERT INTO agent_actions (tool, args_json, reason, status, created_at)
			VALUES ('create_target', '{"text":"Follow up"}', 'Follow up', 'pending', ?)`, at(i)); err != nil {
			return err
		}
	}
	return nil
}
