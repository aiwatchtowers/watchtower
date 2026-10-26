package webfetch

import (
	"net"
	"net/http"
)

// NewForTest is New with the test-only escape hatch on: the dial to the
// initial URL's literal host:port (an httptest server) is allowed; every
// other address, redirect targets included, is judged as in production.
func NewForTest(check func(string) bool) *Fetcher {
	f := New(check)
	f.allowPrivateForTest = true
	return f
}

// ControlForTest runs the connect-time address check of a production
// Fetcher on network/address, without dialing.
func (f *Fetcher) ControlForTest(network, address string) error {
	return f.control("")(network, address, nil)
}

// TransportForTest is the transport a production Get builds.
func (f *Fetcher) TransportForTest() *http.Transport {
	return f.transport("")
}

// FailInterfaceAddrsForTest makes the own-address read fail with err until
// the returned restore runs. Fetchers made afterwards see the failure.
func FailInterfaceAddrsForTest(err error) (restore func()) {
	prev := interfaceAddrs
	interfaceAddrs = func() ([]net.Addr, error) { return nil, err }
	return func() { interfaceAddrs = prev }
}
