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
worker. Raw enabled routes also receive the default total call timeout, so
deadline-free safe callers can recover a due circuit. Earlier caller deadlines win. Off,
pinned and excluded automation calls retain their original legacy deadline.

Off and explicit provider/model pins return the original legacy generator.
Stop/ask guards explicitly use `legacyCLIGenerator`; spec reviewer remains excluded. Tool-bearing `ai.Provider` clients use the
Task 8 preflight described below. SDK
sources (`automation.*`) and automation-tagged contexts use the legacy path
unless the SDK supplies `WithAttemptHook` (Task 7). Hook `Before` admits each attempt;
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

## Deferred scheduled digests and people batches (Task 5)

The daemon's scheduled Slack digest batch/daily rollup and required `people.batch`
primitive check the router's metadata gate before claiming work. Known quota or
probe-busy waits make no model call; quota discovered during a call retains the
leaf's physical usage record. Unsaved work gets no success/considered stamp or
people poison attempt, including the persistent attempt file's calendar date.
Mixed provider waits and material/storage failures retain the ordinary error
policy; a successful worker cannot hide another worker's deferred result.

Daemon-only `digest_pending_window.json`, `digest_pending_daily.json` and
`people_pending_window.json` are
small input descriptors containing ids/timestamps, never prompts or source text.
They pin the original input boundaries across partial commits, restarts and date
rollover. Existing database coverage/considered marks skip committed output;
current filters and fast-forward guards still apply. People norms use the whole
active population, including covered users. A completed people descriptor stays
until the daemon atomically saves `last_people.txt`; a failed save preserves the
old in-memory throttle and reports an error. The success timestamp is the
original window's start of processing, so completing an old window does not
claim newly arrived data was covered.

Off/pinned generators and ordinary CLI commands acquire no durable descriptors.
This is not a general job queue. Individual `people.reduce` quality fallbacks
and optional `people.team` summaries retain their existing cadence; routed provider
unavailability does not start individual quality retries. Off/pinned nonquota
batch failures keep the legacy individual fallback. Source synchronization
continues independently. Other scheduled pipelines retain their own retry rules;
ideas/history integration is described below.

### Decisions

- Решил агент: approved scheduled Slack “period” maps to the actual daemon
  `RunRollups` → `RunDailyRollup` call graph (`digest.daily`). Its descriptor pins
  one UTC day, and `rollup_attempts.txt` remains unchanged on quota before/after
  calls, including UTC date rollover. Migration `00170_daily_digest_attempt.sql`
  gives each scheduled daily claim a random completion token, written atomically
  with its output in
  `digests.daily_attempt_id`. Ordinary upserts preserve it; it stays out of the
  public Digest/wire shape. A retained descriptor checks the exact token/window,
  independent of newer source rows, identical output and timestamp precision.
  An older preclaim daily row still regenerates normally. A later ordinary cycle
  can process the current UTC day.
  One-off `RunPeriodSummary` (`digest.period`) and `RunWeeklyTrends` remain outside
  the durable retry allowlist; no new scheduler or broader pipeline guarantee.

Ordinary metadata preflight failures are logged immediately without starting a
model, debiting a data attempt, or bypassing no-data/budget/throttle eligibility;
expected shutdown cancellation is benign. Pending people windows require positive
ordered bounds and a present StartedAt; invalid descriptors remain errors and
retain their bytes, while future StartedAt is accepted for clock skew.


## Deferred extraction and history chunks (Task 6)

Routed ideas Gmail/IMAP and Jira extraction pins each account's original input
bounds in local SQLite metadata. Known provider waits make no model call;
physical quota failures retain their leaf usage and leave the input floor
unchanged. Account passes continue independently, and joined failures preserve
ordinary material/storage causes. Linear extraction and ideas consolidation do
not acquire this completion guarantee.

