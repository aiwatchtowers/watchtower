# Audit fix — wave 3: Jira

**Branch:** `fix/audit-wave3` (off `main` @ `0c9f192f`, wave 2 merged)
**Source:** `docs/audit/2026-09-13-feature-audit/` — root causes 1 and 4, owner decisions 4 and 5.
**Scope line from the audit README:** *"Wave 3 — Jira: feature flags yaml/defaults/migration; key
detector wiring; `assignee_slack_id` backfill; `jira_sync_state.last_error`."*

Wave 1 stopped the pipelines that were fully dead. Wave 2 stopped the ones that lost material while
reporting success. This wave fixes the Jira surface, where the defect shape is different again:
**a feature that was built, shipped and marked DONE, and then never ran once** — a toggle written
under a key its own reader cannot see, a detector with no caller, a column two migrations skipped,
an error field assigned and dropped.

Three verification reports were produced against this exact HEAD before the plan was written and
are the authoritative anchors for every task. They carry current `file:line`, the offending code,
probe output, the full reader/writer enumerations, the existing tests and the traps:

- `.superpowers/sdd/2026-09-13-audit-fix-wave3/verify-C1-features.md` — tasks 1–3
- `.superpowers/sdd/2026-09-13-audit-fix-wave3/verify-H1-detector.md` — tasks 4–6
- `.superpowers/sdd/2026-09-13-audit-fix-wave3/verify-jira-data.md` — tasks 7–8

All four findings were re-verified as **STILL BROKEN at HEAD**, and three of them turned out to be
**wider than the audit stated**. Those widenings are folded into the tasks below and each is named
where it applies.

---

## Global Constraints

These bind every task. A reviewer checks them as well as the task text.

1. **English only** in the repository — code, comments, commit messages, test names, docs.
2. **One commit per task.** Conventional-commit subject, body explaining the failure the change
   removes. Never `git add -A` and never a working-tree-wide git command: this is a shared worktree
   checkout, stage only the files the task names.
3. **Inner-loop testing only.** `go test ./internal/<pkg>` or `./cmd` (add `-run` to narrow);
   Swift `make test-swift FILTER=<TestClass>`; `make lint-diff`. Never a bare `go test ./...`,
   never an unfiltered `swift test`, never `-count=1` reflexively. The full gate runs once, at the
   end, from the controller.
4. **Never touch the owner's live data.** Do not run the `watchtower` binary at all. Do not open
   `~/.local/share/watchtower/` in any mode, not even read-only, and never read or write the
   owner's real `config.yaml`. Tests use temp databases and temp config files.
5. **No guard-test weakening.** A test named `Test<Module>NN_…` pins a numbered inventory contract.
   It may be *extended in place*; it may never be renamed out of the convention, split into weaker
   assertions, or deleted. Two tasks in this wave deliberately change a **non-guard** test that
   pins behaviour being retired (tasks 5 and 7); each says so explicitly and no other test may be
   touched without reporting it.
6. **Migrations are allowed in this wave, and only where a task names one.** Wave 2 forbade them;
   this wave needs exactly one DB migration (task 4) plus one *config* migration (task 2). If you
   believe your task needs another, stop and report instead of adding it. The DB migration number
   **00067** is reserved for task 4 and was verified free across the whole repo. Follow
   `.claude/skills/add-migration`: `-- +goose Up` and `-- +goose Down` both present, mirror into
   `internal/db/schema.sql`, add new tables to `TestAllTablesExist`, regenerate the golden snapshot
   with `go test ./internal/db/ -run TestSchemaGolden -update`.
7. **No new config keys** other than the one migration marker task 2 names. In particular: do not
   invent a new gate for the key detector — task 6 states the gate it uses and why.
8. **Sentrux complexity gate.** CI counts complex functions and fails when the count rises. If your
   change pushes a function past roughly cyclomatic 13, split it into named helpers in the same
   commit. Never re-baseline the gate.
9. **`docs/inventory/` contracts are load-bearing.** There is no `jira.md` inventory file, but two
   existing ones are in the blast radius: `dev-surface.md` (DEV-01..05 — `get_task_context` and
   `find_experts` are readers of `jira_slack_links`) and `tracks.md`. Read the relevant file before
   touching code in its module. A change that would weaken a numbered contract stops and reports; a
   change that *strengthens* one is allowed and must be recorded in that file's changelog with
   today's date.
