# Import rules: `findings.json` → triage Artifact

How the wrapper turns one validated engine run into writes on the triage Artifact's `db`
(spec `docs/superpowers/specs/2026-11-20-security-audit-team-design.md` §7). The rules
are deterministic: the same run dir and the same Artifact state give the same writes.
The one judgement call is rule 5 (`legacy_match`), which only proposes and is marked as a
proposal on the page.

Every example below is invented (`internal/example/…`, `example:…` fingerprints, legacy
ids `EX-n`). None of it describes Watchtower.

## Conventions

**Doc id.** `findings/<doc-id>`, where `<doc-id>` is the first 16 hex characters of the
SHA-256 of the engine fingerprint's UTF-8 bytes, no trailing newline:
`printf %s "$fp" | shasum -a 256 | cut -c1-16`. A baseline row is `legacy-<legacy_id>`.

| Fingerprint (invented) | Doc id |
|---|---|
| `example:path-traversal:readfile` | `5f1cb9c01e53f362` |
| `example:ssrf:fetch-preview` | `063e7700b0564553` |
| `example:token-log:debug-dump` | `e131db3e893fe77e` |
| `example:race:cache-write` | `1a05eaa8b4612ea2` |

**Run id.** `run_id` from the run's `run-metadata.json`; it names `runs/<run-id>` and is
the value of `first_seen_run` / `last_seen_run`.

**Field ownership** (spec §7 — the names are exact):

- *Content fields*, copied from the `findings.json` record: `verdict`, `title`,
  `description`, `root_cause`, `claimed_root_cause`, `trace`, `evidence`, `blockers`,
  `validation_plan`, `remediation`, `severity`, `reason`. The engine's other record
  fields (`intended_behavior`, `conditions`, `execution`, `confidence`) are not copied;
  they stay in the engine run dir.
- *Run fields*: `first_seen_run`, `last_seen_run`, `run_state`, and `legacy_match`
  (rule 5 only).
- *Create-only fields*: `fingerprint` (engine docs), `legacy_id` (baseline docs), and on
  create only `status` and `note`: a record with verdict `rejected` gets
  `status: "false_positive"` and `note: "Rejected by the engine's verifier."`; every other
  new record gets `status: "open"` and no `note`; a baseline doc gets the row's `status`
  (`open` when the row has none) and `note`.
- *Owner fields*: `status`, `note`, `disputed`, `legacy_decision`, `merged_into`.
  `disputed: true` is written only by the page (the owner's Dispute button, or the owner
  moving a `rejected` doc to `open`/`in_progress`). **No `update` op ever names an owner
  field.** The wrapper writes `status` and `note` only inside a
  `set` that creates a doc that did not exist.

**Ops.** A doc that does not exist is created with a `set` write. A doc that exists is
changed with an `update` write (merge), naming content and run fields only, and pinned
with `if_version` = the `version` the rule 1 read returned (or the version a `set` of this
import returned). The wrapper never `set`s an existing `findings` doc and never `delete`s a doc; the one
`set` on an existing doc is the run row on a re-import (rule 7), pinned like an update. The
examples show writes as entries of `ArtifactData batch`'s `writes` array.

