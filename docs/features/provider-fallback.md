# Claude ↔ Codex quota routing

Spec: `docs/superpowers/specs/2026-11-02-provider-fallback-design.md` (ask #939).
Plan: `docs/superpowers/plans/2026-11-02-provider-fallback.md` (ask #940).

## Safe routing core (Task 4)

`internal/providerrouting.Router` accepts a request with configured preferred,
reserve, mode, tier, invocation profile, retry class, operation ID, config
revision, deadline, capability check and optional attempt hook. Policy is checked
before each attempt; a forbidden preferred is terminal. Only isolated
`batch_text`/`image` computations may retry, once, after confirmed subscription
quota or known shared quota. Auth, transient 429, malformed output, cancellation,
transport, capability and model errors never select an alternative.

`WrapGenerator` is shared by CLI/bounded/pooled factories and the separate daemon
coach. Its physical leaves use the actual provider's model bucket and never
exchange native session identifiers. A routed pooled call uses the same existing
worker pool for both leaves; its total timeout includes queue time and does not
restart for reserve. Known cooldown/probe-busy checks happen before taking a
worker. Unbounded interactive calls can use available providers but cannot claim
a recovery probe without a real deadline.

Off and explicit provider/model pins return the original legacy generator.
Stop/ask guards explicitly use `legacyCLIGenerator`; spec reviewer and generic
`ai.Provider` clients are unchanged. Chat activation belongs to Task 8. SDK
sources (`automation.*`) and automation-tagged contexts use the legacy path
until Task 7 supplies `WithAttemptHook`. Hook `Before` admits each attempt;
`After` receives its result/error and the leaf's recorded facts before reserve
admission, including estimated usage. Missing leaf facts mean unknown usage,
never a zero debit. The hook does not record another ledger row.

`Router.Select` is a metadata-only tool preflight; it never starts a child or
replays a turn. `providerrouting.Preflight` / `Router.Check` let scheduled callers
check known waits before claiming a data-attempt marker. They do not claim
recovery leases; a due safe request arbitrates its lease when `Run` starts.
`Deferred.Attempts` distinguishes a known wait without a physical attempt (0)
from quota discovered after calls. `ErrDeferred` also retains the historical
`digest.ErrAICall` retry marker. Deferred pipeline marker handling is implemented
by Tasks 5–6, not by the router.

Health checks compose exact account and selected-model scopes in the existing
installation store. Reliable identity may be supplied by the host; otherwise the
approved installation/provider fallback is used. No credential reader, auth
manager or poller is added. Claude's opus/sonnet weekly windows are model-scoped
only when the selected family matches. Codex's named-model display template is
recognized only for an exact selected-model match. A broken store reports a
separate diagnostic and permits only the same bounded per-request behavior; it
cannot replace a valid result or permit more attempts.

Leaf `llmusage.Record` carries `operation_id`, `attempt`, `config_revision` into
the existing row/spool. Migration `00169_llm_call_attempts.sql` adds these fields
with legacy-safe defaults. Provider/model remain the leaf's actual values;
wrappers never write synthetic cooldown or duplicate usage rows.

The no-tools Codex batch/image profiles explicitly disable both `shell_snapshot`
and `shell_snapshot_v2`. Upstream 0.166
[`session.rs`](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/session/session.rs#L1429-L1455)
configures the older snapshot independently of ShellTool.
[`shell_snapshot.rs`](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/shell_snapshot.rs)
constructs configuration lazily;
[`environment_selection.rs`](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/environment_selection.rs#L392-L423)
starts the later build future with login-shell permission for a ready local
environment. This source call graph establishes the independent gate. Tests
model this independent gate using a fake helper marker, including a negative
control with only ShellTool disabled. No installed inference or owner shell
startup was executed. Ordinary terminal/agent profiles and managed requirements
are unchanged.