10. **Every guard you write must be mutation-checked.** Neuter the fix in a scratch copy of the file
    **outside the repo**, re-run the test, confirm it FAILS, restore the file, and verify it is
    byte-identical (`diff -q`). A test that passes with and without the fix is worthless and this
    wave has already found three of them in its predecessors. Report the mutation you applied and
    the observed failure in your report file. Scratch copies live under
    `/private/tmp/claude-501/-Users-user-PhpstormProjects-watchtower/2298a5d2-77c6-40ce-b461-ee6463dbe413/scratchpad/wave3/`
    — never inside the repo worktree, where a stray file produces a phantom `lint-diff` failure.

---

## Task 1 — Make `jira.features` writes readable

**Decision 4, finding C1.** Read `verify-C1-features.md` §1, §3, §5a and §7 — it is the full
specification, including probe output showing the literal bytes on both sides.

Today `setJiraFeatureToggle` (`cmd/jira.go:1244-1276`) and `runJiraFeaturesReset`
(`cmd/jira.go:1293-1320`) do `v.Set("jira.features", <Go struct>)` and write through
`writeConfigAtomic` → `viper.WriteConfigAs` → `gopkg.in/yaml.v3`. The struct carries `mapstructure`
and `json` tags but **no `yaml` tags**, so yaml.v3 falls back to the lowercased Go field name and
writes `myissuesinbriefing`. `config.Load`'s mapstructure decode wants `my_issues_in_briefing`;
case is forgiving, underscores are not. Every one of the eleven flags decodes `false`, permanently,
on any install whose toggles were ever touched. Probe-confirmed, both directions.

**Write scalar dotted keys, not the struct.** `v.Set("jira.features.my_issues_in_briefing", true)`
— the `setConfigKey` shape already used by `cmd/features.go:379-398` for every other toggle in the
product. Two reasons this beats adding `yaml` tags, and the second is the load-bearing one:

1. It touches only the key the user toggled, instead of rewriting all eleven on every call.
2. `setJiraFeatureToggle` reads `cfg.Jira.Features` first — which today is **always all-false**. A
   struct write would therefore persist ten explicit `false`s next to the one `true`, cementing the
   loss on exactly the installs task 2 exists to repair. The scalar write has no such property, so
   tasks 1 and 2 compose in either order.

`reset` needs all eleven and may write eleven scalar keys.

The canonical on-disk key is the **mapstructure long name** (`my_issues_in_briefing`, …). Two Swift
readers parse the raw YAML for exactly that spelling and never go through Go:
`Utilities/JiraKeyExtractor.swift:173` and `Services/ConfigService.swift:133`. Do not change them —
they are already right.

**Do not add a `SetDefault` to the writer's viper.** Probed: a default on a viper instance leaks
into `WriteConfigAs` output. Task 3 adds defaults to `config.Load`'s viper only, which is never
written.

**The test that does not exist anywhere and is the point of this task:** write through the real
writer, read back through the real `config.Load`, assert the flag is on. Every existing test in
both languages asserts on a struct the test itself built, which is why the bug survived — see
`verify-C1-features.md` §6. Put it in `cmd/` next to `cmd/features_test.go`'s round-trip test.
Cover: enable, disable, reset, and an unknown flag name. `internal/config/feature_migrate_test.go`
is the closest existing model.

**Done when:** `jira features enable <name>` followed by a fresh `config.Load` observes the flag
`true`, pinned by a mutation-checked test.

---

## Task 2 — One-time repair of configs carrying the dead keys

**Decision 4**, the clause "*one-time config migration deletes the broken lowercase block (the
`MigrateFeatureGates` precedent)*". Read `verify-C1-features.md` §5c — it describes the precedent's
structure in full, and §7 trap 1 for why this is required and not cosmetic.

Every install whose toggles were ever touched carries eleven squashed keys under `jira.features`.
Leaving them is not decode-harmful (the snake key wins, order-independent — probed) but it
**silently discards the owner's intent**: a `teamworkload: true` the owner set stays inert forever
while the repaired reader sees only the absent snake key.