**An owner edit during the import.** The owner may change `status`, `note` or a legacy
decision on the page while the import runs. The pinned `update` then fails without
writing (the whole batch writes nothing); the wrapper re-`get`s the docs the failure
names, recomputes their writes from the fresh doc (rule 3 reads the new `status`), and
sends the batch again — at most 3 such retries per batch; a 4th conflict stops the
import with "the report kept changing during the import; re-run `/security-audit import
<run-dir>`". The owner's edit is never overwritten: no update names an owner
field, and no write lands on a version the wrapper did not read.

---

## Rule 1 — Read the run and the report

Inputs, in this order:

1. `<run-dir>/run-metadata.json` → `run_id`, `run_status`, `incomplete_reason`,
   `profile`, `budget`, `source_ref` (the pinned SHA).
2. `<run-dir>/findings.json` and `<run-dir>/coverage-ledger.json`. The engine validated
   both; the wrapper re-runs `node <engine>/validate-findings.cjs <run-dir>/findings.json`
   and `node <engine>/validate-coverage-ledger.cjs <run-dir>/coverage-ledger.json` before
   importing, because `/security-audit import <run-dir>` can be pointed at any dir. A
   failure imports nothing.
3. `ArtifactData list findings` (every page) and `ArtifactData list runs` — the state the
   rules below compare against, each doc with its `version` (including
   `runs/<run-id>` when an earlier attempt of this import already wrote it). Read once, at import time (not reused from the triage-in
   step: the owner may have edited since).

**Example.** Run dir `…/watchtower/run-7/`:

```json
// run-metadata.json (excerpt)
{"run_id": "run-7", "source_ref": "bbbb2222", "profile": "standard",
 "budget": 40, "run_status": "complete", "incomplete_reason": null}
```

`findings.json` holds three records (`example:path-traversal:readfile`,
`example:ssrf:fetch-preview`, `example:token-log:debug-dump`); the ledger holds four
units; `list findings` returns docs `5f1cb9c01e53f362` (status `open`, version 4),
`e131db3e893fe77e` (status `accepted`, version 7), `1a05eaa8b4612ea2` (status `open`,
version 3) and the two disputed docs of rule 6's example; `list runs` returns `run-6`
(a Full, `sha: "aaaa1111"`). Both validators exit 0 → continue. The later examples use
this state.

## Rule 2 — One doc per record: create or update

For each record in `findings.json`, compute its doc id.

- **No doc** → `set findings/<doc-id>` with `fingerprint`, every content field the record
  has, `first_seen_run = last_seen_run = <run-id>`, `run_state: "new"`, and:
  - verdict `rejected` → `status: "false_positive"`,
    `note: "Rejected by the engine's verifier."`;
  - verdict `confirmed` or `needs_validation` → `status: "open"` (no `note`).

  A doc becomes disputed (rule 6's list) only by an owner act: the page writes the owner
  field `disputed: true` when the owner presses Dispute or moves a `rejected` doc to
  `open`/`in_progress`. The wrapper never writes `disputed`.
- **Doc exists** → `update findings/<doc-id>` with **all twelve content fields** (a field
  the record does not carry is written as `{"__delete__": true}`, so a verdict change
  removes the old verdict's fields), `last_seen_run = <run-id>`, and `run_state` from rule 3. Nothing
  else.
- **Verdict flips to `rejected` on an existing `open`/`in_progress` doc** → the same
  `update`; it is the wrapper's observation, not a dispute: the owner's `status` stays,
  no `disputed` is written, and rule 3 gives `run_state: "still_open"`. The page labels
  it **The engine now rejects it**; the owner sets False positive or disputes it.
- **Re-import of the same run** (doc exists and its `first_seen_run` equals this run id):
  same `update`, with `run_state: "new"` — the earlier attempt created it.

**2b — Baseline rows on the first import.** When `list findings` returned no docs at all
(a new report), the import also creates one doc per row of `baseline-import.json`:
`set findings/legacy-<legacy_id>` with `legacy_id`, `status` and `note` from the row —
nothing else (`surface` and `files` stay in the file; rule 5 reads them from there). A
row carries `status` only where the old audit already published it (`fixed` or
`accepted`); a row without one is created with `status: "open"`, and the owner adjusts
it in the Artifact.
These creates come before rule 5.

**Example (create).** Record `example:ssrf:fetch-preview` → doc `063e7700b0564553`, not
in `list findings` →

```json
{"op": "set", "collection": "findings", "doc_id": "063e7700b0564553",
 "data": {"fingerprint": "example:ssrf:fetch-preview", "verdict": "rejected",
   "title": "Link preview fetches attacker-chosen hosts",
   "description": "A URL from a synced message is fetched for its preview.",
   "claimed_root_cause": "internal/example/preview.go dials the URL host without a private-range check.",
   "trace": [
     {"kind": "entrypoint", "file": "internal/example/sync.go", "line": 52, "scope": "SyncMessages", "description": "URL taken from the remote message."},
     {"kind": "sink", "file": "internal/example/net.go", "line": 30, "scope": "FetchPreview", "description": "http.Get on the URL."}],
   "evidence": [{"file": "internal/example/net.go", "line": 24, "description": "isPrivate(host) checked before dialing."}],
   "reason": "The preview fetcher refuses private ranges before dialing (internal/example/net.go:24).",
   "first_seen_run": "run-7", "last_seen_run": "run-7",
   "run_state": "new", "status": "false_positive",
   "note": "Rejected by the engine's verifier."}}
