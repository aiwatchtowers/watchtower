# Tower interface — one command interface for the Mac and the phone

Spec: `docs/superpowers/specs/2026-11-15-mobile-inbox-design.md` §2.1 (#1170). Stage 0: the core in `internal/tower` and `internal/tower/api`, the request ledger and the builtins. Later stages add the generator, the daemon socket, the pause and the Inbox commands to this note.

## Commands and envelope

- A command is a name (`domain.verb`) with a request type and a response type in `internal/tower/api`, registered once with `tower.Register(r, name, handler, tower.Spec{…})`. A duplicate name panics. `Registry.Commands()` lists them sorted, with the `reflect.Type` of each request and response (the generator's input).
- `tower.Spec`: `Read` (no ledger, no `request_id`), `Idempotent` (a guarded write), `Grant` (the hub grant), `ChangeTables` (a read or watch: the tables whose change re-reads it; a write: the tables it changes), `Watch`. `IdempotentFor`/`GrantFor` decide from the params when set (one command whose verbs differ, such as `inbox.act`).
- Envelope (`api.EnvelopeVersion` = 1): a request is `{v, id, command, params}`; a response is `{id, status, result | refusal{code, sentence}}` with status `ok`, `refused` or `unknown`. `Tower.Call` never fails: an unknown command, another envelope version, unreadable params or a write without `request_id` answer `refused` with `unsupported`.
- Refusal codes are exactly `not_found`, `changed`, `args_changed`, `reply_waiting`, `not_permitted`, `unsupported`. A handler refuses with `tower.Refuse(code, sentence)`; the sentence is written in Go and both clients show it as is. Any other handler error answers `unsupported` with `Options.Sentence(command, err)` (default: the error text).
- A handler gets a `*tower.Ctx` (`DB`, `Origin` — transport `socket`|`hub` and device —, `Now`). It writes through `Ctx.Write(ctx, fn)`: one `BEGIN IMMEDIATE` transaction around `fn`, committed, then `Options.Changed(spec.ChangeTables)`. `Changed` is called only after a commit, never on a rollback. Keep `fn` short: no network, LLM call or render inside it.

## Ledger

`tower_requests` (migration 00192): `request_id` PK, `command`, `state` `begun`|`done`, `result_json`, `at` (UTC `%Y-%m-%dT%H:%M:%SZ`). Written only by `internal/tower`. Every write command embeds `api.WriteParams` (`request_id`, a UUID the client makes once per press and keeps across its retries).

- **A repeat of a `done` id** answers the stored result, byte for byte, without running the handler.
- **Guarded (idempotent) commands** write their `done` row inside the same transaction as their write (`Ctx.Write`), so `done` exists exactly when the write committed. A guarded command calls `Write` once, and `fn`'s result is the command's response. A handler that never calls `Write` gets its `done` row after it returns. A fault or a refusal rolls back and leaves no row, so a resend may succeed. A `begun` row of a guarded command is re-run. A duplicate that committed first wins: the later write rolls back and answers the first result (`FinishTowerRequestTx` never overwrites a `done` row).
- **Non-idempotent commands** (approve, retry, Run Now, the `reply` press) commit `begun` in their own short transaction before they act and write `done` after the handler returns. A repeat of a `begun` id answers `unknown` and never acts; so does a duplicate that began first, and a handler error after `begun` (it may have acted). A refusal is answered as is and keeps the `begun` row, so a resend of that id answers `unknown`.
- A `request_id` recorded for another command is refused (`unsupported`).
- **Prune.** The daemon (`runSyncDaemon`) runs `tower.RunPrune`: once at start and then every `tower.PruneInterval` (1 h), with or without the hub, it deletes rows of both states older than `actions.LedgerRetention` (`ActionMaxAge` 7 days + `retentionMargin` 1 day), the window the hub's own ledger keeps. The hub refuses an action older than `ActionMaxAge` before a handler sees it, so a phone action replayed after a long Mac sleep either finds its row or is refused; it never runs twice.

## Builtins

`tower.RegisterBuiltins(r)` registers two reads:

- `tower.hello` → `api.HelloResponse{interface_version, build, sync_paused, no_sync}` from `tower.InterfaceVersion` (`"dev"` until the generator writes it) and `Options.Build`/`Paused`/`NoSync`.
- `tower.ping` → `api.PingResponse{at}`, the daemon's clock in UTC RFC 3339.