Migration `00171_ideas_extraction_windows.sql` adds narrow primitive receipts,
not a job queue. A successful extraction commits its optional stream digest,
completion receipt and monotonic source floor in one transaction. Valid empty
extraction saves a receipt without creating an unread empty stream digest.
Historical chunk anchors retain the original effective lower floor even when a
partial pass raises the live floor across the chunk boundary. A restart follows
completed prefixes and retries missing passes. Source resets, account deletion,
history reset and removal of saved stream output invalidate the corresponding
receipts; current account/source eligibility remains enforced.

History fetch still runs independently of AI health. Pure typed provider waits
never age into poison strikes, never advance `history_backfill.reached_ts`, and
never erase an older transport hold; other accounts continue their turns. The
row-id scheduling cursor remains a fairness cursor, separate from reached data.
Slack history keeps chunk-local considered receipts for declined channels,
separate from forward channel marks. Existing saved channel output also proves
its consumed prefix. Historical daily output and its account/chunk/day receipt
commit atomically; newly arrived channel data cannot replay a saved day while
another day waits. Scheduled `daily_attempt_id` receipts remain independent.

Only opt-in routed primitives acquire these receipts; off/pinned paths retain
their legacy cadence. Built-ins inherit only a covered primitive they actually invoke, without
replaying a whole recipe. The current Idea finder calls `ideas.RunWith`
(consolidation), not `RunStreamDigests`; it gains no extraction retry promise
from that call. Task 7 supplies attempt-budget integration for SDK calls; the
receipts themselves do not activate routing or broaden the durable allowlist.
Other pipelines are not advertised as durable deferred work.


## Automation attempt accounting and agent preflight (Task 7)

SDK `llm()` and built-in primitive calls install an attempt meter around their
isolated no-tools generator calls. Each physical attempt checks the shared token
remainder, exact active-time deadline and cancellation. Serialized input estimates
are reserved across concurrent primitive workers, then released as leaf usage or estimates are
debited. Preferred, reserve and the existing single JSON-schema retry share the
same run budget and one dense SDK step per call. A legacy generator or primitive
that never enters routing keeps its aggregate accounting; routed calls do not
also debit that aggregate. Cooldown/admission refusals create no synthetic leaf.

