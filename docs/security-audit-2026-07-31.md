# Security Audit — Watchtower, 2026-07-31

**Scope:** the whole project (Go backend + WatchtowerDesktop), branch `feature/target-extract-background`, plus `origin/main` wherever multi-account exists only there.
**Focus:** preparation for Google OAuth verification / CASA, scope minimization, handling of user data.
**Method:** six parallel read-only audits — the branch diff, OAuth scopes, data handling, injection surfaces, secrets and the Desktop surface, and external research into CASA requirements.

---

## 0. Headline conclusion

Technically the project is in decent shape: **no SQL injection, no command injection, no path traversal, no telemetry, no server-side component, and both Google scopes are read-only**. The problems cluster in three places, and none of them is a "hole in the code" in the classic sense:

1. **A legal blocker, not a technical one.** Gmail message content is sent to the `claude`/`codex` CLI authorized by a consumer subscription, where training on input is on by default. This violates item 4 of Limited Use (the prohibition on using Google User Data to train or improve foundation models). As long as that holds, we cannot go for verification. **CASA itself, meanwhile, is cheap and fast ($675–900/year, 2–3 weeks).**
2. **Data is not deleted.** `gmail logout` revokes the grant but deletes no messages; the memory vault is a git repository where "evicting" an episode leaves the content in history forever; deleting a source does not cascade into derived data.
3. **Delivery and the client surface.** Three OAuth client secrets can be extracted from the binary, `install.sh` installs with `sudo` something it does not verify, and the app has no URL-scheme allowlist while the App Sandbox is disabled.

The changes on the current branch (`feature/target-extract-background`) are **safe** — they introduce no new vulnerabilities.

---

## 1. Findings summary

| # | Sev | Finding | Where |
|---|---|---|---|
| L-1 | **Blocker (legal)** | Gmail content → consumer Claude/Codex subscription = violation of Limited Use item 4 | `internal/inbox/situation_card.go:114`, `internal/digest/generator.go:197` |
| D-1 | **Blocker (legal)** | `gmail logout` does not delete `gmail_messages` — restricted data outlives the revocation of access | `cmd/gmail.go:124-166` |
| D-2 | **Blocker (legal)** | The vault is a git repo: eviction writes a tombstone, the content remains in history; the vault is not declared in the privacy policy | `internal/memory/evict.go:180`, `vault.go:165` |
| A-1 | **Fixed** (`bbb1ec79`) | No URL-scheme allowlist: the text of a Slack message becomes a clickable link of any scheme (`smb://`, `file://`) while the sandbox is disabled | `SlackTextParser.swift:51`, `ActivityFeed.swift:80` |
| S-1 | High | Three OAuth client secrets (Slack/Google/Jira) can be extracted from the binary with `strings` | `Makefile:14`, `scripts/build-app.sh:58` |
| S-2 | **Fixed** (`26a355b2`) | `install.sh`: checksum is fail-open, signatures are not verified, quarantine is removed, files are copied with `sudo` | `scripts/install.sh:79-129` |
| O-1 | **Fixed** (`3d88aa0c`) | No PKCE in the Google OAuth flow (even though it is implemented for Outlook) | `internal/calendar/auth.go`, `internal/gmail/auth.go` |
| D-3 | High | Deleting a source does not cascade into derived data (memory, people cards); upstream deletions are not handled | `internal/db/slack_purge.go` |
| P-1 | Medium | Untrusted content lands in the **system prompt** rather than the user message — 11 call sites | `internal/inbox/triage.go:291` and others |
| A-2 | **Fixed** (`bbb1ec79`) | `MemoryView` deliberately handed every non-`watchtower-memory` URL scheme to the system | `MemoryView.swift:18` |
| A-3 | **Fixed** (`66eab707`) | `track_events.source_refs` from LLM output → `Link(destination:)` with no validation | `CustomTrackTimelineView.swift:235` |
| C-1 | **Fixed** (`fe1c5aca`) | `curl \| sh` from the `main` branch of a third-party repo in CI | `.github/workflows/ci.yml:150` |
| B-1 | **Fixed** (`a62a4d4a`) | `review-rules.md:70` proposes `responsibility_spawnattrs_setdisclaim` as the fix — it was tried and rolled back (it changed the responsibility chain but not the subject in the TCC prompt) | `docs/review/review-rules.md:70` |
| ~~S-3~~ | **Withdrawn 2026-08-03** | ~~Refresh tokens and IMAP passwords — plaintext JSON instead of Keychain~~ — reviewed separately, verdict "a deliberate decision, not a gap": the `gcloud` precedent (the same 0600 without encryption), no normative requirement (RFC 8252/9700 are silent), and the argument for verification is the absence of a server. Keychain is architecturally hostile (headless daemon, standalone CLI, ad-hoc signing with a floating cdhash) and does not defend against the dominant threat. See section 8. | `internal/{gmail,calendar,jira,imap,caldav}` |
| M-1 | Medium | Qwen3 weights from a personal HF account with no revision pinning | `Providers/Qwen3Provider.swift:48` |
| O-2 | **Fixed** (`bcdb56c8`) | Fail-open `GrantsScope`: an empty `scope` in the response means "granted" | `internal/calendar/auth.go:215-220` |
| X-1 | Medium | It is unclear how codex parses `-c developer_instructions=<value>` — if it parses it as a TOML document, string injection disables the sandbox | `internal/codex/client.go:47` |
| D-4 | **Fixed** (`db2cc8ae`) | The vault was written `0644/0755` (the only place with world-readable sensitive data) and `watchtower.db` `0644`. Both now 0600/0700, tightened on open so pre-existing installs are brought up too. `.env` is still `0644` — a file on the developer's machine, not in the repo: fix with `chmod 600 .env` | `internal/db/db.go`, `internal/memory/vault.go` |
| L-2 | **Fixed** (`06988964`) | Content in logs: the full target text without truncation, 200 characters of model output in `pipeline_runs.error_msg` | `internal/targets/extractor.go:231,285`, `internal/ai/client.go:73` |
| X-2 | **Fixed** (`2473d001`) | A stale system prompt pushes the agent toward a `sqlite3` shell fallback (Bash is available on codex) | `ChatViewModel.swift:391-399` |