So the migration is **value-preserving, not a delete**: for each of the eleven, if the squashed
spelling is present under `jira.features`, write its value under the long snake spelling, then
remove the squashed key. A snake key already present wins — never overwrite an explicit value the
owner or task 1 wrote.

Copy `config.MigrateFeatureGates`' shape (`internal/config/feature_migrate.go:65-94`):

- a fresh `viper.New()` on the path, `ReadInConfig`; missing file ⇒ clean no-op;
- a **marker key** making it one-time. It must NOT live under `jira.features` — that subtree is
  enumerated as toggles. Use a sibling: `jira.features_migrated`;
- edit through `patchConfigYAML`/`setYAMLPath` (`:135`, `:174`), never `WriteConfigAs`: comments,
  key order and the casing of `workspaces.<Team>` all survive that way. Both helpers are
  unexported in `internal/config`, which is where this migration belongs too;
- atomic 0600 write via `writeFeatureMigrationConfigBytes`.

`setYAMLPath` currently only *writes* bool scalars and there is no deletion helper — add a small
one (remove the key/value pair from `node.Content`) in the same file, in the same style.

**Callers:** daemon start, next to where `MigrateFeatureGates` is already called, and the top of
every `jira features` subcommand (list, enable, disable, reset). **Order matters and is
load-bearing: migrate first, then read or write.** A `jira features enable` that writes before
migrating would be repaired by a migration that then reads a file it no longer describes.

**Tests:** a legacy file with squashed keys (mixed true/false) migrates to snake keys with values
preserved, squashed keys gone, marker stamped; a second run is a byte-identical no-op; a file with
both spellings keeps the snake value; a file with neither is untouched apart from the marker; a
comment and a mixed-case `workspaces.<Team>` key survive the rewrite (this last one is what
`patchConfigYAML` exists for — assert it).

**Done when:** an install that had `teamworkload: true` reads `TeamWorkload == true` through
`config.Load` after one migration, and running the migration twice changes no bytes the second
time.

---

## Task 3 — An absent flag means the role default, not `false`

**Decision 4**, the clause "*seed role defaults via `SetDefault` so an absent key means the role
default, not false*". Read `verify-C1-features.md` §5b and §5d, including trap 8.

There is no `SetDefault` for any `jira.features.*` key today, so a pristine install — one that has
never run `jira features` — has all eleven flags off, and the roadmap's promised "defaults based on
user role on first connection" was never implemented at all.

Add the eleven `SetDefault` calls to `config.Load`, next to `internal/config/config.go:490-491`.
Probed: a `SetDefault` on the `Load` viper does make an absent key decode `true` through the nested
struct `Unmarshal`.

**Seed the IC baseline** — `config.DefaultJiraFeatures(config.DefaultJiraFeaturesRole)` — not a
per-role set. **Ruling, and the reasoning must survive in a comment:** `Load` has no DB handle, and
the role lives in `user_profile.role`, which is **free text** collected from an onboarding
`TextField` placeholdered *"e.g. Engineering Manager"*. The structured `RoleLevel` exists in Swift
(`WatchtowerCore/Models/UserProfile.swift:134-195`) but is never persisted, so `DefaultJiraFeatures`
already falls to its IC branch for every real user — `jira features reset` has always reset to IC.
Seeding the IC baseline is therefore not an approximation of the role default; today it **is** the
role default for everyone. Do not add a connect-time writer to chase the role: that would be a
second writer of the same keys, for a role value that does not exist yet.

Add a brief note to the same comment that wiring real role levels is a separate piece of work.

**Interaction with task 2, and you must assert it:** on a migrated install every touched flag has
an explicit key, so the defaults do not apply to it — the owner's `false` stays `false`. Defaults
apply only where the key is genuinely absent. Test both.

**This is a behaviour change on pristine installs**, deliberately: `my_issues_in_briefing`,
`awaiting_my_input`, `who_ping` and `track_jira_linking` become true, so the daily briefing gains
its MY JIRA ISSUES and AWAITING MY INPUT sections and tracks/digests gain Jira badges. That is what
decision 4 asks for. Note it in your report; the controller surfaces it to the owner.

