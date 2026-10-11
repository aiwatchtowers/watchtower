# Stamp fixture

`stamps.json` pins the one stamp format Go writes into the columns listed
under `columns` (Go's `agentStateAtLayout`, `db.AgentStateStamp`): UTC,
millisecond precision, a literal `Z`, fixed width, so string order is time
order.

- `layout` is the Go reference layout of the format.
- `valid[]`: each `stamp` is exactly what Go writes for the instant
  `unix_ms` (milliseconds since the Unix epoch, UTC). A reader must parse
  `stamp` to `unix_ms`; Go must format `unix_ms` back to `stamp`.
- `invalid[]`: strings a reader must refuse (treat as unreadable — never a
  time). Go's parser refuses each of them.

Readers: `internal/db/stamps_test.go::TestStampFixtureRoundTrips` (Go) and the
Desktop's stamp parser tests (Swift, the parser used for `agent_state_at`).
Add a case here rather than in one side's test only.