```

The record has no `root_cause`, `blockers`, `validation_plan`, `remediation` or
`severity`, so the `set` leaves them out.

**Example (owner disputes a rejected record → disputed next run).** After this run the
owner disagrees with the verifier on `063e7700b0564553`, presses Dispute on the page
(which writes `status: "open"`, `disputed: true`) and saves
`note: "Redirects are followed after the private-range check."`.
The doc now has `verdict: "rejected"`, `status: "open"` and `disputed: true`. At the next run's
triage-in the wrapper lists `example:ssrf:fetch-preview` as **disputed** with that note;
the engine must re-validate it, and rule 6 checks that it did. A `rejected` doc the owner
leaves at `false_positive` is handed over as an ordinary suppressed claim instead.

**Example (update).** Record `example:path-traversal:readfile` → doc `5f1cb9c01e53f362`
exists (owner status `open`); the record is `needs_validation` with `claimed_root_cause`,
`trace` (`internal/example/sync.go` → `internal/example/files.go`), `evidence`,
`blockers` and `validation_plan` →

```json
{"op": "update", "collection": "findings", "doc_id": "5f1cb9c01e53f362", "if_version": 4,
 "data": {"verdict": "needs_validation", "title": "…", "description": "…",
   "root_cause": {"__delete__": true}, "claimed_root_cause": "…", "trace": [/*…*/], "evidence": [/*…*/],
   "blockers": ["…"], "validation_plan": {"local": "…"}, "remediation": {"__delete__": true},
   "severity": {"__delete__": true}, "reason": {"__delete__": true},
   "last_seen_run": "run-7", "run_state": "still_open"}}
```

## Rule 3 — `run_state` of an existing doc that the run found again

Read from the doc's current owner `status` and the record's verdict:

| Owner `status` | Record verdict | `run_state` | Counted in the open totals (rule 7) |
|---|---|---|---|
| `fixed` | any | `regressed` | yes, and in `counts.regressed` |
| `open`, `in_progress` | any | `still_open` | yes |
| `accepted`, `false_positive` | `confirmed`, `needs_validation` | `resurfaced` | **no**; in `counts.resurfaced` |
| `accepted`, `false_positive` | `rejected` | `still_open` | **no** (`rejected` is counted as always) |

The engine was told to suppress unchanged `accepted`/`false_positive` claims (spec
§5.1), so one coming back as a live claim means the code behind it changed:
`run_state: "resurfaced"`. The page's default filter shows a doc resurfaced in the
selected run with a **Resurfaced** chip, the terminal Summary lists its fingerprint, and
the owner decides again. The wrapper never moves `status`.

**Example — owner edit survives (Review Focus 4).** Doc before the import:

```json
// findings/e131db3e893fe77e
{"fingerprint": "example:token-log:debug-dump", "verdict": "confirmed",
 "title": "Debug dump logs the bearer token", "first_seen_run": "run-6",
 "last_seen_run": "run-6", "run_state": "new",
 "status": "accepted", "note": "Dev builds only; tracked separately."}
