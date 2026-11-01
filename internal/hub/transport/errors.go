package transport

import "errors"

// Transport errors (RC §7's mapping of the relay's error codes). Callers test
// them with errors.Is; implementations wrap them with their own detail.
var (
	// ErrTokenExpired: a Changes cursor is no longer kept or was never
	// issued; reset the zone's cursor to 0 and pull again (no login).
	ErrTokenExpired = errors.New("transport: change token expired")
	// ErrUnavailable: the transport cannot be reached or could not finish
	// the op yet; retry later.
	ErrUnavailable = errors.New("transport: unavailable")
	// ErrEntitlementInactive: the phone's subscription is not active.
	ErrEntitlementInactive = errors.New("transport: entitlement inactive")
	// ErrForbidden: this device may not touch that zone or attachment.
	ErrForbidden = errors.New("transport: forbidden")
	// ErrHubQuota: the hub's data zone is over its quota.
	ErrHubQuota = errors.New("transport: hub quota exceeded")
	// ErrMailboxQuota: a mailbox or pairing zone is over its quota.
	ErrMailboxQuota = errors.New("transport: mailbox quota exceeded")
	// ErrRecordTooLarge: a record exceeds the transport's size limit.
	ErrRecordTooLarge = errors.New("transport: record too large")
	// ErrUnsupportedVersion: the server no longer speaks this protocol.
	ErrUnsupportedVersion = errors.New("transport: unsupported protocol version")
	// ErrUnsupportedZone: the zone has no place on this transport (a
	// pairing zone on CloudKit, where linking runs over shares).
	ErrUnsupportedZone = errors.New("transport: zone not supported on this transport")
	// ErrRateLimited: too many requests; back off.
	ErrRateLimited = errors.New("transport: rate limited")
)
