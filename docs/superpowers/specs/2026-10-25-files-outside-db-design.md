# Company content in files outside the database — design (board #604)

Part of board group #595 (corporate data on the Mac). Status: draft for the
owner, 2026-10-25; no code yet. Depends on #603 (database encryption,
`docs/superpowers/specs/2026-10-21-db-encryption-design.md`, Stage 1 merged:
engine only, every file still plaintext). Sibling of #601 (revoke purge,
`docs/superpowers/specs/2026-10-21-revoke-purge-design.md`).

## Goal

#603 makes `watchtower.db` and `agentlog.db` ciphertext. Watchtower also writes
company content into files next to the database and elsewhere on the Mac:
the memory vault, meeting audio and transcript sidecars, automation drafts,
logs with message fragments, AI prompts in `$TMPDIR`, chat attachments, the
MobileHub sidecar and a few UserDefaults keys. A copy of the workspace folder
(Time Machine, a sync client, a support bundle, an agent running `cat`) would
still leak them after #603.

After this change no plain company content stays outside the database, with a
short, named list of exceptions the owner approves (§4). Every item is handled
in one of four ways, picked in this order:

1. **Stop writing it** (logs, temp files, UI caches): the content was never
   needed on disk.
2. **Move it into `watchtower.db`**: small text or structured data whose readers
   already talk to the database.
3. **Seal it with the database key**: large binary files (audio, attachments)
   that do not belong in SQLite pages.
4. **Delete it**: leftovers whose purpose has passed.

No new user-facing steps: nothing asks the owner for a password or a choice.

