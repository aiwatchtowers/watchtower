package transport

// Zone names on the hosted relay (relay proto README, Zone names). hub is the
// hub's relay_device_id, not the Watchtower hub_id: the relay protocol has no
// hub_id, and the transport keeps the mapping. The CloudKit bridge maps these
// names onto its own zones.

// DataZone is the hub's data zone, data/<hub>.
func DataZone(hub string) string { return "data/" + hub }

// MailboxZone is one phone's mailbox with the hub, relay/<hub>/<phone>.
func MailboxZone(hub, phone string) string { return "relay/" + hub + "/" + phone }

// PairZone is a pairing slot's zone, pair/<slot>.
func PairZone(slot string) string { return "pair/" + slot }

// SharedMailboxZone is the one mailbox every phone of hub shares where the
// transport has one (CloudKit's RelayZone): relay/<hub>/*. It starts like
// every MailboxZone(hub, …), so a mailbox event under it reads as one.
func SharedMailboxZone(hub string) string { return MailboxZone(hub, "*") }
