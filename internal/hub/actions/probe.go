package actions

import (
	"context"
	"encoding/json"

	"watchtower/internal/hub/wire"
)

// RegisterProbe registers the link check "probe" (Swift probeOutcome):
// hub-only and idempotent, always applied. Its result names the hub
// (hub_id) and repeats the phone's params.nonce when it sent one, as today's
// hub answers it; a probe without a nonce is applied too, where the Swift hub
// failed it, so a phone or test can check the lane with a bare action.
func RegisterProbe(d *Dispatcher) {
	d.Register("probe", func(_ context.Context, r Request) Outcome {
		res := map[string]any{"hub_id": r.Hub.String()}
		var nonce string
		if raw, ok := r.Action.Params["nonce"]; ok && json.Unmarshal(raw, &nonce) == nil && nonce != "" {
			res["nonce"] = nonce
		}
		return Outcome{Status: wire.StatusApplied, Result: res}
	}, KindOptions{})
}