**Branch `feature/target-extract-background`: no findings.** Arguments to `Process` are passed as an array without a shell, and the removed timeout is an availability matter, not a security one.

---

## 2. Google OAuth: scopes and flow

### Requested scopes

| Scope | Actual use | Verdict |
|---|---|---|
| `gmail.readonly` (restricted) | GET only: `users/me/profile`, `messages`, `messages/{id}?format=full` | **minimal** — there are no writes anywhere, `gmail.modify` is deliberately not requested |
| `calendar.readonly` (sensitive) | GET only: `events`, `calendarList` | **broader than needed, but deliberately so** — it is covered by the pair `calendar.events.readonly` + `calendar.calendarlist.readonly`; the broad scope was chosen because of the granular consent screen (the rationale is already in `docs/legal/google-verification.md`) |

There are no unused scopes. `openid`/`userinfo.email` are not requested — as a result, calendar-only accounts remain unnamed in the UI and the user may revoke the wrong grant.

### Flow

The good: loopback `127.0.0.1` (not OOB), a cryptographically random `state` that is verified, TLS, revoke implemented and actually called, tokens at `0600` in a `0700` directory, never in the database and never in logs, and a built-in Apple-style "bring your own client" that reads the secret from stdin.

~~The bad: **PKCE is absent**~~ — added 2026-08-04 (`3d88aa0c`), lifted from the Outlook implementation (`internal/imap/outlook_auth.go:104`, S256) into a shared `internal/auth/pkce.go`. The fail-open `GrantsScope` is also fixed (`bcdb56c8`) and a mismatch between the client_id in the runbook (`334226468569`) and the one actually built (`73647425110`).

---

## 3. User data

### What is stored and how it is deleted