**Done when:** a config with no `jira.features` block decodes the IC baseline; a config with an
explicit `false` for one of those keys still decodes `false`.

---

## Task 4 — Give `jira_slack_links` an identity per link kind

**Prerequisite for tasks 5 and 6.** Read `verify-H1-detector.md` §2 — the defect is described there
in full with the upsert quoted.

`jira_slack_links` has `UNIQUE(issue_key, channel_id, message_ts)` (`00001_init.sql:893-903`) and
`UpsertJiraSlackLink` (`internal/db/jira.go:556-568`) conflicts on it. But only `ProcessMessage`
writes a real `message_ts`; `ProcessTrack` and `ProcessDigestDecision` both write `message_ts = ""`.
Consequences, all of them silent loss:

- a track link and a digest-decision link for the same `(key, channel)` are **one physical row**,
  with `link_type` flip-flopping to whichever wrote last;
- every later track mentioning `PROJ-1` in the same channel **overwrites** the previous `track_id`,
  so only the most recent track is ever linked;
- `storeDigest` is shared with daily/weekly rollups, which pass `channelID = ""`
  (`internal/digest/pipeline.go:1413`, `:1485`), so all rollup decision links collapse onto
  `(key, "", "")` — one row per issue key for the entire workspace;
- `internal/db/jira_dashboards.go:378-388` counts `link_type = 'decision'` over that flip-flop.

The three link kinds have three different natural identities:

| kind | identity |
|---|---|
| `mention` | `(issue_key, channel_id, message_ts)` |
| `track` | `(issue_key, track_id)` |
| `decision` | `(issue_key, digest_id)` |

Migration **00067**: recreate the table without the inline `UNIQUE` and create three partial unique
indexes, one per kind. **The table is empty on every install in existence** — it has never had a
writer (task 5/6 are what give it one), so the recreation carries no data-preservation burden and
the `Down` is symmetrical. Verify that claim yourself before relying on it rather than taking it
from this plan.

Split `UpsertJiraSlackLink` into the three upserts, each with an `ON CONFLICT` target matching its
index. Keep one exported entry point if that reads better, but each kind must conflict on its own
identity. Keep the existing `COALESCE` merge semantics within a kind.

Mirror into `internal/db/schema.sql`, regenerate the golden snapshot. `jira_slack_links` is an
existing table, so `TestAllTablesExist` already covers it.

**Tests:** two tracks mentioning the same key in the same channel produce two rows, both linked;
a track link and a decision link for the same key and channel coexist; two rollup decisions for
different digests do not clobber each other; re-writing the same mention is idempotent.
Mutation-check by restoring the single unique constraint.

**Done when:** each link kind round-trips without displacing another kind's row, pinned by tests
that fail against the old constraint.

---

## Task 5 — The detector must not invent keys

**Prerequisite for task 6.** Read `verify-H1-detector.md` §2, points 1–3, and §7.

`DetectKeys` (`internal/jira/key_detector.go:34-65`) filters candidate `[A-Z][A-Z0-9_]+-\d+` tokens
against the known project keys from `db.GetKnownProjectKeys()`. When that set is **empty it accepts
everything** (`:60`, `if len(known) == 0 || known[proj]`). The set is loaded once through a
`sync.Once` whose `ResetCache` (`:145`) has zero production callers, and a load error is swallowed
into the same accept-all path (`:36-38`).

Nothing has ever run this code, so the fallback has never hurt anyone. Task 6 gives it a caller on
every synced Slack message — at which point `UTF-8`, `COVID-19`, `SHA-256`, `HTTP-2` and `RFC-9728`
all become "Jira keys" written into a table that feeds AI prompts, the Desktop, and the
`get_task_context` dev surface.

Two changes:

1. **Empty known-key set ⇒ detect nothing.** A load error takes the same path: unknown means no,
   never yes.
2. **Memoize only a non-empty result.** Otherwise a daemon that starts before the first Jira sync
   caches the empty set for its whole lifetime and never detects anything again — the same bug in
   the other direction. Reloading while the set is empty is a cheap `SELECT DISTINCT` over two
   small tables. Keep `ResetCache` working for the tests that use it.