```

This run's `findings.json` has `example:token-log:debug-dump` again (`confirmed`,
`overall_severity: "low"`) because the logger changed. The op names wrapper fields only:

```json
{"op": "update", "collection": "findings", "doc_id": "e131db3e893fe77e", "if_version": 7,
 "data": {"verdict": "confirmed", "title": "Debug dump logs the bearer token",
   "description": "…", "root_cause": "…", "claimed_root_cause": {"__delete__": true},
   "trace": [/*…*/], "evidence": [/*…*/], "blockers": {"__delete__": true}, "validation_plan": {"__delete__": true},
   "remediation": {"strategy": "…"}, "severity": {"overall_severity": "low", "likelihood": {…}, "impact": {…}},
   "reason": {"__delete__": true}, "last_seen_run": "run-7", "run_state": "resurfaced"}}
```

Doc after the merge: `status: "accepted"` and `note: "Dev builds only; tracked
separately."` are byte-identical — no op named them. If the owner edits `note` while the import runs, the pinned update
fails, the wrapper re-reads the doc (now version 8) and resends the same wrapper fields
pinned to 8 — the new note stays. The record is not counted in `counts.by_verdict` /
`counts.by_severity`; it is counted in `counts.resurfaced`.
Had the owner's status been `fixed`, the same op would carry `run_state: "regressed"`.

## Rule 4 — Open docs the run did not find again

Applies to docs with a `fingerprint` (never `legacy-*` docs), owner `status` `open` or
`in_progress`, and no record in this run's `findings.json`. Docs with any other status
are not written.

1. **Find the doc's units.** Open the coverage ledger of the doc's `last_seen_run`: that
   run row's `engine_run_dir` + `/coverage-ledger.json`, or, once the run was archived,
   `~/security-audit-skill/watchtower-archive/<last_seen_run>/coverage-ledger.json`
   (wrapper `SKILL.md`, Retention). The doc's units are the
   `coverage_id`s whose `result_fingerprints` — live or in any `attempts[]` entry —
   contain the doc's fingerprint. No such ledger, or no unit → **no write** (skip
   reason *no ledger*).
2. **Covered this run?** Look each `coverage_id` up in this run's ledger. Every one must
   be present with live `status: "covered"`. Any one `deferred`, `out_of_scope`,
   `blocked`, `planned`, `in_progress`, `candidate`, `not_applicable` or absent → **no
   write** (skip reason *not covered*).
3. **Source changed?** The doc has no `trace[].file` → **no write** (skip reason *no
   trace files*: a pathspec-less diff would compare the whole tree). Otherwise
   `git -C <source repo> diff --quiet <sha of last_seen_run> <this run's sha> -- <every
   distinct trace[].file of the doc>`, where `<source repo>` is the run's
   `watchtower_source_repo` (the Watchtower checkout, `REPO`; the target worktree may be
   gone). Exit 0 (unchanged) → `run_state: "not_refound"`; exit 1 (changed) →
   `run_state: "fixed"`; any other exit (a sha the repo does not have, an unreadable
   repo) → **no write** (skip reason *could not compare*).

Each skip is counted by reason; the terminal Summary shows the counts (wrapper
`SKILL.md`, Summary), so a doc left untouched for a missing ledger or a failed diff is
not silent.

The op is `update` with `run_state` only — `last_seen_run`, content fields and `status`
stay; `run_state: "fixed"` is the wrapper's observation, the owner's `status` decides.

**Example — covered.** Doc `1a05eaa8b4612ea2` (`example:race:cache-write`, status `open`,
`last_seen_run: "run-6"`, trace files `internal/example/cache.go`,
`internal/example/store.go`). In `run-6`'s ledger the fingerprint sits in
`result_fingerprints` of unit
`internal%2Fexample%2Fcache.go%23Put::internal%2Fexample%2Flock.go%23mu::internal%2Fexample::ATTACK-CLASSES.md%23Race%20conditions`.
This run's ledger has that unit with:

