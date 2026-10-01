package extsync

import (
	"context"
	"fmt"
	"strconv"
	"strings"
)

// A degraded outcome (a transient failure, or OCR that could not run) on a
// row that already has text keeps that row's content — text and version —
// so search keeps the last good text. The version that was tried is kept
// beside it, in meta_json under pendingVersionKey (the knowledge index
// reads only named meta keys, never this one; no schema change needed):
//   - the delta stream re-lists every changed ref inside its cursor
//     overlap (1 minute here, 24 hours in the Confluence CQL); without the
//     marker the stored (old) version would mismatch the listed one and the
//     stream would re-download the row on every pass with no cap;
//   - with it, a listed version equal to the pending one is not stale: its
//     retries belong to revisitAttachments, which re-fetches the CURRENT
//     remote version and stops at maxExtractAttempts;
//   - a listed version newer than the pending one is stale again and gets
//     a fresh budget; a success rewrites meta_json and drops the marker.
const pendingVersionKey = "pending_version"

// staleAttachmentRefs is staleRefs for attachments: a ref is stale when its
// version differs from the stored one and from the stored pending one.
func staleAttachmentRefs(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef) ([]ItemRef, error) {
	known, err := attachmentVersions(ctx, q, sourceID, refs)
	if err != nil {
		return nil, err
	}
	var stale []ItemRef
	for _, r := range refs {
		v, ok := known[r.ExtID]
		if !ok || (v.stored != r.Version && v.pending != r.Version) {
			stale = append(stale, r)
		}
	}
	return stale, nil
}

// attachmentVersion is a stored attachment's version, the version its
// pending retry tried (0 = none) and its attempt count.
type attachmentVersion struct{ stored, pending, attempts int }

// lastTry reports whether a degraded try of version spends the row's last
// attempt on a version other than the stored one. Only a revisit counts on
// from the stored attempts; a delta try of a newly listed version starts
// at 1.
func (v attachmentVersion) lastTry(version int, revisit bool) bool {
	return revisit && version != v.stored && v.attempts+1 >= maxExtractAttempts
}

// attachmentVersions reads the stored and pending versions and the attempt
// counts of refs in one query.
func attachmentVersions(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef) (map[string]attachmentVersion, error) {
	out := make(map[string]attachmentVersion, len(refs))
	if len(refs) == 0 {
		return out, nil
	}
	args := make([]any, 0, len(refs)+2)
	args = append(args, "$."+pendingVersionKey, sourceID)
	for _, r := range refs {
		args = append(args, r.ExtID)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(refs)), ",")
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, COALESCE(json_extract(meta_json, ?), ''), extract_attempts
		FROM ext_documents WHERE source_id = ? AND ext_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading attachment versions: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, pending string
		var v attachmentVersion
		if err := rows.Scan(&id, &v.stored, &pending, &v.attempts); err != nil {
			return nil, fmt.Errorf("extsync: scanning attachment version: %w", err)
		}
		v.pending, _ = strconv.Atoi(pending) // absent or malformed = no pending version
		out[id] = v
	}
	return out, rows.Err()
}

// recordAttempt records a degraded outcome (failed or ocr_pending) for the
// tried version: it counts the attempt — the first try of a newly listed
// version (fresh) starts a new budget at 1, a revisit retry adds one — and
// marks the tried version pending unless the row already stores it. A row
// with 0 < attempts < maxExtractAttempts is retried by revisitAttachments.
func recordAttempt(ctx context.Context, q Queryer, sourceID int64, extID, status string, tried int, fresh bool) error {
	path := "$." + pendingVersionKey
	if _, err := q.ExecContext(ctx, `UPDATE ext_documents SET extract_status = ?,
		extract_attempts = CASE WHEN ? THEN 1 ELSE extract_attempts + 1 END,
		meta_json = CASE WHEN version = ? THEN json_remove(meta_json, ?) ELSE json_set(meta_json, ?, ?) END
		WHERE source_id = ? AND ext_id = ?`,
		status, fresh, tried, path, path, strconv.Itoa(tried), sourceID, extID); err != nil {
		return fmt.Errorf("extsync: recording %s extraction of %s: %w", status, extID, err)
	}
	return nil
}
