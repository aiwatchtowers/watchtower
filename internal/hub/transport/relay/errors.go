package relay

import (
	"context"
	"errors"
	"fmt"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// Errors of the hosted relay that the neutral transport errors do not cover.
// The attestation errors also match transport.ErrForbidden: until the relay
// admits hubs by a phone's vouch (Go hub design §7, relay ask #805) a hub that
// registers as a Mac without App Attest is simply not let in.
var (
	// ErrAttestationRequired: the relay wants an attestation this hub cannot
	// give (attestation is on and the hub is not exempt). Do not retry in a
	// loop.
	ErrAttestationRequired = fmt.Errorf("relay: attestation required: %w", transport.ErrForbidden)
	// ErrAttestationFailed: the relay refused the hub's attestation.
	ErrAttestationFailed = fmt.Errorf("relay: attestation failed: %w", transport.ErrForbidden)
	// ErrSlotLimit: the account's slots (or its replacements) are used up.
	ErrSlotLimit = errors.New("relay: slot limit reached")
)

// MapError maps an error of the relay client to the transport errors (RC §7),
// keeping the client's error in the chain (client.Code still reads it). A
// protocol error the transport has no class for comes back wrapped as is; a
// failure to reach the relay (no answer, a dropped connection) is
// transport.ErrUnavailable; a cancelled or expired context is returned
// unchanged.
func MapError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	if errors.Is(err, client.ErrUnsupportedVersion) {
		return fmt.Errorf("%w: %w", transport.ErrUnsupportedVersion, err)
	}
	var pe *client.Error
	if !errors.As(err, &pe) {
		return fmt.Errorf("%w: %w", transport.ErrUnavailable, err)
	}
	if class := classOf(pe.E.GetCode()); class != nil {
		return fmt.Errorf("%w: %w", class, err)
	}
	return fmt.Errorf("relay: %w", err)
}

// classOf is the transport error class of a relay error code, or nil.
func classOf(code relayv1.ErrorCode) error {
	switch code {
	case relayv1.ErrorCode_ERROR_CODE_UNSUPPORTED_VERSION:
		return transport.ErrUnsupportedVersion
	case relayv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, relayv1.ErrorCode_ERROR_CODE_FORBIDDEN:
		// UNAUTHENTICATED reaches us only after the client's own new login was
		// refused too: the relay does not accept this hub's key.
		return transport.ErrForbidden
	case relayv1.ErrorCode_ERROR_CODE_TOKEN_EXPIRED:
		return transport.ErrTokenExpired
	case relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, relayv1.ErrorCode_ERROR_CODE_ATTACHMENT_TOO_LARGE:
		return transport.ErrRecordTooLarge
	case relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED:
		return transport.ErrHubQuota
	case relayv1.ErrorCode_ERROR_CODE_MAILBOX_QUOTA_EXCEEDED:
		return transport.ErrMailboxQuota
	case relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, relayv1.ErrorCode_ERROR_CODE_TRAFFIC_LIMIT_EXCEEDED:
		return transport.ErrRateLimited
	case relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE:
		return transport.ErrEntitlementInactive
	case relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE:
		return transport.ErrUnavailable
	case relayv1.ErrorCode_ERROR_CODE_ATTESTATION_REQUIRED:
		return ErrAttestationRequired
	case relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED:
		return ErrAttestationFailed
	case relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT, relayv1.ErrorCode_ERROR_CODE_SLOT_REPLACEMENT_LIMIT:
		return ErrSlotLimit
	default:
		return nil
	}
}