| Class | Retention | Deletion |
|---|---|---|
| Slack: messages, threads, file metadata | none | `auth logout` → `ClearSlackData` |
| **Gmail: message bodies up to 50 KB, addresses** | **none** | **absent** — D-1 |
| IMAP/Outlook | none | FK cascade, works |
| Calendar | sliding window −24h…+N days | `calendar logout` → `ClearCalendarEvents` |
| Meeting audio (`rec_*.caf`) | **30 days**, sweep in place | automatic |
| Transcript text, notes | none (by design) | manually from the UI only |
| People cards, beliefs about people | none | `ClearSlackData` only (does not cascade into memory) |
| **Memory vault (episodes, beliefs)** | aging 14d / eviction 45d = tombstone, **not deletion** | **no real deletion exists** — D-2 |

### At rest

There is no encryption of any kind: SQLite without SQLCipher, GRDB without a passphrase, and Keychain is not used for user secrets anywhere. The app is **not sandboxed** (`app-sandbox = false` — deliberately, because of the CoreAudio process tap). There are no Time Machine exclusions, which means unencrypted message bodies, meeting audio and OAuth tokens are copied to any external drive.

Permissions are generally set carefully (`0600`/`0700` for tokens, config, logs, PID), but **the vault is the outlier: `0644` files and `0755` directories** — the only place where sensitive data is world-readable, saved only by the parent directory's `0700`. The database file also has no explicit `chmod` (it is created under the umask, effectively `0644`).

### Egress

Exactly three channels:
- **LLM** (the main one): `exec.Command(claude|codex)` — Slack messages, **full message bodies**, meeting transcripts, vault content, people cards and meeting prep all go there. The code sets no retention/no-training flags — the policy of the account the CLI is authorized under is what applies.
- **Read-only API clients**: Slack, Gmail, Calendar, Jira, IMAP, CalDAV. Not a single write call.
- **Auto-update**: `GET api.github.com/.../releases/latest`, no user data, signature verified against the Team ID.

There is **no** telemetry, analytics or crash reporting, in Go or in Swift. Gmail attachments are not even downloaded. STT runs on-device.

---

## 4. CASA: what it actually is right now

- **The nomenclature has changed**: not Tier 2/3 but **AL0/AL1/AL2**; Google assigns the level dynamically based on user count, scopes and "application-specific signals" (the thresholds are not published). The requirements are identical at every level — what differs is the method of proof.
- **The baseline is ASVS 4.0.3**, not 5.0 (5.0 was released in May 2025; CASA has not migrated to it).
- **Self-scan is officially deprecated**; the route is: a notification email from Google → running the scan yourself → uploading the configs and results (CSV/XML) to the portal → Letter of Validation. **Google does not receive the source** (at AL2 the lab needs access to the repo or the dependency manifest — only to check 6.1.1).
- **The desktop app is covered by the `Local` type**, for which there are preconfigured setups for **FluidAttacks CLI (SAST — supports both Go and Swift, free)** and **ZAP (DAST)**. Important: **the application type must be agreed with the lab in writing up front** — the CASA Test Guide is written for the web and contains no methodology for desktop.
- **Price and timeline**: TAC Security $675 (Basic) / $855 (Premium), LoV in 2–3 weeks. Leviathan $800–1200. Tier 3 ($4500+) is needed only for the Workspace Marketplace badge — a desktop app does not need it.
- **Passing criterion**: no findings with **high** likelihood of exploit. **At revalidation the bar rises to medium** — aim there from the start.
- **Recertification is annual**, counted from the LoV approval date, and the level can be raised.
- **Caveat**: the ADA documentation is out of sync (the `/casa/tier-2/*` pages still use the old terms, the changelog is frozen at March 2023, and onboarding of new labs is paused because of the ADA migration under the Linux Foundation). The source of truth is Google's email and the lab's instructions.

### The key point: Limited Use item 4

From the Workspace user data policy (updated 2026-07-13), the following is prohibited:

> "Transferring, selling, or using user data to create, train, or improve a machine learning or artificial intelligence model **beyond that specific user's personalized model**…"

FAQ Q16 defines a personalized model as "any models run **exclusively on-device** or a model specifically tailored to only that end user or organization" that does not mix data from different users. Claude and GPT are unquestionably foundational.

