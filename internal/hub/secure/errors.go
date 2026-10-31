// Package secure is the hub's E2E primitives, byte for byte with the Kit's
// WatchtowerSync/Secure (Envelope.swift, InnerFrame.swift, EnvelopeSealer.swift,
// KeyDerivation.swift, Padding.swift, ChunkedAssetCipher.swift, SeqAllocator.swift,
// RollbackGuard.swift, WireBytes.swift). The Kit's vectors in
// WatchtowerKit/Tests/Fixtures/e2e pin every rule. Nothing here logs a key.
package secure

import "errors"

// Envelope errors, one per EnvelopeError case. Failures inside the AEAD all
// collapse to ErrAuthenticationFailed: wrong key, moved record and flipped bit
// are one outcome, no detail leaks.
var (
	ErrTooShort             = errors.New("secure: envelope too short")
	ErrBadMagic             = errors.New("secure: bad magic")
	ErrUnsupportedVersion   = errors.New("secure: unsupported version")
	ErrUnsupportedSuite     = errors.New("secure: unsupported suite")
	ErrUnknownClass         = errors.New("secure: unknown envelope class")
	ErrLengthMismatch       = errors.New("secure: length mismatch")
	ErrSignatureMissing     = errors.New("secure: signature missing")
	ErrSignatureInvalid     = errors.New("secure: signature invalid")
	ErrAuthenticationFailed = errors.New("secure: authentication failed")
	ErrFrameMalformed       = errors.New("secure: frame malformed")
	ErrSignatureRequired    = errors.New("secure: signature required")
	ErrOversized            = errors.New("secure: oversized")
	ErrWrongClass           = errors.New("secure: wrong envelope class")
)

// Asset errors (AssetCipherError). A chunk that does not open is
// ErrAuthenticationFailed; a file longer than its header promises is ErrOversized.
var (
	ErrAssetBadHeader      = errors.New("secure: bad asset header")
	ErrAssetTruncated      = errors.New("secure: asset truncated")
	ErrAssetDigestMismatch = errors.New("secure: asset digest mismatch")
	ErrAssetSourceChanged  = errors.New("secure: asset source changed while sealing")
)

// ErrSeqExhausted is SeqAllocatorError.exhausted.
var ErrSeqExhausted = errors.New("secure: envelope seq exhausted")

// Sealer and Opener errors. ErrWrongHub and ErrWrongSender are the Kit's
// wrongHub / wrongSender: the AAD and signature bind the ids, these check them
// against the hub and devices this side expects.
var (
	ErrUnsealed         = errors.New("secure: record did not pass the sealer")
	ErrWrongHub         = errors.New("secure: envelope names another hub")
	ErrWrongSender      = errors.New("secure: envelope from an unexpected sender")
	ErrNameMismatch     = errors.New("secure: frame names another record")
	ErrUnknownKind      = errors.New("secure: unknown record kind")
	ErrEpochNotAccepted = errors.New("secure: relay epoch not accepted")
	ErrNoRelayKey       = errors.New("secure: no relay key opens the record")
	ErrRolledBack       = errors.New("secure: older version of a relay record")
)
