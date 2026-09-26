---
type: chore
title: "Low-priority findings bundle — bugs (Swift Desktop)"
status: open
priority: low
tags: [swift-bugs, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

7 low-priority findings from the bugs (Swift Desktop) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## Opening a memory node's history shells out to /usr/bin/git, which pops the "install developer tools" dialog on machines without Xcode CLT

- type: bug · confidence: med · tags: [swift, system-prompt, memory, tcc-adjacent]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Utilities/MemoryVaultGit.swift:27-49; ViewModels/MemoryViewModel.swift:348

`/usr/bin/git` is the xcode-select shim. On a Mac without Command Line Tools, running it pops a system "The git command requires the command line developer tools. Install?" dialog, attributed to Watchtower. It pops the moment the owner opens a memory node. The Go side uses go-git precisely to avoid needing git, and the Swift reader then degrades to an empty list anyway, so the prompt buys nothing. It is not a TCC prompt, but it belongs to the same "Watchtower pops system dialogs" class the owner treats as P0. Fix: check `xcode-select -p` / the CLT receipt before spawning, or add a tiny `watchtower memory log --json` CLI command backed by go-git.

## Meeting prep decode fails when the model omits an array: Go emits null, Swift expects non-optional arrays

- type: bug · confidence: med · tags: [swift, dual-path, wire-shape, meeting-prep]
- where: WatchtowerDesktop/Sources/ViewModels/MeetingPrepViewModel.swift:59-81; internal/meeting/pipeline.go:20-30,227-237

`MeetingPrepResult` in Swift declares `talkingPoints`/`openItems`/`peopleNotes`/`suggestedPrep` as non-optional arrays. Go unmarshals the model's JSON straight into a struct whose slices stay nil when a key is missing or `null`, and re-marshals them as `null` (no omitempty, no `[]T{}` init). Scenario: a solo or ad-hoc event with no attendees, where the model returns no `people_notes`. The CLI succeeds, but Swift shows "Failed to parse meeting prep" and discards a valid prep. This is exactly the review-rules wire-shape rule. Fix: normalize nil slices to empty in `prepareForEvent` (plus an empty-state wire test), or make the Swift fields default to `[]`.

## DatabaseManager.runCLIMigrations swallows migration failure, runs on the main thread in onboarding, and never reads its stderr pipe

- type: bug · confidence: high · tags: [swift, migrations, main-thread, error-handling]
- where: WatchtowerDesktop/Sources/Database/DatabaseManager.swift:142-161; App/OnboardingView.swift:1297-1310

Three problems:
1. A non-zero `db migrate` only produces an `NSLog`, and callers go on to open the database. A failed migration (a locked DB, or a schema from a newer CLI) then surfaces later as scattered "no such table/column" errors instead of one clear message.
2. `ensureOnboardingDatabase()` is a MainActor view method that calls it synchronously, so the UI blocks for the migrate run (up to the 30 s watchdog), plus a `findCLIPath` hash (see the finding above).
3. `standardError = Pipe()` is never read, so a chatty migrate (more than 64 KiB of stderr) blocks until the 30 s timer kills it.

Fix: return or throw the exit status plus drained stderr, show it on the splash/onboarding error surface, and run it detached (as `AppState.initialize` already does).

## Merging an idea that already absorbed others leaves a two-hop redirect the consolidator can't follow

- type: bug · confidence: med · tags: [swift, ideas, dual-path, IDEA-03]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaQueries.swift:274-287; internal/ideas/consolidate.go:753-757; Views/Ideas/IdeaDetailPane.swift:514

Scenario: C is merged into A, then the owner merges A into B. The candidate filter allows this, since A is active/proposed. `IdeaQueries.merge` re-parents A's mentions but leaves C's `merged_into_id = A`. `applyAttachMentionOp` follows `merged_into_id` exactly one hop, so a later sighting of C lands on A, a hidden `status='merged'` row. That is what IDEA-03 promises cannot happen ("a later sighting of a merged-away item lands on the survivor"). Fix inside the same write: `UPDATE ideas SET merged_into_id = B WHERE merged_into_id = A`. Relevant to the IDEA-03 guard, so owner review is needed. Secondary: re-parenting can duplicate a `(source, ref)` mention already on B, since the index is non-unique.

## Large free text is passed on argv (--text) to AI commands, so big pastes hit E2BIG and the content is visible in ps

- type: bug · confidence: med · tags: [swift, argv, cli]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Services/MeetingRecapService.swift:14-20; Services/TargetExtractService.swift:21; WatchtowerCore/Services/MeetingTopicsExtractService.swift:32; WatchtowerCore/Services/TrackComposeService.swift:24

The recap sheet invites "paste a recap, transcript fragment, or rough notes". Target extraction and extract-topics also take arbitrary pasted text, and all of these go in as a single argv element. A very large paste (macOS ARG_MAX is ~1 MB including the environment) makes `posix_spawn` fail with "Argument list too long", surfaced as a cryptic launch failure. Meanwhile every paste of meeting content is readable by any local process via `ps` for the call's duration. Transcripts already travel via `--transcript-file` "never argv" for exactly this reason. Fix: add `--text-file`/stdin to `targets extract`, `meeting-prep recap` and `extract-topics`, and use a temp file (the `TranscriptSaveService` pattern).

## "Silent" auth trust-cert actually edits user trust settings, which macOS gates behind a password dialog

- type: question · confidence: low · tags: [swift, system-prompt, slack-auth, onboarding]
- where: WatchtowerDesktop/Sources/App/OnboardingView.swift:1204-1225; Views/Settings/SlackConnectionDetail.swift:349-351; internal/auth/cert.go:152-191

Both Swift call sites say the trust step is "silent — adds to user trust store, no password needed". `TrustCert` runs `security add-trusted-cert -r trustRoot -p ssl -k login.keychain`. Modifying per-user certificate trust settings normally raises the "security is trying to modify your Certificate Trust Settings — enter your password" authorization dialog. That would be an unexpected system prompt on the first Slack connect, and on reconnect whenever the cert was regenerated. Not verified on a live machine. Worth confirming on a clean account; if it prompts, fix the copy and consider an alternative (a trusted loopback without HTTPS, or the `--app-return` flow the other providers use).

## Settings "Test Connection" probes have no timeout and no safe working directory

- type: bug · confidence: med · tags: [swift, process, settings, tcc-hygiene]
- where: WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift:479-513

`runCLIProbe` launches `claude -p …` / `codex exec …` directly, with no watchdog and no `currentDirectoryURL`. Every other AI-spawning site sets `Constants.processWorkingDirectory()`, whose documented purpose is avoiding TCC prompts from a child scanning a protected cwd. A hung provider CLI, such as the codex version-skew hangs recorded in project memory, leaves "Testing…" spinning forever with no cancel. The probe also runs in the app's inherited cwd. Fix: set the safe cwd and add a timeout that terminates the probe (the `stopDaemonBounded` pattern).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