Out of scope: the database files themselves and `*.db.bak` copies (#603 Stage 3,
its Q4 (a): the encryption notice offers **Delete N plaintext backups**),
credentials that are not content (see Q4), the owner's own repositories,
exports the owner makes on purpose, MDM policy (#608).

## What exists today

Paths: `<ws>` = the workspace dir (`cfg.WorkspaceDir()`), `<as>` =
`~/Library/Application Support/Watchtower`, `$TMPDIR` = the per-user temp dir.
"Content" means text, audio or names that come from Slack, mail, calendar,
Jira/Linear/Confluence, meetings, or AI output made from them.

### Go

| # | Path | Writer | Content | Size | Lifetime / readers |
|---|---|---|---|---|---|
| G1 | `<ws>/memory/**.md` + `<ws>/memory/.git` | `internal/memory/vault.go:247,545,577` (go-git repo) | **Yes.** Entities, episodes, beliefs, rollups written from every source; git history keeps every past version | KB–100s MB | Forever. Source of truth by MEM-02; the SQLite index (`memory_nodes`, `memory_fts` with the full body) is derived. Read by the pipeline, MCP `memory_*`, Desktop Memory browser (`MemoryVaultGit.swift` runs `git log`) |
| G2 | `<ws>/automation-drafts/<conv>.jsonl` | `internal/automations/authoring/draftcache.go:45,96` | **Yes.** Recipe text and the dry run's result (LLM output, tool reads) | KB, last 5 entries | Until the draft is saved/discarded. Read by the Desktop draft panel |
| G3 | `<ws>/watchtower.log` (+ `.1`) | `cmd/logfile.go:63`, the daemon's `log` | **Yes.** Slack channel names, `@name (Real Name)` per user (`internal/sync/orchestrator.go:873,923`), meeting titles (`internal/meeting/pipeline.go:173,259`), track/target text cut to 80 chars (`internal/tracks/pipeline.go:921,1029`, `internal/targets/extractor.go:260,314`), raw LLM output on parse errors (200–500 chars: digest, tracks, guide, briefing, meeting), up to 64 KB of AI CLI stderr and result envelopes (`internal/ai/client.go`, `internal/digest/generator.go:293-320`, `internal/codex/model_errors.go:111`), full Jira and Ollama HTTP bodies (`internal/jira/client.go:349,453`, `internal/ollama/client.go:185,285`) | 20 MiB + one old copy | Forever (rotated) |
| G4 | `<ws>/daemon.log` (+ `.1`) | `cmd/sync.go:429` (detached child's stdout/stderr) | Panics and stray stderr; a panic can carry values | Capped only at daemon start | Forever |
| G5 | `<ws>/sessions.log` | `internal/sessions/log.go:31` | No (ids, fixed labels) | **No cap** | Forever |
| G6 | `<db dir>/dblock.jsonl` | `internal/db/lockmetrics` | No (Go function names, SQLite code names) | 10 MiB | Rotated |
| G7 | `$TMPDIR/wt-system-prompt-*.txt` | `internal/ai/client.go:402`, `internal/digest/generator.go:240`, `internal/codex/instructions.go:48` | **Yes.** A pipeline's whole system prompt | KB–MB | Removed after the child exits; a crash leaves it until the next **daemon** start sweeps it (`fsutil.SweepStalePrivateTemp`) |
| G8 | `$TMPDIR/wt-chat-prompt-*.txt`, `wt-chat-mcp-*.json`, `wt-mcp-*.json` | `internal/chat/claude_backend.go:328,332`, `internal/ai/client.go:465` | **Yes** (chat prompt) and secrets (MCP headers/env) | KB | For the whole warm session; **never swept** after a crash |
| G9 | `<ws>/tmp/extract/<spool>*` | `internal/extract/extract.go:191` | **Yes.** Downloaded Confluence attachments | MB | Removed after extraction; left by a crash |
| G10 | `<ws>/project_files/<project>/<sha>.<ext>` | `internal/workbenchfiles/store.go:182` | Possibly (screenshots attached to targets) | MB | Until no target names it. Read by the workbench agent **by path** |
| G11 | `~/.claude/projects/<slug of the chat cwd or $TMPDIR>/*.jsonl` (written by the Claude CLI) | `internal/ai/client.go:buildArgs` and `internal/chat` run `claude -p` **without** `--no-session-persistence` (only `internal/digest/generator.go:90,109` passes it); codex runs `--ephemeral` | **Yes.** Every prompt, tool result and answer of AI Chat, Discuss chats and every `ai.Client` one-shot | MB–GB | Claude Code's own cleanup (30 days by default). Needed only for `--resume` |
| G12 | `last_*.txt`, `*_attempts.txt`, `last_sync.json`, `sync_progress.json`, `history_backfill_hooks_done.txt`, locks, pid files | `internal/daemon`, `internal/sync` | No (times, counts, phase labels) | Bytes | — |
| G13 | `<ws>/agentlog.db` | `internal/agentlogdb` | Agent transcripts' facts | MB | Encrypted by #603 Stage 3 (same key) — listed for completeness |

### Desktop (Swift) and the Mac-side mobile hub

| # | Path | Writer | Content | Size | Lifetime / readers |
|---|---|---|---|---|---|
| S1 | `<as>/recordings/rec_*.caf` | `SystemAudioRecorder.swift:667` | **Yes.** Meeting audio (mic + system) | ~14 MB/h | `audio_retention_days` (30) after the transcript; orphan sweep 30 days. Read by WhisperKit, `ClipPlayer`, `transcript save --audio` |
| S2 | `<as>/recordings/rec_*.m4a` | `MeetingRecorderCenter.swift:1908` (phone upload, decrypted) | **Yes.** Phone meeting audio | MB | As S1 |
| S3 | `<as>/recordings/rec_*.txt`, `rec_*.json` | `MeetingRecorderCenter.swift:1779,1783` | **Yes.** Full transcript, utterances, voice embeddings | KB–MB | Removed after a successful save; else up to 30 days |
| S4 | `<as>/recordings/rec_*.meta` | `MeetingRecorderCenter.swift:1668,1889` | Meeting title | Bytes | Until saved/dismissed |
| S5 | `<as>/recordings/rec_*.activity` | `SystemAudioRecorder.swift:194,401` | No (RMS timeline) | KB | With the audio |
| S6 | `$TMPDIR/watchtower-transcript-*.txt`, `-segments-*.json`, `-speakers-*.json` | `TranscriptSaveService.swift:143,151,167` (default mode) | **Yes** | KB–MB | One CLI call (`defer`) |
| S7 | `$TMPDIR/watchtower-text-*.txt`, `dictation-*.txt`, `watchtower-automation-*/` | `CLITextFile.swift:17`, `DictationCleanService.swift:78`, `AutomationEditorCenter.swift:679` | **Yes** (recaps, compose text, dictation, recipes) | KB | One CLI call |
| S8 | `<ws>/chat_files/<conversations|projects>/<id>/<uuid>.<ext>` | `ChatAttachmentStore.swift:95` | **Yes.** Chat attachments and long pastes | ≤ 32 MB each | Until the conversation/project is deleted. Read by Go `ai session` by path, sent to the model as content blocks |
| S9 | `<ws>/workchat-attachments/<session>/*` | `WorkchatAttachmentStore.swift:30` (default mode) | **Yes.** Pastes into a workbench session | KB–MB | 7 days after the session ends. Read by the agent CLI **by path** |
| S10 | `<ws>/memory/**.md` | `MemoryViewModel.swift:379` (owner edits) | As G1 | KB | As G1 |
| S11 | `<as>/MobileHub/hubstate.db` | `HubSyncState.swift:46` (GRDB, no key) | **Yes.** `session_reports.payload` (asks, now/next, PRs), `held_session_lines` (the phone's typed prompt, decrypted action JSON) | KB–MB | Rolling windows |
| S12 | `<as>/MobileHub/SliceAssets/<rec>/<file>` + `<file>.desc` | `SliceAssetStore.swift:135-136` | Sealed transcript segments, **but the `.desc` holds `K_asset` in the clear** next to the ciphertext | KB–20 MB | While the record is in the zone |
| S13 | `<as>/MobileHub/transport-assets/.<uuid>.m4a` | `ChunkedAssetCipher.swift:287` | **Yes**, briefly (0600) | MB | Removed after ingest on every path |
| S14 | `<as>/MobileHub/transport.db`, `transport-assets/<sha>` | `TransportStore.swift:20,448` | Sealed E2E envelopes; heartbeat/hello metadata in clear | MB | Swept |
| S15 | UserDefaults `embeddedChat.queuedDraft.<key>` | `EmbeddedChatWiring.swift:93` | **Yes.** Unsent message text | Bytes | Until the turn starts |
| S16 | UserDefaults `projects.notificationSnapshot.<id>` | `WorkbenchNotificationCenter.swift:173` | **Yes.** Target titles, ask titles and question bodies, action summaries | KB | Overwritten each poll |
| S17 | `<as>/session-host.log` | `SessionHostClient.swift:281` | No (PTY output stays in memory) | ≤ 1 MiB | — |
| S18 | `<ws>/skills/*.md`, `<ws>/automations/*.md` | `SkillsSettingsViewModel.swift:232`, `internal/automations/recipe_write.go:24` | Owner-written prompts and recipes (owner content, not synced company data) | KB | Owner's files |
| S19 | NSSavePanel exports (artifacts, `*.wtvoices` — the latter already AES-GCM under a password), `memory digest-compare --out` | `ArtifactActionPerformer.swift:54`, `VoiceRegistryCenter.swift:542`, `cmd/memory.go:657,704` | Yes, on purpose | — | Owner's choice |

Not found: file logs through `os_log`, crash-report files of our own, debug
dumps of raw LLM output, any `WATCHTOWER_DEBUG`-style switch. `SandboxedHTMLView`
uses a non-persistent WebKit store; the Monaco views load over a scheme handler
and keep no content in web storage.

## Design

### 1. The sealed-file primitive (needs #603 Stage 2)

One format for the large binary files, Go and Swift twins (dual path, a shared
fixture test like #603's ECIES fixture):

- **Key:** `HKDF-SHA256(db_key, info = "watchtower sealed file v1")`, 32 bytes.
  The database key comes from #603's opener (`internal/dbkey` / Swift
  `DatabaseKeyStore`), so no new Keychain item, no prompt, no new failure mode:
  if the database opens, the files open. Key loss (#603 §8) loses them with the
  database, which is the same promise.
- **Format:** magic `WTSF\x01`, a 16-byte random file id, then AES-256-GCM chunks
  of 64 KiB (nonce = file id ‖ chunk counter, last-chunk flag in the AAD), the
  same shape as the Kit's `ChunkedAssetCipher`, which the Swift twin reuses.
  Streaming read and write, so a one-hour recording never sits in memory twice.
- **Names:** `<name>.wts` beside where the plaintext lived. Readers open `.wts`
  first and fall back to the plaintext name only while the one-time step (§3)
  has not run.
- **Workspaces without a key** (dev builds under #603 Q1 (a) have a `dev` key, so
  this is only a pre-Stage-2 install): nothing is sealed; the plaintext path is
  kept until Stage 3 encrypts the database, and then §3 seals.

Used for exactly two things: meeting audio (S1, S2) and chat attachments (S8).

### 2. Per item

| # | Decision | How |
|---|---|---|
| G1, S10 memory vault | **Move into the DB** (Q1) | New tables `memory_files(path PK, content, updated_at)` and `memory_history(commit_id, path, content NULL = deleted)` + `memory_commits(id, kind owner_edit/pipeline/…, message, at)`. `Vault` keeps its API (`Write`, `Render`, `Commit`, `OwnerEditedFiles`, `reset-to`) over these tables instead of go-git. MEM-02 inverts: the tables are the record, `memory_nodes`/`memory_fts` stay derived and `memory reindex` rebuilds them from `memory_files`. The Desktop Memory browser edits through GRDB and lists history from `memory_commits` (no `git log`). Obsidian can no longer open the vault; `memory export --out DIR` writes the markdown on request (an owner export, like S19) |
| G2 automation drafts | **Move into the DB** | `automation_draft_cache(conversation_id, seq, entry_json, at)`, last 5 per conversation kept by the writer; the Desktop panel reads it through GRDB. Deleted with the draft, as today |
| G3 watchtower.log | **Stop writing content** | One rule: logs carry ids, counts, durations, phase and error class, never names or text. Names become ids (`channel=<acct>:<id>`, `user=<acct>:<id>`, `event=<id>`); AI text drops out of log lines; parse errors log byte count + sha256 + shape (as `internal/claude/output.go:22` already does); CLI stderr and HTTP bodies are kept on the error **stored in the database** (`pipeline_runs.error`, `jira_accounts` status text) and logged as the first 120 chars after a scrub of quoted strings. A guard test runs the pipelines with canary text in every synced field and fails if a canary reaches the log writer |
| G4 daemon.log | **Stop writing content** + cap | The detached child points stderr at `watchtower.log`'s rotating writer once it starts; `daemon.log` keeps only the pre-logger lines. Panics print the stack, not the values (`GOTRACEBACK=single`, default) |
| G3, G4 old copies | **Delete once** | The one-time step (§3) deletes `watchtower.log*` and `daemon.log*` written before the redacting version, after keeping the last 200 lines that pass the redaction filter |
| G5 sessions.log | Keep (no content) | Add the 20 MiB rotation the other logs have |
| G6, G12, S5, S17 | Keep | No content. `sync_progress.json`'s `detail` follows the log rule |
| G7, G8 prompt temp files | **Stop writing them** where the CLI allows, sweep the rest | Pass the system prompt through an inherited pipe (`--system-prompt-file /dev/fd/3`, Codex `model_instructions_file` likewise), so nothing hits the disk. If a CLI version refuses a FIFO (checked at the start of the implementation on the pinned versions), keep the 0600 file but delete it right after the child has read it (the first stream event), and sweep every `wt-*` prefix at every process start, not only the daemon's. MCP config files with secrets go the same way |
| G9 extract spool | Keep, sweep | Sweep `<ws>/tmp/extract` at daemon start (older than 10 min) |
| G11 Claude Code session store | **Stop writing it** (Q3) | `ai.Client` one-shots pass `--no-session-persistence` (as digests do). Chat sessions too: the warm child keeps the context in memory, and every respawn uses the existing replay from the database (`ReplayFromDB`, today's `session_lost` path) instead of `--resume`. Cost: a respawned chat re-sends its history once |
| S1, S2 meeting audio | **Seal** | The recorder writes plaintext while it records (crash recovery needs a growing file); on stop, and for a recovered recording on the next launch, the file is sealed to `rec_*.caf.wts` and the plaintext removed. The phone ingest seals while copying from the decrypted temp file. WhisperKit, `ClipPlayer` and `transcript save --audio` read through the unsealing stream (samples into memory, `AVAudioPlayer(data:)`). Retention unchanged |
| S3 transcript sidecars | **Move into the DB** | The save-retry state goes into a `pending_transcripts(recording, text, meta_json, at)` row written right after transcription; the row is the retry source, deleted on a successful save. No `.txt`/`.json` sidecars |
| S4 `.meta` | **Move into the DB** | Same row, `title`/`event_id` columns, written when the recording starts |
| S6, S7 Swift → CLI temp files | **Stop writing them** | All text goes to the CLI over stdin (`--text-file -`, `transcript save --stdin` with one JSON object); the recipe check uses `validate --stdin`. `CLITextFile` is removed |
| S8 chat attachments | **Seal** | `ChatAttachmentStore` writes `.wts`; Go `ai session` unseals when it builds the content blocks (it already reads the file itself, the model never gets the path) |
| S9 workchat attachments, G10 target images | **Exception** (Q3) | The workbench agent reads them by path, so they must be plaintext. 0600 for both; workchat attachments are deleted when the session ends instead of 7 days later; target images are deleted when the target is archived (`workbench_target_archive`) |
| S11 hubstate.db | **Encrypt with the DB key** | Opened with the same `PRAGMA key` as `watchtower.db` in `prepareDatabase`; a plaintext file is moved to `hubstate.db.old`, rebuilt empty and deleted (the hub's state is re-derivable: slices republish on the next 30 s tick, held lines are re-sent by the phone) |
| S12 SliceAssets `.desc` | **Move the key into hubstate.db** | The descriptor (with `K_asset`) becomes a `slice_assets` row in the now-encrypted `hubstate.db`; the sealed files stay. A `.desc` file is never written again; leftovers are deleted |
| S13, S14 | Keep | Already removed after ingest / sealed E2E |
| S15 queued draft | **Move into the DB** | `chat_queued_drafts(surface_key, text, at)` — CHAT-01 (owner text never lost) keeps holding across a quit |
| S16 notification snapshot | **Stop writing content** | Store ids + a sha256 of each title/body; the diff only needs "changed or not". The notification text is read from the database when it fires |
| S18 skills, automation recipes | Keep (owner content) | Owner-written, hash-confirmed recipe files are the source of record for AUTO-*; they are not synced company data |
| S19 exports | Keep | Made on purpose by the owner; #608 can turn exports off in the corp build |
| G13 agentlog.db | #603 Stage 3 | — |

### 3. The one-time step (with #603 Stage 3)

Runs once, right after #603's "Encrypting your database…" step, in the same
splash (seconds; audio sealing is the only heavy part, ~1 s per hour of audio):

1. Import the memory vault into `memory_files`/`memory_history` (the whole git
   history, oldest first), verify every file's sha256 against `memory_nodes.content_hash`,
   then delete `<ws>/memory/` (including `.git`).
2. Import `automation-drafts/*.jsonl` and recording sidecars (`.txt`, `.json`,
   `.meta`) into their tables, then delete them.
3. Seal every `rec_*.caf|m4a` and `chat_files/**`, verify by unsealing the first
   and last chunk, delete the plaintext.
4. Re-key `hubstate.db` (§2), move `.desc` keys into it.
5. Delete old logs (§2), every stale `wt-*`/`watchtower-*` temp file, and
   `<ws>/tmp/extract`.
6. Record `files_outside_db = done` in `db_maintenance`.

Each sub-step is resumable (a crash re-runs it; imports are upserts, a sealed
`.wts` that verifies wins over a leftover plaintext). The step needs free disk
for the largest single file, not 2×. It never deletes a file it failed to
import or seal; such files are listed in the Desktop notice with the encrypted
database ones.

### 4. Staging

| Stage | Needs | Ships |
|---|---|---|
| **A** | Nothing (now) | Log redaction + canary guard test, `daemon.log`/`sessions.log` caps, temp files via pipes/stdin + sweeps, `--no-session-persistence` everywhere, drafts / sidecars / queued draft / notification snapshot into the DB, `.desc` keys into `hubstate.db`, workchat-attachment cleanup at session end |
| **B** | #603 Stage 2 (the key) | Sealed-file primitive; new recordings and attachments sealed; `hubstate.db` keyed; memory vault in the DB for new installs |
| **C** | #603 Stage 3 | The one-time step (§3) for existing installs |

Stage A is useful on its own: it removes the content that exists only by
accident (logs, temp files, CLI session stores) and costs no key work.

### 5. #603 transfer and #601 purge

- **Transfer** (#603 §5.8): `transfer_files` shrinks to the sealed files
  (recordings, chat attachments, re-sealed with the transfer passphrase's key)
  and the owner's recipes/skills; memory and drafts travel inside the database.
  `transfer.Included` gets a guard test against this spec's tables §2.
- **Purge** (#601): unchanged. Memory stays out of the v1 purge scope (its Q2);
  moving it into the DB makes a later Q2-c purge a plain `DELETE`.

## Contracts that change

- **MEM-02** (files are the source of truth) — inverted: `memory_files` is the
  record, the index stays derived and rebuildable from it; the guard test
  compares a `Rebuild` from `memory_files` with the incremental index.
- **MEM-03** (owner edits in their own commit) — kept, over `memory_commits.kind
  = owner_edit` instead of git commits.
- **CHAT-01** — kept; the queued draft moves to the DB.
- **CHAT-04 / chat warm sessions** — `--resume` is no longer used; a respawn
  replays from the database.
- New inventory entries **FILES-01** (no content in logs: canary guard test)
  and **FILES-02** (sealed-file format and key derivation: Go↔Swift fixture).
- `docs/features/memory.md`, `mobile-companion.md`, `meeting-transcriber.md`,
  `chat-redesign.md` and the guide's privacy page change with their stage.

## Questions for the owner

- **Q1. Memory vault** — (a) move it into the database, drop the git repo and
  Obsidian access, `memory export` on request (recommended); (b) keep the files
  and git, seal each file with the DB key (git diffs and Obsidian stop working
  anyway); (c) keep plaintext files, the guide says so.
- **Q2. Meeting audio** — (a) seal it with the DB key once recording stops,
  retention unchanged (recommended); (b) delete the audio as soon as the
  transcript is saved, keep no audio; (c) store audio as blobs in the database.
- **Q3. Files external agents read** (the Claude CLI session store, workchat
  attachments, target images) — (a) no session store for any Watchtower call
  (chats replay from the DB on respawn), agent-read files stay plaintext 0600
  and are deleted at session end / target archive (recommended); (b) as (a),
  but keep `--resume` for AI Chat and delete its session files when the chat
  closes; (c) leave them as today.
- **Q4. Token and credential files** (`*_token.json`, Google/IMAP/CalDAV
  credentials, Quick Connection secrets, `config.yaml` tokens) — not content,
  but the key to it: (a) move them into the encrypted database in Stage B
  (recommended); (b) the Keychain, as backlog #567 proposes; (c) keep 0600 files,
  outside #604.

## Later

- Serve target images to the workbench agent over MCP image content, so they can
  be sealed too.
- Scrub the plaintext the recorder writes during a recording (encrypting while
  recording needs a streaming AAC writer of our own).
- The workbench agents' own transcript stores for sessions in the owner's
  repositories (Claude Code, Codex) are the agents' data; #608 can set their
  retention in the corp build.
- Check, when Stage 3 lands, that `db compact`'s VACUUM temp file
  (`temp_store = FILE`) is written encrypted for a keyed database; if not, compact
  in memory or through `VACUUM INTO` a keyed file.