```json
{"coverage_id": "internal%2Fexample%2Fcache.go%23Put::…%23Race%20conditions",
 "status": "covered", "agent_id": "hunter-03",
 "reviewed_paths": ["internal/example/cache.go", "internal/example/lock.go"],
 "local_checks": [{"agent_id": "hunter-03", "reviewed_paths": ["internal/example/cache.go", "internal/example/lock.go"],
   "invariant": "Put holds mu across read and write.", "method": "source", "result": "Holds.", "artifact": null}],
 "result_fingerprints": [], "unresolved": []}
```

`git diff --quiet aaaa1111 bbbb2222 -- internal/example/cache.go internal/example/store.go`
exits 1 →

```json
{"op": "update", "collection": "findings", "doc_id": "1a05eaa8b4612ea2", "if_version": 3,
 "data": {"run_state": "fixed"}}
```

Exit 0 instead → `{"run_state": "not_refound"}`.

**Example — incomplete run (Review Focus 5).** Same doc, but the run stopped on budget:

```json
// run-metadata.json
{"run_id": "run-7", "run_status": "incomplete",
 "incomplete_reason": "validation_budget_exhausted"}
// coverage-ledger.json, the doc's unit
{"coverage_id": "internal%2Fexample%2Fcache.go%23Put::…%23Race%20conditions",
 "status": "deferred", "agent_id": null, "reviewed_paths": [], "local_checks": [],
 "result_fingerprints": [], "unresolved": ["Budget exhausted before wave 2."]}
```

The unit is `deferred` → **no write** for `1a05eaa8b4612ea2`: its `run_state` stays what
the previous run set, even though `cache.go` changed. A unit left `candidate` with an
unvalidated fingerprint (the engine keeps those out of `findings.json` on an incomplete
run) is equally **no write**. On an incomplete run the import still runs rules 2, 3, 5,
6 and 7 for what `findings.json` does hold; rule 4 writes only for units the ledger
marks `covered`, so no doc outside them becomes `fixed` or `not_refound`.

## Rule 5 — Propose `legacy_match` (after rules 2–4)

The engine's schema has no field for it, so the wrapper decides after the import. For
each doc **created this run** — its `first_seen_run` equals this run id, which also
covers a doc an earlier attempt of this import created (rule 8 re-import):

1. **Candidates**: rows of `baseline-import.json` whose `files` share at least one path
   with the record's `trace[].file` or `evidence[].file`. A `files` entry ending in `/`
   matches every file under it. Skip a row whose `legacy-<legacy_id>` doc has
   `merged_into` set.
2. **Compare**: the parent reads the record's `root_cause` (or `claimed_root_cause`) next
   to each candidate's `note` and picks the one describing the **same weakness** — the
   same missing control at the same sink, not just the same file. None fits, or two fit
   equally → no proposal.
3. **Write** only when the doc's `legacy_match` is empty and `legacy_decision` is unset:
   `update findings/<doc-id>` with `legacy_match` only, pinned to the version its `set`
   returned (on a re-import, the version the rule 1 read returned) (so an owner decision made in between makes the write fail instead of being
   overwritten; then re-read and write nothing if `legacy_decision` is now set). Once set, or once the owner decided Merged/Split, no run writes
   it again.

The page shows **Matches an old audit item — check**; the owner's Merged/Split decides.

**Example.** Invented baseline rows:

```json
[{"legacy_id": "EX-7", "surface": "data-lifecycle", "status": "open",
  "files": ["internal/example/files.go"],
  "note": "Attachment names are joined to the cache dir without cleaning, so ../ escapes it."},
 {"legacy_id": "EX-9", "surface": "data-lifecycle", "status": "fixed",
  "files": ["internal/example/"],
  "note": "Cache files were written 0644."}]
```

New doc `063e7700b0564553` traces `internal/example/sync.go` and `internal/example/net.go`
→ EX-9 is a candidate by prefix (EX-7 shares no file), but its note (file mode) is a different weakness from the record's (no
private-range check) → no write. Had the run created a doc for
`example:path-traversal:readfile` (trace `internal/example/files.go`), EX-7 and EX-9 would
both be candidates; EX-7's note is the same weakness →