Three independent blockers in the current architecture:
1. **Training is on by default** on consumer plans: the Anthropic Consumer Terms explicitly cover "Claude Code from accounts associated with those plans", and retention for training is 5 years. We cannot verify whether the user has turned the toggle off.
2. **"Stored in conjunction with foundational models"** (FAQ Q14) — nowhere defined; a strict reading kills any frontier-model call. This is the largest interpretive risk.
3. **Automated (daemon) access to Claude on a consumer subscription** contradicts Anthropic's own Consumer Terms, independently of Google.

**Options:** (A) require a **BYO API key** — API traffic is excluded from training by default, and there is a DPA plus zero-retention options; (B) **on-device only for Gmail** (the infrastructure already exists — WhisperKit/MLX); (C) stay below the verification threshold — but the policy applies regardless of verification status.

Plus a new requirement in the Workspace policy as of 2026-07-13: protection **against prompt injection** ("Model Armor or other prompt injection protection") — for an application that feeds message bodies to an agentic model with tools, this will have to be documented. See finding P-1.

### The Internal application route

Internal exempts an app from both verification and CASA ("use of restricted or sensitive scopes doesn't require further review by Google"), at the cost of being limited to a single Workspace organization. Caveats: the CASA exemption is **inferred, not stated verbatim**; the Internal → External transition is **not documented by Google at all** (the fate of existing grants is unknown); and the limit of 100 new users per External project **is consumed permanently and never resets**.

---

## 5. Action plan

### Block 0 — decide architecturally (everything else depends on this)
1. Choose the AI path: **BYO API key** (recommended) or **on-device for Gmail**. As long as Gmail goes to a consumer subscription, we cannot go for verification.
2. Separate the pipelines by source: Gmail-derived data must not travel the same path as Slack/Jira if the CLI subscription remains in place for the latter.

### Block 1 — blocking for submission
3. Purge Gmail data in `runGmailLogout` following the `ClearCalendarEvents` model — the cheapest fix and the one most visible to an assessor.
4. Resolve the vault's undeletability: `watchtower memory forget --source gmail` with physical deletion **and** history rewriting (or recreating the repo without history). The alternative is to disable `memory.sources.gmail` before release and declare that.
5. Bring the privacy policy in line with the implementation: the vault as a second copy of Gmail-derived data, a separate **named section about Gmail** (a general formulation is not sufficient — FAQ Q12), and the real deletion model.
6. Sync `docs/legal/google-verification.md` — it lists the client_id of project `334226468569`, while the build uses `73647425110`.
7. An in-app consent screen before the first time Gmail content leaves the device (it should be captured in the demo video).

### Block 2 — engineering, before scanning
8. **PKCE (S256)** in the Google flow — a working example is in `internal/imap/outlook_auth.go:104`.
9. A single allow-listing `OpenURLAction` at the outer level of `WatchtowerApp.body` — this closes A-1, A-2, A-3 and X-2 at once.
10. Check codex's `-c` parser (X-1); if in doubt, pass the system prompt via a file or stdin.
11. Remove the `sqlite3` fallback from `ChatViewModel.swift:391-399` and fix the MCP tool names.
12. `install.sh`: make the checksum mandatory (fail-closed) plus `codesign --verify` — the code is already written in `UpdateService.swift:238-247`, it just needs to be ported.
13. Permissions: `chmod 0600` on `.env` and `watchtower.db` (plus `-wal`/`-shm`), and the vault to `0600/0700`.
14. The "source → derived" cascade: extend the purge to `memory_nodes`/`memory_aliases`/`memory_provenance`/`memory_fts` plus the vault files.
15. Move untrusted content from the system half to the user half at the 11 call sites, and export the shared sanitizer (it is currently private in `digest` and `guide`).
16. Truncate content in logs: `internal/targets/extractor.go:231,285`, `internal/ai/client.go:73`.
17. Pin the sentrux `curl | sh` in CI to a commit plus a SHA-256.