**`TestKeyDetector_DetectKeys_NoKnownKeys` (`internal/jira/key_detector_test.go:55`) deliberately
pins the accept-all fallback and must be inverted.** It is not a `Test<Module>NN_` guard and pins
no inventory contract, so Global Constraint 5 does not forbid this — but rewrite it in place under
a name that states the new rule, and make its body assert the *stronger* fact (no keys detected
against an empty DB). Say in your report that you changed it and why.

**Done when:** an empty Jira dataset yields zero detections, a project key that lands after the
first call is picked up without a process restart, and both are mutation-checked.

---

## Task 6 — Wire the detector

**Decision 5**, "*wire it in `cmd/sync.go` + a test*". Read `verify-H1-detector.md` §1, §3, §4 and
§5. Depends on tasks 4 and 5.

`NewKeyDetector` and both `SetJiraKeyDetector` hooks have had **zero production callers since the
commit that introduced them** (`deddd91f`) — confirmed by grep and by `git log -S`. The table has
never been written, so `--jira`/`--no-jira`, the Desktop "Linked Jira Issues" badges,
`get_task_context`'s Slack threads, `find_experts`' linked-thread evidence, who-to-ping and
`DetectChannelsWithoutJira` have all silently returned nothing since the feature shipped.

**Namespacing is already correct — verify it, do not re-derive it.** Both hooked call sites feed
the detector ids that came out of 00048-namespaced columns, and every reader that touches
`channel_id` joins it against `messages.channel_id` / `channels.id` / `digests.channel_id`. Write
form and read form agree. Key extraction is unaffected either way: Slack ids contain no `-`, so no
namespace prefix can produce a false key match. `verify-H1-detector.md` §3 has the full table.

**Three wiring points:**

1. **Daemon** — `cmd/sync.go:542-546`, right after the two pipelines are constructed. One shared
   `jira.NewKeyDetector(database)` instance passed to both `SetJiraKeyDetector` calls, so the
   known-key cache is loaded once, not twice.
2. **One-shot CLI path** — `cmd/sync.go:950-952` constructs its own `pipe`/`tracksPipe`. Wire it
   the same way; leaving it unwired would be a silent asymmetry.
3. **Per-message detection** — `ProcessMessage` has no hook anywhere, and it is the *only* one that
   matters to the four flagship readers: they all skip rows with an empty `message_ts`
   (`internal/tools/taskcontext.go`, `internal/tools/experts.go`, `internal/jira/blockers.go`), so
   **wiring only the digest and tracks hooks leaves `get_task_context` exactly as empty as it is
   today.** Hook it into `internal/sync/message_sync.go:393` `upsertMessagePage`, **after** the
   page's `tx.Commit()` (`:446`) — on rollback there is no message to link to. `channelID` is
   already namespaced there and `msg.Timestamp` is the raw ts, which is exactly the `(channel_id,
   ts)` pair `messages` uses. Give `sync.Orchestrator` an optional detector field, the same shape
   `digest` and `tracks` already use, wired in `wireSlackSyncers` (`cmd/sync.go:616`).
   **Batch the writes**: `UpsertJiraSlackLink` is one `Exec` per detected key per message today,
   outside any transaction. An initial sync of a Jira-heavy workspace would serialise one
   round-trip per mention. Write the page's links in one transaction.
   Apply the same hook to the search-sync writer (`internal/sync/search_sync.go:307`) or state in
   your report why not.

**Gate: `cfg.Jira.Enabled`, and nothing else.** It is false by default but `jira add` / `jira login`
flip it true via `enableJiraPhase`, so it is true on exactly the installs that have Jira. **Do not
gate on any `jira.features.*` flag** — until tasks 1–3 land those are structurally false, and even
after them a feature gate here would make a data-collection step invisible to the owner. Do not
invent a new config key (Global Constraint 7).

**Forward-only. No backfill in this wave** — controller ruling. A history-wide pass over `messages`
is a real command with a `--since` window, a dry-run, a resume story and a refusal when
`GetKnownProjectKeys()` is empty, and it belongs with the operator runbook the owner has not run
yet, not bolted onto a wiring change. The bounded alternative (re-processing `digest_topics` and
`tracks`) is cheap but feeds only the weakest surfaces. Recorded as a follow-up; say nothing in the
code about backfilling.

