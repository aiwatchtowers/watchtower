package link

import (
	"crypto/ed25519"
	"crypto/rand"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// TestHeadlessLinkPayloadHasNoShares guards phone contract point 1 (go-hub
// plan 2): a headless hub's QR, as `hub pair` prints it, is relay only — no
// CloudKit share fields — and names the hub by its host name, clipped.
func TestHeadlessLinkPayloadHasNoShares(t *testing.T) {
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatalf("state.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	now := func() time.Time { return time.Unix(1_800_000_000, 0).UTC() }
	kr, err := identity.NewKeyring(id, st, now)
	if err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	hostname := "acme-" + strings.Repeat("h", wire.MaxMacNameLength)
	c := NewCenter(Config{
		Store: st, Keys: kr, Opener: secure.NewOpener(kr, kr),
		Host: HeadlessHost(hostname, pub), Clock: now, Publish: func(...string) {},
	})

	p, url, err := c.Issue()
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	parsed, err := wire.ParseLinkURL(url)
	if err != nil {
		t.Fatalf("ParseLinkURL: %v", err)
	}
	for _, lp := range []wire.LinkPayload{p, parsed} {
		if lp.Transport != wire.TransportRelay || !slices.Equal(lp.Transports, []string{wire.TransportRelay}) {
			t.Fatalf("transports: %q %q", lp.Transport, lp.Transports)
		}
		if lp.DataShare != nil || lp.RelayShare != nil {
			t.Fatalf("a headless QR carries a share: %+v", lp)
		}
		if lp.MacName != wire.ClipMacName(hostname) || len([]rune(lp.MacName)) != wire.MaxMacNameLength {
			t.Fatalf("mac_name %q", lp.MacName)
		}
		if lp.RelayDeviceID != identity.RelayDeviceID(pub) || lp.RelayAuthPub == "" {
			t.Fatalf("relay identity: %+v", lp)
		}
	}
}