### Block 3 — the CASA process
18. Agree the **type = `Local`** with the lab in writing, before work starts.
19. Run FluidAttacks CLI (SAST) over Go and Swift plus ZAP (DAST) against the OAuth loopback listeners.
20. Fix every high, and aim for medium (the revalidation bar).
21. Choose a lab (TAC Security $675 / Leviathan $800–1200) and ask about the CASA Accelerator.
22. Set a reminder 60 days before the LoV anniversary.

### Separately, outside CASA
23. Keychain for refresh tokens and IMAP passwords instead of plaintext JSON.
24. Remove the wording "e.g. `responsibility_spawnattrs_setdisclaim`" from `review-rules.md:70`: this approach was already tried and rolled back (2026-05-02) — disclaim correctly changed responsible_path, but the `subject` in the TCC prompt is resolved from the binary's physical path upward to the nearest `.app`, so the UI still showed Watchtower.app. The workable direction is a sub-bundle `Contents/Helpers/WatchtowerCLI.app` with its own `CFBundleIdentifier`. As written, the document sends the next engineer looking for code that does not exist and repeating a rolled-back experiment.
25. Pin the revision of the Qwen3 weights (currently a personal HF account with no pinning).
26. Revoke on logout for Slack/Jira/Outlook (today only the local token is deleted).
27. Retention options for `gmail_messages`/`imap_messages` and transcript text.

---

## 6. What to present as strengths

- Both Google scopes are read-only, with **not a single write call** to a Google API anywhere in the tree; `gmail.modify` is deliberately not requested (recorded in a code comment).
- There is no server of our own, no telemetry, no crash reporting and no sale of data.
- Gmail attachments are not downloaded at all.
- Loopback redirect plus a cryptographic `state`; no embedded webview is used.
- Tokens are local only, `0600`/`0700`, never in the database (an explicit contract in `schema.sql:1122`), never in logs.
- Revoke is implemented and actually invoked, including cleanup of legacy token files.
- No SQL injection: three independent passes over Go and a full review of Swift/GRDB found zero; FTS5 is sanitized at all three MATCH sites in Go and in the Swift counterpart.
- MCP is stdio only, and the database is opened read-only before handlers are registered; there is not a single listening socket other than the loopback OAuth callbacks; `0.0.0.0` does not appear in the repository.
- Speech-to-text is fully on-device — by Google's definition that is a personalized model.
- CI has access to no repository secret whatsoever; the trigger is `pull_request`, not `pull_request_target`; there is no interpolation of untrusted fields.
- Open source: the claims about read-only access and local storage are verifiable.

---

## 7. Open questions

- Google does not publish the AL1 vs AL2 thresholds by user count.
- "Stored in conjunction with foundational models" is nowhere defined — the key ambiguity in the whole LLM story.
- The list of certifications accepted by the CASA Accelerator is unconfirmed (the page returns 404).
- The exemption of Internal applications from CASA is inferred logically; there is no verbatim rule.
- The Internal → External transition is undocumented — do not plan on grants being preserved.
- Exactly how codex parses the value of `-c developer_instructions=` (X-1) cannot be determined from this repository.
- Whether FileVault counts as "encryption at rest" for the local database — no authoritative answer was found either from Google or in the CASA specification (which contains no control on encryption at rest at all). A question for the lab during type agreement.

---

## 8. Finding-by-finding review (with owner decisions)

Findings are reviewed one at a time; the verdicts are recorded here so that questions are not reopened.

### D-1 — deletion of Gmail data · reviewed 2026-08-02, **implemented 2026-08-04** on `feature/security-audit-fixes` (`0f4c48e8`, `077600c2`)

The original formulation ("purge messages on `gmail logout` following the calendar model") is **wrong**. Google does **not** require automatic deletion on revocation of access: the obligation is reactive — "Honor user requests to delete their data" — and the scope is defined by the user's request. There are only two hard requirements on this path: delete tokens immediately (already done) and **provide help documentation on how a user deletes their data** (not done, and not a code matter).

The straightforward fix would have broken the UX irreversibly: the sync watermark is not reset, so after reconnecting the history would never come back, and AI-derived data cannot be restored at all.