Leaf facts take precedence over aggregate result usage. An attempt debits a leaf
call's fresh `Input` plus `Output`; its cache reads and writes stay in the leaf
ledger only, matching the unrouted path ([automation budgets](automations.md#budgets)). Authoritative non-estimated
zeros remain zero, including parsed zero-usage envelopes and children that never
started. Missing usage is estimated
from the submitted system/user input and available partial output, marked
estimated, and a failed estimate leaves an unknown remainder that blocks further
model admission. This is a conservative budget rule, not a claim about provider
billing. SDK `reported_cost_usd` sums only provider-reported cost; estimated
pricing stays in the leaf ledger. Existing waiting-run replay preserves the
unknown-usage gate through internal versioned replay metadata; successful estimates
and validation failures with known usage do not acquire that gate. See
[automation resume details](automations.md#resume-after-a-restart-2026-10-21-board-795).

For CLI `agent()`, shared known health selects a bound provider/model before the
child starts; the step name and leaf audit identify that selection. The existing
MCP binding, proposal-only tools, isolated Codex home, carved budget and process
group cleanup remain in force. One started tool loop is never retried. Confirmed
quota records shared health and ends the step, preserving proposals; a later new
call can select reserve. Runtime B and explicit/off routes retain their behavior.

No whole recipe or primitive is replayed because of quota, and no waiting type or
durable pipeline guarantee is added. Current built-in primitives run inline at
slots; `ask()` remains workbench-only, while `track.scan` remains a personal
`custom_tracks` primitive. The SDK uncertainty metadata does not make these
recipes resumable.

## Chat and tool preflight (Task 8)

Migration 172 gives existing conversations `routing_mode=pinned`; newly inserted
conversations default to `preferred_reserve`. `provider`/`model` remain the legacy
pin pair. `actual_provider`, `actual_model` and `routing_reason` record the chosen
attempt independently of the global preference. `SetChatRouting` is a manual
selection and clears the previous actual pair. A chosen reserve remains sticky
across turns and DB reopen; recovery of the preferred alone does not switch that
conversation back. If the sticky reserve is exhausted, a new automatic turn may select recovered
preferred after policy and capability checks; if both are waiting, no child starts. A new conversation starts from configured preferred.
Explicit CLI provider/model flags, including the default model, are pins.

Auto-enabled sessions defer the warm child until the pending turn is known.
`Router.Select` checks policy, then shared known health, then the available
candidate's capabilities before construction/start. A healthy candidate missing
a required capability fails without switching merely for capability.
`Router.Run` then wraps exactly one pinned, never-retried turn, including the warm startup. A typed terminal event's internal `Cause` is
observed even when the backend returns nil. A newly discovered quota preserves
partial text and action rows, records health, and ends that turn with
`retryable=false`. A later new turn can choose reserve. Cancellation retires an
auto session's child; a new turn replays persisted Watchtower history. Between
providers the old backend is closed and reaped; native session IDs never cross.
Off/pinned sessions retain their legacy warm lifecycle.

The selected provider builds its own strong model, prompt, MCP setup and
claude.ai mode. An unavailable required claude.ai mode, image/PDF (including
project files), or Codex-incompatible Quick Connection prevents reserve startup;
there is no text-only downgrade. This is conservative: a main chat with its
claude.ai tool mode enabled requires that mode. Preflight performs no paid probe.
Tool-bearing query, embedded chats, REPL and Jira analyzer factories use the same
known-health selection and single-call outcome recording. Native-thread IDs returned by a routed streaming client bind subsequent calls
to that actual provider/model. An unknown incoming native ID fails closed with
no child; an explicit `--provider` pin or a fresh session is required. Off/pinned
legacy callers retain their existing behavior. Stop hooks and spec reviewers retain
their separate excluded factories.

Protocol v2 adds `preferred_provider`, `routing_mode` and `reason` alongside the
actual `provider`/`model`. Auto sessions first emit readiness without claiming a
physical provider; their per-turn readiness supplies the selected actual pair.
The fixture is `internal/chat/testdata/routing_v2.jsonl`. Extra fields are additive
for old readers; no text reset event was added. Task 9 owns the Desktop controls.

Replay reads up to 200 newest content-free action receipts for prior assistant
turns on the active path, including failed empty replies without tool events.
The summary includes durable action ID, tool, status and whether a result/error
is recorded; full arguments, results and diagnostics are omitted. Current turns,
regenerate owner rows, abandoned branches and other conversations are excluded.
The existing replay character cap still applies; receipts never execute actions.

## Desktop chat intent and actual execution (Task 9)

New main chats use **Preferred + reserve · Auto**. Migration 172's historical
rows keep their provider/model pair as a pin; the composer offers the explicitly
combined **Preferred + reserve · Auto model** choice to remove both. **Only**
provider and explicit model choices remain hard pins. Automatic session argv
omits both `--provider` and `--model`: Go reads routing intent from the row.
Observing actual metadata does not change the pool's wanted configuration.

Protocol-v2 ready events carry preferred/mode/reason separately from actual
provider/model. An empty automatic ready event claims no started provider.
`ChatTurnDriver` records selected actual metadata in the existing conversation
and message columns without resetting text or steps; the embedded v1 stream has
additive `routing` and typed error fields for the same actual-message contract.
The current native claude.ai required-capability guard is unchanged: a reserve
that cannot supply required tools or attachments is refused before startup.

Healthy reserve sessions remain sticky. **Use preferred** between turns clears
sticky metadata and retires the idle host; the existing pool waits for its exit
before launching the replacement. Busy or queued turns cannot change routing,
unsent drafts remain intact, and no global provider preference is written.
The Go preflight may return an exhausted sticky reserve to a recovered compatible
preferred before a new turn; it never replays a started turn.

`watchtower ai routing-status` reads local installation quota metadata through
`Router.Status` and `Store.Peek`. The reader uses the router's exact account and
selected strong-model scopes, returns the configured revision, and exposes only
provider/state/next-check metadata. It claims no lease, performs no inference,
and never rewrites health state. Expired leases project `quota_wait` in the
returned copy; a passed reset never means available. Storage, policy and cancel
errors remain errors. Desktop refreshes on entering a chat, app activation and
turn boundaries; it does not promise instant background recovery notification.
This is the canonical reader for subsequent settings integration.

A typed started-quota error persists `quota_exhausted` in the existing
`error_code`, including partial replies. Reload therefore cannot restore Retry,
Continue or Regenerate for that turn. A short transient `rate_limit` keeps its
existing retry behavior. **Review actions** reads and opens existing persisted
action IDs/status/results without sending a prompt, approving a proposal, or
executing an action; empty receipt lists do not claim that no effects occurred.
The user can check these actions and then send a new message.

`ChatRoutingPresentation` consumes the canonical status DTO and actual session
metadata. Its copy comes from the approved `ProviderFallbackPreview`; runtime
next-check times come from metadata, while sample times remain in shot fixtures.
`ChatRoutingStatusView` is shared by production and light/dark, narrow and
reverse-provider catalog scenes. Tests cover argv, parser/driver/DB reload,
embedded typed quota handling, action review without sending, explicit pins,
sticky retirement and bounded warm sessions.

Ready-before-turn storage failures retain their underlying error on the session
and appear in the existing persistence error strip even without a live turn.
The next turn carries the diagnostic until an actual-metadata write succeeds;
repair clears only the matching diagnostic, preserving unrelated errors.

An embedded typed started-quota event remains the terminal outcome if the owner
presses Stop while stdout is still draining. The partial/error row keeps its
quota code and action review after reload. Ordinary Stop behavior is unchanged.

Historical actual/provider inequality alone never proves quota or recovery.
The Go chat adapter retains the persisted routing cause across sticky turns and
reopens, updating its in-memory provider/cause only after the DB write succeeds.
Automatic quota/recovery cards require an affirmative quota cause; recovery also
requires matching available local health. Unknown or ordinary historical causes
show the actual label and any diagnostic without inventing a quota explanation.

### Applying AI configuration

The running daemon reloads saved AI routing without restarting its process or
Workbench terminals. Each sync cycle and automation run captures one immutable
routing generation before work begins. A started job keeps its provider, models,
paths, context budget and attempt/deadline semantics; later jobs capture the
published generation. SDK modules and agent preflight bind together. Persistent
pipelines, the memory opener, scheduler, waiting runs, replay journals and history
checkpoints retain their existing owners. All generator generations share one
worker admission pool, including separately constructed coach and agent calls;
lowering its limit waits for existing calls to drain.

`ai routing-status` additionally reports `saved_version`, optional `application`
(identity, normalized revision, saved file version, preferred provider and optional
error), and `application_error` for unreadable/corrupt acknowledgement metadata.
The acknowledgement is an owner-only atomic sidecar beside the existing daemon
PID file. Readers require the existing confirmed kernel start identity and reject
replaced/dead daemons. The saved file version includes the local file identity,
mtime and size, so a delayed acknowledgement cannot confirm a later A→B→A Save.
It is distinct from the normalized routing revision and is not a second routing
hash. Unchanged acknowledgements do not rewrite the sidecar every poll.

Publication precedes acknowledgement. A failed acknowledgement write does not
roll running jobs back: Settings says the current background configuration is
unconfirmed and labels any older acknowledgement as the last confirmed provider.
Retry only reads current saved state; it never rewrites a captured Settings draft.
Concurrent Saves supersede older in-flight results. Existing daemon-status
observations revoke confirmation if the daemon stops; Retry validates the new
run. A separate feature-save failure never strands routing in Applying. Explicit process provider
pins remain effective and are reported as an apply error when they differ from
the saved route, including a same-provider pin with an enabled reserve. Saved
and effective pinned revisions remain distinct. Fallback itself never writes configuration.

New automatic main-chat contexts read the latest preference. Warm launched hosts
retire after their active turn on a routing-revision change; pending hosts keep
FIFO admission and read configuration on launch. Compatibility never uses the
observed actual provider. Embedded turns already start a fresh query process;
new engines read the current configured preference and active turns keep theirs.

An explicit `--workspace` on `ai routing-status` selects that workspace's daemon
identity and acknowledgement; quota health remains installation-wide. Reloading
Settings revokes both previous confirmation and pending responses, even within
the same workspace. This does not launch metadata commands from ConfigService
initialization: the current saved revision is confirmed by the explicit apply or
Retry action. A later response from before Reload or daemon loss cannot restore
an older confirmation.

Generator decorators expose `GeneratorForContext` for optional-capability
inspection. `digest.Preflight`, `RoutingEnabled` and `ImageCapable` inspect the
job-selected generation; dynamic callers must pass their job context, including
through nested pool/timeout wrappers. An enabled old job retains its durable
receipts after reserve is disabled, and a disabled old job does not acquire
routing/deferred semantics merely because a newer job enables it.

### Settings connections and limits

Settings → System → AI edits the preferred provider and the other cloud provider's
independent light/strong model bucket and CLI path. Reserve starts off; installing,
checking, or testing a CLI never enables it. Switching Claude ↔ Codex keeps both
buckets. Selecting Ollama disables reserve and keeps the existing local server and
model controls. Policy restrictions keep stored choices and refuse forbidden calls.

**Check connection** only checks whether the selected executable can be found. It
never runs an auth command, reads credentials, opens a keyring or sends a model
request. Native sign-in status cannot safely be established by binary existence,
so an installed CLI remains **Not verified**. A known auth failure from the
explicit test instead gives the sign-in guidance. Metadata/transport failures
remain distinct from missing sign-in.

**Test connection** warns before the button that it sends one short request using
the selected provider's strong model and account, possibly spending paid quota.
It uses the current form's model and CLI path without saving them, testing the
light model, or falling back to another provider. The existing `ai test` command
now invokes the canonical isolated no-tools batch leaf: no owner startup hooks,
MCP tools or shell snapshots. For codex the request carries a system prompt
naming a fresh nonce, delivered the way every codex call delivers it (the
`model_instructions_file`, or stdin on a codex too old for one), and an answer
without the nonce (matched case-insensitively) fails as `invalid_output`
(with a content-free stderr line) and the owner-readable error "Codex answered
but ignored Watchtower's instructions. Update the Codex CLI, or check its
config, and test again.", so a broken system-prompt path fails the test. The MCP tool mount is not part of
the probe (it stays tool-less); the
opt-in `scripts/check-codex-features.sh --live` covers it with a real codex
run. Its additive `--cli-path` override is test-only;
HTTP providers reject that flag and retain their direct HTTP test. Local Settings
tests retain one request per distinct light/strong model against the form URL.
Failures cross into Desktop as sanitized messages plus a typed `error_code`, not
arbitrary child stderr. Real attempts retain normal leaf usage recording.

`ai test` and `ai routing-status` skip the root schema-upgrade hook: a connection
or limits check does not migrate a database or rewrite the configuration. The
explicit probe still sets its ordinary usage-spool destination after reading the
configuration. Their existing CLI audit classifications remain unchanged.

**Check again** under Saved provider limits reads the saved configuration, never
the unsaved form. `ai routing-status --check-again` reserves the existing
`ManualCheck` per-minute gate over exactly the router's account/model scopes.
Its optional provider `manual_allowed` field distinguishes a throttled check.
It sends no synthetic recovery prompt, claims no probe lease, and never clears a
quota block because a timestamp passed. Only a real eligible request can prove
recovery. Missing local health remains an error rather than successful recovery.
Ollama has no cloud health scope and is not misreported as unauthenticated.

Connection, limits and apply have separate operations and Retry actions. The
app-owned models invalidate stale results on configuration reload/save or form
selection/model/path/workspace changes. Save and apply continue using the actual
saved file version and daemon acknowledgement; a successful connection test does
not claim that the daemon applied anything. Production status cards and approved
catalog scenes share `ProviderFallbackStatus` and `ProviderFallbackPreview` copy;
sample chat names, default-model summaries and sample times stay in fixtures.
