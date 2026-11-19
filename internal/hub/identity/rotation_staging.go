//go:build relaystaging

package identity

import (
	"log"
	"os"
	"time"
)

// The staging run's numbers (relay client Phase 5, ask #1077): a test host
// built with -tags relaystaging (make hub-staging) rotates its relay epoch
// every 10 minutes, or every WATCHTOWER_RELAYSTAGING_EPOCH (a Go duration),
// and keeps a retired epoch 30 minutes. No release path sets the tag
// (TestNoReleasePathSetsRelayStaging); the variable is read only here.
func init() {
	relayRotationAge = 10 * time.Minute
	if v := os.Getenv("WATCHTOWER_RELAYSTAGING_EPOCH"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			relayRotationAge = d
		} else {
			log.Printf("hub: WATCHTOWER_RELAYSTAGING_EPOCH is not a positive duration: the 10-minute epoch stays")
		}
	}
	PreviousEpochGrace = 30 * time.Minute
	log.Printf("hub: relaystaging build: relay epoch %v, retention %v", relayRotationAge, PreviousEpochGrace)
}
