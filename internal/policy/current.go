package policy

import (
	"sync"
	"time"
)

// cacheTTL is how long Current reuses a read: cheap enough to ask per call,
// fresh enough that a changed profile applies within half a minute.
const cacheTTL = 30 * time.Second

// reader returns the forced values of Domain. The darwin+cgo build sets it to
// the CoreFoundation reader outside test binaries; tests swap it through
// SetReaderForTesting (policytest.Set), so no test reads this Mac's real
// managed preferences.
var reader = func() map[string]any { return map[string]any{} }

var now = time.Now

var cache struct {
	mu sync.Mutex
	p  Policy
	at time.Time
	ok bool
}

// Current returns the effective policy, read at most once per cacheTTL.
func Current() Policy {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	t := now()
	if cache.ok && t.Sub(cache.at) < cacheTTL && !t.Before(cache.at) {
		return cache.p
	}
	cache.p, cache.at, cache.ok = Normalize(reader()), t, true
	return cache.p
}

// SetReaderForTesting swaps the reader and drops the cache; restore puts the
// previous reader back and drops the cache again. Other packages use
// policytest.Set.
func SetReaderForTesting(r func() map[string]any) (restore func()) {
	cache.mu.Lock()
	old := reader
	reader, cache.ok = r, false
	cache.mu.Unlock()
	return func() {
		cache.mu.Lock()
		reader, cache.ok = old, false
		cache.mu.Unlock()
	}
}

// SourceAllowed reports whether the current policy allows the source.
func SourceAllowed(src string) bool { return Current().SourceAllowed(src) }

// MobileSync returns the current MobileSync mode.
func MobileSync() string { return Current().MobileSyncMode() }

// ConnectionAllowed reports whether the current policy allows the Quick
// Connection (see Policy.ConnectionAllowed).
func ConnectionAllowed(kind, rawURL, command string) bool {
	return Current().ConnectionAllowed(kind, rawURL, command)
}

// ShellAllowed reports whether the current policy allows shell() in
// automations.
func ShellAllowed() bool { return Current().ShellAllowed() }

// ProviderAllowed reports whether the current policy allows the LLM provider.
func ProviderAllowed(id string) bool { return Current().ProviderAllowed(id) }

// ClaudeAIToolsAllowed reports whether the current policy allows the main
// chat's claude.ai tools.
func ClaudeAIToolsAllowed() bool { return Current().ClaudeAIToolsAllowed() }

// PurgeRevokedData returns the current forced purge switch (#601's policy
// origin).
func PurgeRevokedData() (on, set bool) { return Current().PurgeRevokedData() }