**Tests:** a call-site test asserting the detector receives the same `channel_id` value that lands
in `messages`/`channels` (namespaced) — the existing hook tests only assert the setter stores a
value, and every fixture in `key_detector_test.go` uses bare `"C1"`. Update those fixtures to
`"1:C1"` (zero behavioural risk, they treat the id as opaque) so they stop encoding the pre-00048
world. Add a wiring test that fails if the daemon path stops wiring the detector.

**Done when:** a synced message mentioning a known project key produces a `mention` row with the
namespaced channel id and the real ts, and the daemon wiring is pinned by a test.

---

## Task 7 — Repair `jira_issues.assignee_slack_id` / `reporter_slack_id`

**Root cause 1, consumer #5.** Read `verify-jira-data.md` Finding A in full — the audit
under-states this in two ways and the report closes both.

Migration 00048 namespaced `jira_user_map.slack_user_id`, `calendar_attendee_map.slack_user_id` and
`jira_slack_links.channel_id`, but **no `UPDATE jira_issues`** — neither `assignee_slack_id` nor
`reporter_slack_id`, and 00054 (JSON columns) does not mention the table either. It is a scalar
column both migrations simply missed. The column is therefore **mixed**: rows last written before
2026-08-03 carry bare `U123`, rows re-upserted since carry `1:U123`, and because Jira sync is
incremental by `updated_at`, the bare population never drains.

Readers that compare against an external identity (`GetCurrentUserID`, `people_cards.user_id`,
`calendar_attendee_map.slack_user_id`) silently return nothing for bare rows — MY JIRA ISSUES,
AWAITING MY INPUT, the day plan's Jira work, meeting-prep attendee workload, the Person detail's
delivery stats. Readers that group *by* the column propagate the bare form outward instead,
including onto the screen (`WorkloadPersonDetailView.swift:41`), into `find_experts` where one
human splits into two candidates (`internal/tools/experts.go:293-320`, and DEV-03 promises
evidence), and into the memory vault as a second parallel person entity
(`internal/memory/jira_ingest.go:223-226`) — the exact class `memory migrate-slack-ids` exists to
clean up.

**Ruling: re-derive, do not prefix-guess.** `db.BackfillJiraSlackIDs` (`internal/db/jira.go:450-467`)
already copies the correct value from `jira_user_map` — which 00048 *did* namespace — keyed by
`assignee_account_id`, an Atlassian id no migration touched. Its `AND assignee_slack_id = ''` guard
is the only reason stale rows survived: it fills empty cells and never corrects wrong ones. Relax
the guard so a stored value that disagrees with the map is corrected too. This needs no Slack
account id, so the whole zero/one/multiple-Slack-account question the `memory migrate-slack-ids`
precedent has to answer does not arise, and there is no guess to get wrong. Rows with no Atlassian
account id or no map entry are left alone.

**Close the source, or the repair re-opens.** Two live paths still write bare ids into
`jira_user_map`, from which they propagate onto issues:

- `cmd/jira.go:926-955` `jira users map <jira_account_id> <slack_user_id>` takes argv verbatim;
- `internal/jira/users.go:102-108` applies `cfg.Jira.UserMap` from config.yaml and **overrides** an
  already-correct email/fuzzy match.

Namespace and validate both against `users.id` — an operator typing the `U0123ABCD` they see in
Slack must land a usable value, and an id that matches no `users` row should be reported, not
stored. Making the backfill authoritative over the column is then consistent rather than
destructive: `jira_user_map` becomes the single source of truth.

**Adjacent defect, and it is why the repair alone is not enough
(`verify-jira-data.md` §A6):** `UserMapper.ResolveAll` has exactly two callers, both CLI —
`jira users resolve` and the end of a manual `jira sync`. **`phaseJiraSync` never calls it.** On a
daemon-driven install — the normal one — every Jira user first seen since the owner's last manual
sync gets a shell `jira_user_map` row with an empty `slack_user_id`, so `convertIssue` writes `""`
and it stays empty forever. Fixing the historical rows while new ones keep arriving empty is
precisely the half-fix this programme exists to stop. Call the resolve step and the backfill once
per account in `phaseJiraSync`, after that account's `Sync` returns cleanly. Keep it out of the
`ErrAuthRevoked` and cancelled-context paths, and do not let a resolve failure change the account
status — the CLAUDE.md rule that `phaseJiraSync` may write only `"revoked"` still holds.

