package state

import (
	"database/sql"
	"fmt"
	"time"
)

// StoredReport is one session_reports row: a session's last good capped
// report. Payload is the stored value as is: the Go hub writes it sealed
// (identity.Keyring SealLocal, label "session_reports.payload"); an adopted
// Swift sidecar may hold plaintext rows, which the caller deletes.
type StoredReport struct {
	SessionID int64
	Payload   []byte
	FetchedAt time.Time
}

// SessionReports returns every stored report, by session id.
func SessionReports(tx *sql.Tx) ([]StoredReport, error) {
	rows, err := tx.Query(`SELECT session_id, payload, fetched_at FROM session_reports ORDER BY session_id`)
	if err != nil {
		return nil, fmt.Errorf("reading session reports: %w", err)
	}
	defer rows.Close()
	var out []StoredReport
	for rows.Next() {
		var (
			r  StoredReport
			at float64
		)
		if err := rows.Scan(&r.SessionID, &r.Payload, &at); err != nil {
			return nil, fmt.Errorf("reading session reports: %w", err)
		}
		r.FetchedAt = fromReal(at)
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading session reports: %w", err)
	}
	return out, nil
}

// SaveSessionReport stores sessionID's report, replacing the previous one;
// payload must already be sealed.
func SaveSessionReport(tx *sql.Tx, sessionID int64, payload []byte, at time.Time) error {
	if _, err := tx.Exec(`INSERT INTO session_reports (session_id, payload, fetched_at) VALUES (?, ?, ?)
		ON CONFLICT (session_id) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at`,
		sessionID, payload, toReal(at)); err != nil {
		return fmt.Errorf("storing a session report: %w", err)
	}
	return nil
}

// DeleteSessionReport removes sessionID's stored report.
func DeleteSessionReport(tx *sql.Tx, sessionID int64) error {
	if _, err := tx.Exec(`DELETE FROM session_reports WHERE session_id = ?`, sessionID); err != nil {
		return fmt.Errorf("deleting a session report: %w", err)
	}
	return nil
}

// KeepSessionReports drops the stored reports of every session not in
// keeping (HubSyncState.removeSessionReports(keeping:)).
func KeepSessionReports(tx *sql.Tx, keeping map[int64]bool) error {
	ids, err := sessionReportIDs(tx)
	if err != nil {
		return err
	}
	for _, id := range ids {
		if keeping[id] {
			continue
		}
		if err := DeleteSessionReport(tx, id); err != nil {
			return err
		}
	}
	return nil
}

// sessionReportIDs is every session with a stored report.
func sessionReportIDs(tx *sql.Tx) ([]int64, error) {
	rows, err := tx.Query(`SELECT session_id FROM session_reports`)
	if err != nil {
		return nil, fmt.Errorf("reading session reports: %w", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("reading session reports: %w", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading session reports: %w", err)
	}
	return ids, nil
}