```json
{"op": "update", "collection": "findings", "doc_id": "5f1cb9c01e53f362", "if_version": 1,
 "data": {"legacy_match": "EX-7"}}
```

## Rule 6 — Disputed check

The disputed list is the one the wrapper handed the engine at triage-in: fingerprints of
docs with `verdict: "rejected"`, the owner field `disputed: true`, and owner `status`
`open` or `in_progress` (spec §5.1). A doc the engine newly rejected while the owner had
it open (rule 2) is not on it until the owner disputes it.
A disputed fingerprint is re-validated when either holds:

- it is a record in this run's `findings.json` (any verdict), or
- a unit in this run's ledger has it in live `result_fingerprints` and at least one live
  `local_checks` entry made by a **verifier** (live checks are this run's — archived ones
  sit in `attempts`).

**How a verifier check is identified.** The ledger has no role field; a check carries only
its `agent_id`. The wrapper therefore tells the engine's parent (wrapper `SKILL.md`) to
give every verifier a canonical ID starting `verifier-` and every hunter one starting
`hunter-` (critics `critic-`, reconnaissance `recon-`) — all valid under the engine's
`^[a-z0-9][a-z0-9_-]{0,63}$`. A verifier check is a live `local_checks` entry whose
`agent_id` starts with `verifier-`. A hunter's own check (`hunter-…`) does not count, nor
does a check by an ID outside the scheme. When the ledger shows no `verifier-` or
`hunter-` IDs at all, the engine did not follow the naming: every disputed fingerprint
not in `findings.json` is listed as not re-validated, and the terminal summary says why.

Every other disputed fingerprint goes into the run row's `disputed_not_revalidated`
(rule 7), the terminal summary, and stays in the next run's disputed list (its doc is
unchanged, so it is still disputed).

A disputed fingerprint that is a record in this run's `findings.json` with verdict
`rejected` was re-checked and rejected again: it goes into the run row's
`disputed_rejected_again` (rule 7) and the terminal summary. Its doc keeps the owner's
`status` and `disputed`, so it stays on the next run's list until the owner sets
`false_positive` (the page says so).

**Example.** Disputed list: `example:csrf:form-post`, `example:auth:skip-check`. The
first is in no record, but a unit of this run's ledger has it in `result_fingerprints`
with a verifier check (`agent_id: "verifier-02"`):

```json
{"coverage_id": "internal%2Fexample%2Fform.go%23Submit::…", "status": "candidate",
 "agent_id": "verifier-02", "result_fingerprints": ["example:csrf:form-post"],
 "local_checks": [{"agent_id": "verifier-02", "reviewed_paths": ["internal/example/form.go"],
   "invariant": "Submit checks the origin token.", "method": "source",
   "result": "Token checked on every path.", "artifact": null}]}
```

→ re-validated. Had the unit's only check been the hunter's
(`"agent_id": "hunter-05"`), it would not count. The second is in no record and in no
unit's `result_fingerprints` →

```json
"disputed_not_revalidated": ["example:auth:skip-check"]
```

## Rule 7 — The run row

`set runs/<run-id>` with exactly the spec §7 fields. The wrapper is the row's only writer
and a `set` replaces the whole row. First import: no row in the rule 1 `list runs` → plain
`set`. Re-import of the same run dir (rule 8): the row exists → the same `set`, pinned with
`if_version` = the version the rule 1 read returned (the tool refuses an unpinned write
to an existing doc); a version conflict → re-`get` the row and resend.

