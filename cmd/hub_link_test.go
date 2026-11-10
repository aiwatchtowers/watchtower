package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
)

// relayEpochRig is a sidecar with a keyring whose clock the test moves, and
// phones that have an offer (so a relay epoch gets them an ephemeral key) or
// do not (a static key).
type relayEpochRig struct {
	t   *testing.T
	dir string
	now time.Time
	id  *identity.Identity
}

func newRelayEpochRig(t *testing.T) *relayEpochRig {
	t.Helper()
	return &relayEpochRig{t: t, dir: hubTestDir(t), now: time.Now().Add(-20 * 24 * time.Hour)}
}

// keyring opens the sidecar's keyring at the rig's clock, runs f and closes.
func (r *relayEpochRig) keyring(f func(kr *identity.Keyring, st *state.Store)) {
	r.t.Helper()
	st, err := state.Open(r.dir)
	require.NoError(r.t, err)
	defer func() { _ = st.Close() }()
	if r.id == nil {
		id, err := identity.New()
		require.NoError(r.t, err)
		r.id = &id
	}
	kr, err := identity.NewKeyring(*r.id, st, func() time.Time { return r.now })
	require.NoError(r.t, err)
	f(kr, st)
}

// TestHubPhonesJSONKeysPinned: each phone carries keys = ephemeral|static,
// ephemeral exactly when the current epoch holds a relay-key row for it.
func TestHubPhonesJSONKeysPinned(t *testing.T) {
	r := newRelayEpochRig(t)
	var eph, stat string
	r.keyring(func(kr *identity.Keyring, st *state.Store) {
		p1, err := hubtest.New(hubtest.Config{})
		require.NoError(t, err)
		p2, err := hubtest.New(hubtest.Config{})
		require.NoError(t, err)
		for _, p := range []*hubtest.Phone{p1, p2} {
			require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, p.Device()) }))
		}
		_, err = p1.Offer()
		require.NoError(t, err)
		cur, err := kr.CurrentEpoch()
		require.NoError(t, err)
		require.NoError(t, st.WithTx(context.Background(), func(tx *sql.Tx) error {
			ok, err := state.SetKXOffer(tx, p1.ID().String(), p1.Offered(), cur)
			if err == nil && !ok {
				err = errors.New("offer refused")
			}
			return err
		}))
		require.NoError(t, kr.RotateToward(identity.ReasonManual, true, nil))
		eph, stat = strings.ToUpper(p1.ID().String()), strings.ToUpper(p2.ID().String())
	})
	got := hubPhonesByID(t)
	require.Len(t, got, 2)
	assert.Equal(t, "ephemeral", got[eph]["keys"])
	assert.Equal(t, "static", got[stat]["keys"])
	assert.Contains(t, hubKeysOf(got[eph]), "keys")
	out, err := runHub(t, "phones", "--json")
	require.NoError(t, err)
	assert.NotContains(t, out, "sealed", "no key material in the output")
}

// TestHubStatusShowsEpochAge: epoch and epoch_age_days are the current
// epoch and its age; null with no sidecar.
func TestHubStatusShowsEpochAge(t *testing.T) {
	r := newRelayEpochRig(t)
	out, err := runHub(t, "status", "--json")
	require.NoError(t, err)
	m := decodeKeys(t, out)
	assert.Contains(t, hubKeysOf(m), "epoch")
	assert.Contains(t, hubKeysOf(m), "epoch_age_days")
	assert.Nil(t, m["epoch"], "no sidecar: unknown")
	assert.Nil(t, m["epoch_age_days"])

	r.keyring(func(kr *identity.Keyring, st *state.Store) {})
	r.now = time.Now()
	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	var v struct {
		Epoch *uint32 `json:"epoch"`
		Age   *int    `json:"epoch_age_days"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &v), out)
	require.NotNil(t, v.Epoch)
	require.NotNil(t, v.Age)
	assert.Equal(t, uint32(1), *v.Epoch)
	assert.InDelta(t, 20, *v.Age, 1)
}
