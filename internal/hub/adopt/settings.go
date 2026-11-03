package adopt

import (
	"database/sql"
	"fmt"

	"watchtower/internal/hub/state"
)

// applySettings writes the owner's settings Desktop sent: hub_meta.enabled
// and each linked phone's start-sessions grant (a device id the sidecar does
// not hold is ignored).
func (r *run) applySettings() error {
	return r.inTx(StepTransport, func(tx *sql.Tx) error {
		enabled := "0"
		if r.settings.Enabled {
			enabled = "1"
		}
		if err := state.SetMetaTx(tx, state.MetaEnabled, enabled); err != nil {
			return err
		}
		for id, granted := range r.settings.StartSessionAllows {
			v := 0
			if granted {
				v = 1
			}
			if _, err := tx.Exec(`UPDATE devices SET start_sessions_granted = ? WHERE device_id = ? COLLATE NOCASE`, v, id); err != nil {
				return fmt.Errorf("adopt: writing a phone's grant: %w", err)
			}
		}
		return nil
	})
}