**Tests:** none exist — `BackfillJiraSlackIDs` has no test at all, and every fixture that sets
`AssigneeSlackID` uses the bare form self-consistently, which is why no test can see this bug.
Write: a bare stored id with a namespaced map entry is corrected; an empty cell is still filled;
a row with no map entry is untouched; `jira users map` with a bare argument stores the namespaced
form; a daemon pass resolves and backfills. Mutation-check each.

**Do not renumber or rewrite migration 00048.** It has shipped; the repair is code that runs on
every pass, not a rewrite of history.

---

## Task 8 — Persist and show per-project Jira sync errors

**Audit M1.** Read `verify-jira-data.md` Finding B — it confirms the finding and adds the half the
audit missed.

`Syncer.Sync` (`internal/jira/sync.go:132-142`) sets `syncState.LastError` and `LastErrorAt`, then
calls `UpdateJiraSyncState(accountID, projectKey, lastSyncedAt, issuesSynced)`
(`internal/db/jira.go:508-520`), which names four columns and updates two. The two assignments are
**dead code in the literal sense**: on the error branch the call re-writes the row with the values
it just read out of it, and the struct falls out of scope at `continue`. Deleting those six lines
changes no test outcome and no observable behaviour — exactly what a mutation check catches.

Both columns exist and always have (`00001_init.sql:913-917`, carried through 00049's composite-PK
recreation), `internal/db/schema.sql:960-966` mirrors them, and both Go readers and the Swift model
already select and decode them. **No migration is needed.**

Two halves, and the fix needs both:

1. **Persist.** Extend `UpdateJiraSyncState` to carry the error text and timestamp.
   **Clear on success** — the success branch (`internal/jira/sync.go:144-151`) writes them empty
   alongside the timestamp. *Ruling:* the column names are singular and sit next to
   `last_synced_at`; "the error, if any, from the most recent attempt" is what every reader assumes
   and what `slack_accounts`/`google_accounts` `status`/`error` already mean. The alternative —
   never clearing — makes `jira status` show a recent sync next to a weeks-old error with no way to
   tell which is current, which is *more* misleading than today's silence. A flapping project loses
   its history under this choice; that is the accepted cost, and a `consecutive_failures` counter
   is the follow-up if intermittent failures turn out to be common. Say so in a comment.
2. **Render.** `jira status` (`cmd/jira.go:769-775`) prints a line only when `LastSyncedAt != ""`
   and never mentions the error, so **populating the column alone changes nothing an operator can
   see** — a project that has failed every pass since it was added shows no line at all, which
   reads identically to "not configured". Print the error when present, and print a line for a
   project that has never synced successfully.

This does **not** conflict with the rule that `phaseJiraSync` may write only `"revoked"` to an
account's status. That rule is about the account row's grant health, whose reason is that a
transient failure must not strand a red badge only a re-login can clear. This is a different table,
keyed per project, driving no Re-login button, with a natural clear condition the code is already
in a position to write. The two are orthogonal; the columns were designed for this in 00001.

**Tests:** a failing project records the error and the timestamp; a subsequent success clears both;
`jira status` renders an errored project and a never-synced one. No guard test exists to break.

---

## What this wave deliberately does not do

- **`jira_slack_links` backfill** (task 6's ruling) — forward-only; the history pass is a follow-up
  command with its own dry-run and operator step.
- **The Desktop "Sync now" / "Resolve users" failure with two Jira sites** (audit H2) — real, but
  outside the scope line, and single-site installs are unaffected.
- **`who_ping` and `write_back` gate nothing**, and `BuildFeatureContext` has no callers
  (`verify-C1-features.md` §4) — owner decision **D4** in the audit was never taken. Task 3 will
  turn `who_ping` on by default, where it will continue to gate nothing. Surface it; do not
  unilaterally wire or delete either flag.
- **Real role levels.** `user_profile.role` is free text and `RoleLevel` is never persisted, so the
  roadmap's per-role defaults cannot work yet (task 3's ruling). Fixing that is its own piece of
  work.
