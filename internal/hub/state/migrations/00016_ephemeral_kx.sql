-- +goose Up
-- Weekly relay keys from ephemeral X25519 keys (relay client Phase 5).
-- devices.kx_offer is the phone's newest offered ephemeral public key (from
-- its epoch_ack's next_kx), kx_offer_epoch the ack's epoch: an older ack
-- never replaces a newer offer. Stored only while the hub is on the relay
-- and the phone is not lapsed; a re-link, an unlink and leaving the relay
-- clear it.
ALTER TABLE devices ADD COLUMN kx_offer BLOB;
ALTER TABLE devices ADD COLUMN kx_offer_epoch INTEGER NOT NULL DEFAULT 0;

-- Whether the epoch began on the relay (1) or on iCloud (0), written when it
-- begins. NULL on rows written before this migration: those are never erased.
ALTER TABLE hub_epochs ADD COLUMN on_relay INTEGER;

-- One phone's two relay keys (p2h, h2p) of one epoch, sealed under the wrap
-- key, with the two ephemeral publics that built them (the keybox names
-- them). Erased with the epoch's keys; a re-link or unlink deletes the
-- phone's rows.
CREATE TABLE epoch_relay_keys (
    epoch INTEGER NOT NULL,
    device_id TEXT NOT NULL COLLATE NOCASE,
    hub_pub BLOB NOT NULL,
    device_pub BLOB NOT NULL,
    sealed_keys BLOB NOT NULL,
    PRIMARY KEY (epoch, device_id)
);

-- +goose Down
DROP TABLE epoch_relay_keys;
ALTER TABLE hub_epochs DROP COLUMN on_relay;
ALTER TABLE devices DROP COLUMN kx_offer_epoch;
ALTER TABLE devices DROP COLUMN kx_offer;
