package mcp

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// WithReadSession keys the process's read budget on whichever registry the
// server ends up with — the dev-mode read registry NewServer builds itself
// included.
func TestWithReadSession_KeysTheServersRegistry(t *testing.T) {
	database := db.OpenTestDB(t)
	srv := NewServer(database, WithReadSession("terminal:42"))
	assert.Equal(t, "terminal:42", srv.registry.ReadSessionKey(tools.Binding{}))

	reg := tools.New(database)
	_ = NewServer(database, WithRegistry(reg, tools.Binding{Surface: "main"}), WithReadSession("pid:9"))
	assert.Equal(t, "pid:9", reg.ReadSessionKey(tools.Binding{}))
}
