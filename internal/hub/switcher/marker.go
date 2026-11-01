package switcher

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The transport marker (phone contract points 4 and 6a): plain kind
// "transport", id "marker", in a transport's data zone; its payload is the
// latest transport_switched minus keybox and device_id, the same for every
// phone. A switch owes it to the data zone of the transport it leaves
// (sealed in the old epoch, which every phone there holds) and to the
// relay's (in the new epoch when the relay is the new transport). It has no
// TTL and no hygiene: the hub never deletes it while the zone exists (the
// publisher deletes only the records it tracks, the mailbox hygiene only
// mailbox records).

// hub_meta keys: the marker payload of the latest switch (wire.Control JSON)
// and the markers owed, data zone by transport kind → epoch to seal in.
const (
	metaMarker      = "transport_marker"
	metaMarkersOwed = "transport_markers_owed"
)

// oweMarkersTx records r's marker payload and adds owed to the markers still
// to write, in the caller's transaction (the switch's announce).
func (s *Switcher) oweMarkersTx(tx *sql.Tx, r switchRecord, owed map[transport.Kind]uint32) error {
	hub, target, by, epoch := s.c.Keys.HubID().String(), string(r.Target), r.By, r.Epoch
	payload, err := wire.Marshal(wire.Control{
		ID: r.ID, Kind: wire.ControlSwitched, HubID: &hub, Target: &target, Epoch: &epoch, By: &by,
		At: &wire.Time{Time: r.At},
	}.Marker())
	if err != nil {
		return err
	}
	if err := state.SetMetaTx(tx, metaMarker, string(payload)); err != nil {
		return err
	}
	all, err := owedTx(func(k string) (string, bool, error) { return state.MetaTx(tx, k) })
	if err != nil {
		return err
	}
	for k, e := range owed {
		all[k] = e
	}
	return saveOwedTx(tx, all)
}

func owedTx(q func(string) (string, bool, error)) (map[transport.Kind]uint32, error) {
	out := map[transport.Kind]uint32{}
	raw, ok, err := q(metaMarkersOwed)
	if err != nil || !ok || raw == "" {
		return out, err
	}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, fmt.Errorf("switcher: unreadable owed markers: %w", err)
	}
	return out, nil
}

func saveOwedTx(tx *sql.Tx, owed map[transport.Kind]uint32) error {
	raw, err := json.Marshal(owed)
	if err != nil {
		return err
	}
	return state.SetMetaTx(tx, metaMarkersOwed, string(raw))
}

// writeOwedMarkers writes every owed marker it can; one that does not land
// stays owed for the next try (Run's poll).
func (s *Switcher) writeOwedMarkers(ctx context.Context) {
	owed, err := owedTx(s.c.Store.Meta)
	if err != nil || len(owed) == 0 {
		return
	}
	payload, ok, err := s.c.Store.Meta(metaMarker)
	if err != nil || !ok {
		return
	}
	for k, epoch := range owed {
		t := s.transport(k)
		if t == nil {
			s.markerWritten(k, epoch)
			continue
		}
		if err := s.writeMarker(ctx, t, epoch, []byte(payload)); err != nil {
			log.Printf("hub: the transport marker on %s waits (%s)", k, errClass(err))
			continue
		}
		s.markerWritten(k, epoch)
	}
}

// writeMarker seals the marker in epoch and saves it over whatever marker
// t's data zone holds.
func (s *Switcher) writeMarker(ctx context.Context, t transport.Transport, epoch uint32, payload []byte) error {
	sealer := s.sealer
	if current, err := s.c.Keys.CurrentEpoch(); err == nil && epoch != current {
		sealer = sealer.InEpoch(epoch)
	}
	rec, err := sealer.Data(s.data, wire.MarkerPlain, "", payload, nil, "")
	if err != nil {
		return fmt.Errorf("switcher: sealing the marker: %w", err)
	}
	wctx, cancel := context.WithTimeout(ctx, OldSideTimeout)
	defer cancel()
	out, err := t.Save(wctx, []transport.SaveItem{{Record: rec}})
	if err == nil && (len(out) != 1 || !out[0].Saved) {
		err = fmt.Errorf("switcher: the marker was not saved")
		if len(out) == 1 && out[0].Refused != nil {
			err = out[0].Refused
		}
	}
	return err
}

// markerWritten drops k from the owed markers unless a later switch owes it
// again in another epoch meanwhile.
func (s *Switcher) markerWritten(k transport.Kind, epoch uint32) {
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		owed, err := owedTx(func(key string) (string, bool, error) { return state.MetaTx(tx, key) })
		if err != nil {
			return err
		}
		if e, ok := owed[k]; !ok || e != epoch {
			return nil
		}
		delete(owed, k)
		return saveOwedTx(tx, owed)
	})
	if err != nil {
		log.Printf("hub: the transport marker on %s: %s", k, errClass(err))
	}
}