| Field | Source |
|---|---|
| `engine_run_dir` | the run dir path |
| `kind` | `full` or `range` |
| `from`, `to` | the tag pair (Range); `null` for Full |
| `sha` | `source_ref` from `run-metadata.json` |
| `profile`, `budget` | `run-metadata.json` |
| `run_status`, `incomplete_reason` | `run-metadata.json` (`incomplete_reason: null` when complete) |
| `coverage {covered, deferred, out_of_scope, blocked}` | count of this run's live ledger units by `status`; `covered` counts `covered` and `candidate` (both carry evidence); `planned`, `in_progress`, `not_applicable` are not counted |
| `disputed_not_revalidated[]` | rule 6 (`[]` when none) |
| `disputed_rejected_again[]` | rule 6 (`[]` when none) |
| `counts {by_verdict, by_severity, regressed, resurfaced, new}` | below |
| `started_at`, `finished_at` | ISO 8601 UTC; start = when the wrapper pinned the target, finish = when the import ends |

`counts.by_verdict` (`confirmed`, `needs_validation`, `rejected`) and
`counts.by_severity` (`critical`, `high`, `medium`, `low`, `informational`, and `none`
for records without `severity`, i.e. every non-`confirmed` record) count the records of
this run's `findings.json`, **leaving out** `confirmed`/`needs_validation` records whose
doc has owner status `accepted` or `false_positive` (rule 3). `rejected` records are
always counted under `rejected` (they are created as `false_positive`, rule 2). `counts.new` = docs with `run_state: "new"` this
run; `counts.regressed` = docs with `run_state: "regressed"` this run;
`counts.resurfaced` = docs with `run_state: "resurfaced"` this run (rule 3).

**Example.** The rule 1 run (complete), with doc `e131db3e893fe77e` (accepted) found again:

```json
{"op": "set", "collection": "runs", "doc_id": "run-7",
 "data": {"engine_run_dir": "<engine-dir>/watchtower/run-7",
   "kind": "range", "from": "v0.1.0", "to": "v0.1.1", "sha": "bbbb2222",
   "profile": "standard", "budget": 40, "run_status": "complete",
   "incomplete_reason": null,
   "coverage": {"covered": 3, "deferred": 0, "out_of_scope": 1, "blocked": 0},
   "disputed_not_revalidated": ["example:auth:skip-check"],
   "disputed_rejected_again": [],
   "counts": {"by_verdict": {"confirmed": 0, "needs_validation": 1, "rejected": 1},
     "by_severity": {"critical": 0, "high": 0, "medium": 0, "low": 0, "informational": 0, "none": 2},
     "regressed": 0, "resurfaced": 1, "new": 1},
   "started_at": "2026-11-20T09:30:00Z", "finished_at": "2026-11-20T11:05:00Z"}}
```

(The accepted `confirmed`/`low` record is not in `by_verdict` or `by_severity`; it is
the one `resurfaced`.)

On a re-import of the same run dir, the rule 1 read returned `runs/run-7` at
version 1, so the same write goes out as
`{"op": "set", "collection": "runs", "doc_id": "run-7", "if_version": 1, "data": {…}}`.

## Rule 8 — Batching and order

Writes go through `ArtifactData batch`, **at most 50 writes per batch** (the tool's
limit) and at most 1 MiB per batch
body, each doc at most once per batch. Order: rule 2b baseline creates, rule 2 creates,
rule 2/3 updates, rule 4 updates, rule 5 `legacy_match` updates (in batches after the
creates they pin to), and the rule 7 run row last — so a run row exists only after its
findings are written. A pinned-version failure is handled as in *An owner edit during the
import* (at most 3 retries per batch, then stop); any other failed batch stops the import with the engine run dir intact, and
`/security-audit import <run-dir>` re-runs from rule 1 with a fresh read (rule 2's
re-import case keeps `run_state: "new"` for docs this run created).

**Example.** 230 writes (40 baseline creates, 120 creates, 50 updates, 19 rule 4 updates,
1 run row) → five batches: writes 1–50, 51–100, 101–150, 151–200, 201–230 (the last
ending with the run row). A doc with a rule 5 proposal gets its `legacy_match` update in a
batch after the one holding its `set`.
