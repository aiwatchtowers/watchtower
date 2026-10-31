package state

import (
	"slices"
	"strings"
	"testing"
)

// Column classes of the sidecar's text and blob columns (spec §8 p. 4a: new
// columns hold no content; anything with content is sealed or not stored).
const (
	classID         = "id"              // a record, device, row or upload id; a mailbox or path built from ids
	classTimestamp  = "timestamp"       // a time
	classHash       = "hash"            // a digest or keyed wire name
	classErrorClass = "error_class"     // an error class, never error text
	classEnum       = "enum"            // a fixed vocabulary
	classPublicKey  = "public_key"      // a phone's public key
	classSealed     = "sealed"          // an envelope or a SealLocal blob (identity in the clear at most)
	classPlaintext  = "plaintext_today" // readable text, today's two columns only
	classLabel      = "label"           // the owner's own phone or hub name, model; never source content
	// classLinkSecret is a link nonce, confirm nonce or four-digit code of a
	// pairing: a request's row goes when it ends
	// (link.TestLinkSecretsGoWhenTheRequestEnds); devices.link_nonce (an input
	// of the relay keys) and link_codes.nonce (the code's identity) stay.
	classLinkSecret = "link_secret"
	classPerKey     = "per_key"    // hub_meta.value: classed per key (hub's canary test pins the keys)
	classSwiftOnly  = "swift_only" // written only by the Swift hub; Go never writes it (the hub canary asserts them empty)
)

// sidecarColumns maps every TEXT/BLOB (or untyped) column of a migrated
// sidecar to its class. A new column missing here fails
// TestSidecarHasNoNewUnsealedContentColumns, so content cannot land
// unsealed by accident.
var sidecarColumns = map[string]string{
	"goose_db_version.tstamp": classTimestamp,

	"slice_state.record_name":  classID,
	"slice_state.payload_hash": classHash,
	"slice_state.wire_name":    classHash,

	"hub_meta.key":   classEnum,
	"hub_meta.value": classPerKey,

	"work_alerts.key": classID, // "<kind>:<id>"

	"relay_processed.record_name": classID,
	"relay_processed.phase":       classEnum,
	"relay_processed.outcome":     classEnum,
	"relay_processed.echo":        classPlaintext,

	"ask_answer_deliveries.record_name": classID,
	"ask_answer_deliveries.delivery":    classEnum,

	"phone_recordings.upload_id":  classID,
	"phone_recordings.audio_path": classSwiftOnly,
	"phone_recordings.status":     classEnum,
	"phone_recordings.error":      classSwiftOnly,

	"session_reports.payload": classSealed,

	"session_milestones.kind": classEnum,
	"session_milestones.text": classSealed,

	"held_session_lines.record_name": classID,
	"held_session_lines.action":      classSealed, // identity in the clear, params SealLocal
	"held_session_lines.line":        classPlaintext,
	"held_session_lines.launch":      classTimestamp,
	"held_session_lines.reason":      classEnum,

	"link_codes.nonce":          classLinkSecret,
	"link_codes.used_by_device": classID,

	"devices.device_id":        classID,
	"devices.name":             classLabel,
	"devices.scope":            classEnum,
	"devices.user_record_name": classID,
	"devices.signing_key":      classPublicKey,
	"devices.agreement_key":    classPublicKey,
	"devices.link_nonce":       classLinkSecret,
	"devices.relay_device_id":  classID,

	"link_refusals.device_id":     classID,
	"link_refusals.name":          classLabel,
	"link_refusals.scope":         classEnum,
	"link_refusals.reason":        classEnum,
	"link_refusals.agreement_key": classPublicKey,

	"hub_epochs.sealed_keys": classSealed,

	"pending_devices.device_id":        classID,
	"pending_devices.name":             classLabel,
	"pending_devices.model":            classLabel,
	"pending_devices.scope":            classEnum,
	"pending_devices.user_record_name": classID,
	"pending_devices.signing_key":      classPublicKey,
	"pending_devices.agreement_key":    classPublicKey,
	"pending_devices.link_nonce":       classLinkSecret,
	"pending_devices.sas":              classLinkSecret,
	"pending_devices.confirm_nonce":    classLinkSecret,
	"pending_devices.relay_device_id":  classID,

	"revoked_devices.device_id":     classID,
	"revoked_devices.agreement_key": classPublicKey,
	"revoked_devices.name":          classLabel,
	"revoked_devices.scope":         classEnum,

	"relay_seen.wire_name": classHash,
	"relay_seen.sender_id": classID,

	// The Swift hub's staged-asset descriptors (K_asset, header, digest);
	// the Go hub stages none here.
	"slice_assets.file_path":  classSwiftOnly,
	"slice_assets.descriptor": classSwiftOnly,

	"control_queue.mailbox":          classID,
	"control_queue.record_name":      classID,
	"control_queue.kind":             classEnum,
	"control_queue.envelope":         classSealed,
	"control_queue.expect":           classEnum,
	"control_queue.last_error_class": classErrorClass,

	"held_actions.device_id":   classID,
	"held_actions.record_name": classID,
	"held_actions.envelope":    classSealed,

	"zone_tokens.zone": classID,

	"recording_jobs.upload_id":   classID,
	"recording_jobs.device_id":   classID,
	"recording_jobs.status":      classEnum,
	"recording_jobs.error_class": classErrorClass,
}

// textual reports whether a declared column type may hold text or bytes
// (SQLite's TEXT and BLOB affinities, and no type at all).
func textual(declared string) bool {
	t := strings.ToUpper(declared)
	if t == "" {
		return true
	}
	for _, s := range []string{"CHAR", "CLOB", "TEXT", "BLOB"} {
		if strings.Contains(t, s) {
			return true
		}
	}
	return t == "TIMESTAMP" || t == "DATETIME" // NUMERIC affinity, but goose writes text
}

// TestSidecarHasNoNewUnsealedContentColumns (spec §8 p. 4a, §13 E2E (1)):
// every text or blob column of a freshly migrated sidecar has a class, no
// class is stale, and the readable columns are exactly today's two.
func TestSidecarHasNoNewUnsealedContentColumns(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	rows, err := s.db.Query(`SELECT m.name, p.name, p.type FROM sqlite_master m, pragma_table_info(m.name) p
		WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid`)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	seen := map[string]bool{}
	for rows.Next() {
		var table, col, typ string
		if err := rows.Scan(&table, &col, &typ); err != nil {
			t.Fatal(err)
		}
		key := table + "." + col
		_, listed := sidecarColumns[key]
		if !textual(typ) {
			if listed {
				t.Errorf("%s is %s, not text or blob: drop it from the allowlist", key, typ)
			}
			continue
		}
		seen[key] = true
		if !listed {
			t.Errorf("%s (%s) has no class: seal its content (SealLocal) or classify it as no content", key, typ)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	var plaintext []string
	for key, class := range sidecarColumns {
		if !seen[key] {
			t.Errorf("%s is in the allowlist but not in the sidecar", key)
		}
		if class == classPlaintext {
			plaintext = append(plaintext, key)
		}
	}
	slices.Sort(plaintext)
	if want := []string{"held_session_lines.line", "relay_processed.echo"}; !slices.Equal(plaintext, want) {
		t.Errorf("plaintext_today columns %v, want exactly %v", plaintext, want)
	}
}
