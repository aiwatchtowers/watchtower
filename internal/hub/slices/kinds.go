// Package slices is the Go hub's slice publisher (spec §9): it diffs each
// DataZone slice against the payload hashes last pushed (state.slice_state),
// seals what changed through secure.Sealer, saves it on the transport and
// deletes the records that left the slice. Plan 1a ships the core with the
// two hub-own slices, device_grant and heartbeat; Plan 1b adds the database
// sources behind the same Source seam and calls PublishSoon on change.
package slices

import "slices"

// Kind is a raw value of the Kit's SliceKind ("device_grant", "heartbeat",
// "owner_ask", …): a record of kind k is named "<k>-<id>", the heartbeat
// alone is named "heartbeat".
type Kind string

// The kinds the hub's own code names.
const (
	KindDeviceGrant Kind = "device_grant"
	KindHeartbeat   Kind = "heartbeat"
	KindAskAlert    Kind = "ask_alert"
	KindSessionChat Kind = "session_chat"
)

// AllKinds is the Kit's SliceKind.allCases, in its order. A new Kit kind is
// added here and in secure's dataKinds in the same change.
var AllKinds = []Kind{
	"briefing", "inbox_item", "target", "track", "digest", "digest_topic", "calendar_event", "person_card",
	"situation", "meeting_transcript", "day_plan", "day_plan_item", "feature_state", "stream_digest",
	"slack_account", "google_account", "jira_account", KindHeartbeat, KindDeviceGrant, "recording_job",
	"workbench", "workbench_target", "workbench_comment", "terminal_session", "owner_ask", "session_report",
	"session_timeline", KindAskAlert, "permission_request", KindSessionChat,
}

// UrgentKinds is what the owner waits for at once (the Swift hub's
// urgentKinds): a cycle diffs them before every other kind.
var UrgentKinds = []Kind{"owner_ask", KindAskAlert, KindDeviceGrant, "permission_request", KindSessionChat}

// UnlinkedKinds is all a cycle publishes while no phone is linked: the link
// flow's answer.
var UnlinkedKinds = []Kind{KindDeviceGrant}

// publishOrder is the order a cycle diffs kinds in (the Swift publishOrder):
// the urgent kinds in AllKinds order with the near-live session chat after
// the ask kinds, then the rest in AllKinds order.
var publishOrder = func() []Kind {
	var urgent, rest []Kind
	for _, k := range AllKinds {
		switch {
		case k == KindSessionChat:
		case slices.Contains(UrgentKinds, k):
			urgent = append(urgent, k)
		default:
			rest = append(rest, k)
		}
	}
	return append(append(urgent, KindSessionChat), rest...)
}()

// recordName is the plain record name of kind's item id: "<kind>-<id>", and
// "heartbeat" for the heartbeat, whose id must be empty. ok is false for an
// empty id of any other kind and a non-empty heartbeat id: neither names a
// record the phone reads.
func recordName(k Kind, id string) (string, bool) {
	if k == KindHeartbeat {
		return string(k), id == ""
	}
	return string(k) + "-" + id, id != ""
}
