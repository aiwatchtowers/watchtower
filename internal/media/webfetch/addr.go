package webfetch

import (
	"net"
	"net/netip"
)

// refusedPrefixes are never public, whatever they embed. IPv4 entries match
// an unmapped IPv4 address; IPv6 entries match before any embedded IPv4 is
// extracted.
var refusedPrefixes = mustPrefixes(
	// IPv4.
	"0.0.0.0/8",       // "this network", 0.0.0.0 included
	"10.0.0.0/8",      // private
	"100.64.0.0/10",   // CGNAT
	"127.0.0.0/8",     // loopback
	"169.254.0.0/16",  // link-local (cloud metadata)
	"172.16.0.0/12",   // private
	"192.0.0.0/24",    // IETF protocol assignments
	"192.0.2.0/24",    // documentation
	"192.88.99.0/24",  // 6to4 relay anycast (deprecated)
	"192.168.0.0/16",  // private
	"198.18.0.0/15",   // benchmarking
	"198.51.100.0/24", // documentation
	"203.0.113.0/24",  // documentation
	"224.0.0.0/4",     // multicast
	"240.0.0.0/4",     // reserved, 255.255.255.255 included
	// IPv6 inside 2000::/3 (everything outside it is refused by the 2000::/3 rule).
	"2001::/23",      // IETF special purpose block, Teredo 2001::/32 included
	"2001:db8::/32",  // documentation
	"3fff::/20",      // documentation
	"64:ff9b:1::/48", // local-use NAT64 (outside 2000::/3 too; listed for clarity)
)

var (
	globalUnicast6 = netip.MustParsePrefix("2000::/3")
	nat64          = netip.MustParsePrefix("64:ff9b::/96")
	sixToFour      = netip.MustParsePrefix("2002::/16")
)

func mustPrefixes(ss ...string) []netip.Prefix {
	out := make([]netip.Prefix, len(ss))
	for i, s := range ss {
		out[i] = netip.MustParsePrefix(s)
	}
	return out
}

// IsPublic reports whether ip is an address Watchtower may connect to: a
// public unicast address that is none of the host's own addresses (own).
// IPv4-mapped addresses are unmapped; NAT64 (64:ff9b::/96, last 32 bits) and
// 6to4 (2002::/16, bits 16-47) addresses are judged by the IPv4 they embed.
// Every other IPv6 address must be global unicast (2000::/3) outside the
// special-purpose blocks, so loopback, unspecified, link-local, ULA,
// multicast, IPv4-compatible and local-use NAT64 forms are all refused.
func IsPublic(ip netip.Addr, own []netip.Addr) bool {
	ip = ip.WithZone("").Unmap()
	if !ip.IsValid() || isOwn(ip, own) {
		return false
	}
	if ip.Is6() {
		b := ip.As16()
		switch {
		case nat64.Contains(ip):
			return IsPublic(netip.AddrFrom4([4]byte{b[12], b[13], b[14], b[15]}), own)
		case sixToFour.Contains(ip):
			return IsPublic(netip.AddrFrom4([4]byte{b[2], b[3], b[4], b[5]}), own)
		case !globalUnicast6.Contains(ip):
			return false
		}
	}
	for _, p := range refusedPrefixes {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

func isOwn(ip netip.Addr, own []netip.Addr) bool {
	for _, o := range own {
		if o.WithZone("").Unmap() == ip {
			return true
		}
	}
	return false
}

// ownAddrs lists the host's interface addresses (unmapped, no zone).
func ownAddrs() ([]netip.Addr, error) {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	out := make([]netip.Addr, 0, len(addrs))
	for _, a := range addrs {
		var ip net.IP
		switch v := a.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		if na, ok := netip.AddrFromSlice(ip); ok {
			out = append(out, na.Unmap())
		}
	}
	return out, nil
}
