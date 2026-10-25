package webfetch_test

import (
	"net/netip"
	"testing"

	"watchtower/internal/media/webfetch"
)

func TestIsPublic(t *testing.T) {
	own := netip.MustParseAddr("93.184.215.99") // stands for a public address on one of our interfaces
	refused := []string{
		"127.0.0.1", "::1", "::", "10.1.2.3", "172.16.0.1", "192.168.1.1",
		"169.254.169.254", "fe80::1", "fe80::1%en0", "fc00::1", "fd12:3456::1", "100.64.0.1", "224.0.0.1",
		"0.0.0.0", "0.1.2.3", "255.255.255.255", "192.0.0.8", "198.18.0.1", "198.19.255.1",
		"240.0.0.1", "ff02::1", "::7f00:1",
		"::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254",
		"64:ff9b::7f00:1",      // NAT64 of 127.0.0.1
		"64:ff9b::a00:1",       // NAT64 of 10.0.0.1
		"64:ff9b:1::5db8:d70e", // local-use NAT64
		"2002:7f00:1::1",       // 6to4 of 127.0.0.1
		"2002:c0a8:101::1",     // 6to4 of 192.168.1.1
		"2001:0:4136:e378::1",  // Teredo
		"2001:db8::1",          // documentation
		"93.184.215.99",        // own interface
		"::ffff:93.184.215.99", // own interface, mapped
		"64:ff9b::5db8:d763",   // own interface through NAT64
	}
	for _, s := range refused {
		if webfetch.IsPublic(netip.MustParseAddr(s), []netip.Addr{own}) {
			t.Errorf("IsPublic(%s) = true, want false", s)
		}
	}
	public := []string{
		"93.184.215.14", "2606:2800::1",
		"64:ff9b::5db8:d70e", // NAT64 of 93.184.215.14
		"2002:5db8:d70e::1",  // 6to4 of 93.184.215.14
		"::ffff:93.184.215.14",
	}
	for _, s := range public {
		if !webfetch.IsPublic(netip.MustParseAddr(s), []netip.Addr{own}) {
			t.Errorf("IsPublic(%s) = false, want true", s)
		}
	}
	if webfetch.IsPublic(netip.Addr{}, nil) {
		t.Error("IsPublic(zero Addr) = true, want false")
	}
}