**The accepted design:** a separate explicit action, "delete synced Gmail data" (CLI plus a button), with `logout` unchanged. In a single transaction: the account's messages, inbox items by the `gmail:<id>:` prefix, and cleanup of orphaned situations and feed items following the `slack_purge.go` model. **No watermark is touched** — not the sync watermark (otherwise everything would be re-downloaded), not the memory one (otherwise re-extraction against an empty table would thin out episodes), and not the inbox or composer ones (they are shared with other sources).

Derived knowledge is not touched by default, and that is safe: `mail:` refs are not re-validated in the belief pass (`validateChatRefs` filters only `chat:`/`act:`), episodes are idempotent on the `gmailthread:<thread>` alias with no account number, and reading a dangling ref is not validated anywhere. Deleting knowledge is a second, separate explicit choice, with an honest caveat that whatever has been reworked into generalizations cannot be recovered.

**An existing bug found along the way:** the inbox deduplication key embeds `account_id` (`gmail:<account_id>:<thread>`), and on `google remove` the watermarks disappear together with the account row. So "delete the account → reconnect" **already today** causes a re-download and duplicates.

The first instinct — re-key `channel_id` on the mailbox address — was investigated and **rejected**. The root cause is not the format: `removeGoogleAccount` deleted the account row but left the inbox items and learned rules that hang off the channel-id convention rather than a foreign key. Re-keying would also have been a poor trade: the format is a documented contract (`docs/inventory/inbox-pulse.md:137,158`, owner approval required), the migration is irreversible where it collapses duplicates, and an address is a weak key — it can be empty (a reachable state when the Gmail scope is not granted or the profile lookup fails), is neither normalised nor unique, changes on a Workspace rename, and its legal `_` is a `LIKE` wildcard, which would have made one mailbox's purge delete another's rows. **Shipped instead:** `removeGoogleAccount` calls `ClearGmailData` before `DeleteGoogleAccount` — one call, no migration, trivially revertible.

**Still outstanding for D-1 (not code):** the Workspace policy separately requires "user help documentation that explains how users can manage and delete their data from your app or service". The CLI command exists; the documentation does not.

**Two pre-existing bugs surfaced by the investigation, both unrelated to this work and neither fixed:**

- ~~`GetGmailBodyByID` selects `WHERE id = ?` with no `account_id`~~ — **fixed** (`aaed5aa3`): renamed to `GetGmailBody(accountID, id)` and scoped; the account is read back out of the item's `channel_id` by `GmailAccountIDFromChannelID`, the sole parse site of that format.
- The memory alias `gmailthread:<thread_id>` (`internal/memory/gmail_extract.go:32`) is not account-scoped, so two mailboxes sharing a thread id would merge their episodes.

### S-3 — tokens in files vs Keychain · reviewed 2026-08-03, decision: **we keep the files**, finding withdrawn

An overcall in the original report. The verdict and rationale are in the memory entry `project_token_storage_file_vs_keychain`; in brief: the `gcloud` precedent (the same unencrypted 0600, which Google acknowledges in its own documentation), no normative requirement (RFC 8252/9700 are silent on on-device storage), and for verification we answer with scope — there is no server, and the list of required measures is written about "your systems". Keychain is architecturally hostile (headless daemon, standalone CLI, ad-hoc signing with a floating cdhash breaks the ACL the same way it breaks TCC grants) and does not defend against the dominant threat (Atomic Stealer + Chainbreaker). A compromise in case a reviewer needs a concrete control: encrypt the file with a key from Keychain under a permissive ACL.

**What remain genuine** are the file-permission gaps nearby: `.env` 0644, `watchtower.db` 0644, vault 0644/0755 (D-4).

### Reprioritization following the reviews

Two items from the mandatory Workspace-policy list for restricted scopes apply to us and were not present as requirements in the original report: **protection against prompt injection** ("Model Armor or other prompt injection protection" — this makes P-1 not a "good practice" but a checklist item) and **encryption of user data at rest** (the open FileVault question above).
