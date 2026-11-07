package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
)

// TestTransportWiring_EveryRegistryIDHasConstructors pins the one factory
// (spec 2026-11-05 §3.4): every registry provider has a transport row and a
// cmd wiring, and a constructor is nil exactly where the provider's Caps say
// the transport cannot do it.
func TestTransportWiring_EveryRegistryIDHasConstructors(t *testing.T) {
	for _, p := range providers.All() {
		t.Run(p.ID, func(t *testing.T) {
			row := transport.For(p.ID)
			assert.Equal(t, p.ID, row.ID)
			assert.Equal(t, p.Caps, row.Caps)
			assert.NotNil(t, row.NewGenerator, "every transport generates text")
			assert.NotNil(t, row.NewQuerier, "every transport answers a query")

			w := wiringFor(p.ID)
			assert.NotNil(t, w.newChatBackend, "every transport carries a chat session")
			// agent() runs a CLI child where the transport has one; the
			// others run the runtime-B loop, which needs the tools.
			assert.Equal(t, providers.RunsChild(p.ID), w.newAgentClient != nil, "a CLI child per agent() call")
			assert.True(t, w.newAgentClient != nil || p.Caps.HasTools(), "agent() needs tools")
		})
	}
}
