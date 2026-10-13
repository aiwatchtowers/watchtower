package tools

import (
	"crypto/sha256"
	"encoding/hex"
)

// ArgsSHA256 is the lowercase hex sha256 of a row's stored args_json bytes —
// the fingerprint an approver passes to ApproveSeen (`actions approve
// --args-sha256`) to say "these are the args I was shown". The Desktop card
// computes the same digest over the AgentAction.argsJSON string it rendered.
func ArgsSHA256(argsJSON string) string {
	sum := sha256.Sum256([]byte(argsJSON))
	return hex.EncodeToString(sum[:])
}
