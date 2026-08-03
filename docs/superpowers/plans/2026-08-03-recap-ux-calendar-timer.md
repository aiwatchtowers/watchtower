# Recap UX + calendar countdown fixes

## Context

A 1-second test recording linked to an event displayed a full detailed recap. Root cause analysis (2026-08-03):

1. The Recap tab resolves "event recap wins": `RecordingDetailView.load()` sets `recapContent = loaded.recap?.parsed ?? loaded.row?.parsedSummary`. When an earlier real recording of the same event already produced a `meeting_recaps` row, a later short recording shows that recap with no indication it came from another source. Confusing: looks like the AI hallucinated a meeting out of 1 second of audio.
2. `transcript save` generates a recap unconditionally. For a 1s recording the transcript is a Whisper hallucination ("Продолжение следует..."), and `GenerateTranscriptRecap` injects the event title/description/attendees into the prompt — so the strong-tier model "recaps" the event description. Wasted AI call, misleading output.
3. `CalendarEventRow` renders the pre-meeting countdown via `Text(startDate, style: .relative)`, which self-ticks, but the `event.startDate > Date()` gate is only evaluated on re-render. After the meeting starts the label keeps ticking — now counting UP — until something re-renders the list.

## Global Constraints

- Everything committed to the repo is English-only (code, comments, tests, commit messages).
- The `transcript save` stdout envelope is a frozen contract consumed by Swift `TranscriptSaveService`: exit 0 whenever the transcript row was persisted; only ADDITIVE keys may be introduced (the `chapters_ok`/`chapters_error` precedent in `printTranscriptEnvelope`).
- The recap collision guard (existing `meeting_recaps` row is never overwritten; generated recap falls back to `summary_json`) and the "event recap wins" display resolution are unchanged.
- The explicit retry command `watchtower meeting-prep transcript recap <id>` must stay ungated — an explicit user request always generates.
- Do not weaken, rename, or split any guard test.
- Swift verification: `cd WatchtowerDesktop && swift build` / `swift test` — redirect output to a log file and check the real exit code (`$?`); never pipe through `tail`.

## Task 1: Go — skip recap/chapters generation for too-short transcripts in `transcript save`

**File:** `cmd/meeting_transcript.go` (+ its test file).

- Add a package-level constant:
  ```go
  // minRecapTranscriptChars gates the automatic recap (and chapters) generation
  // at save time: Whisper on near-silent audio hallucinates short phrases, and
  // GenerateTranscriptRecap injects the calendar event's description into the
  // prompt — so a near-empty transcript makes the model "recap" the event
  // description instead of the meeting. The explicit `transcript recap <id>`
  // retry command stays ungated (an explicit user request always generates).
  const minRecapTranscriptChars = 200
  ```
- In `runTranscriptSave`, after the row is inserted: when `utf8.RuneCountInString(text) < minRecapTranscriptChars`, do NOT call `generateAndStoreTranscriptRecap` and do NOT attempt chapters generation (leave `chaptersOutcome` nil so no chapters keys are emitted). Report the skip through the envelope.
- Envelope changes in `printTranscriptEnvelope`: introduce an additive `recap_skipped` boolean key, emitted ONLY when the skip happened (the conditional `chapters_ok` precedent). When skipped: `recap_ok=false`, `recap_error="transcript too short (<N> chars): recap skipped"`, `recap_skipped=true`. Choose a clean way to thread this through (e.g. a sentinel error checked with `errors.Is`, or an extra bool parameter) — keep it as simple as possible; update the function's doc comment.
- The `transcript recap <id>` command (`runTranscriptRecap`) is NOT gated; it must never emit `recap_skipped`.
- Tests (use the existing `transcriptGeneratorFactory` seam and the existing test patterns in the package's test file):
  1. Save with a short transcript (e.g. "Продолжение следует..." — 22 chars): generator factory is never invoked, row IS persisted, envelope has `recap_ok=false`, non-empty `recap_error` mentioning "too short", `recap_skipped=true`, exit success.
  2. Save with a transcript of exactly `minRecapTranscriptChars` runes: generator IS invoked (boundary — gate is `<`, not `<=`). Use a rune-count-vs-byte-count-distinguishing string (multibyte characters) so the rune semantics are pinned.
  3. `transcript recap <id>` on a short transcript: generator IS invoked, no `recap_skipped` key in the envelope.
- Verify: `go test ./cmd/ ./internal/meeting/`, `go vet ./...`, `go build ./...`.

## Task 2: Swift — recap provenance label + `recap_skipped` envelope handling

**Files:** `WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailView.swift`, `WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailTabs.swift`, `WatchtowerDesktop/Sources/Services/TranscriptSaveService.swift`, `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift` (+ tests).

Part A — provenance label in the Recap tab:
- In `RecordingDetailView.load()`, alongside the existing `recapContent` resolution, compute whether the displayed recap is the event's `meeting_recaps` row generated from a DIFFERENT source than this recording: `loaded.recap != nil && loaded.recap?.sourceText != loaded.row?.transcriptText` (`MeetingRecap.sourceText` records exactly the text the recap was generated from — an exact match means it IS this recording's recap). Store in a new `@State` and pass into `RecordingRecapTab` as a new `let` (suggested name: `recapFromOtherSource: Bool`).
- In `RecordingRecapTab`, when `recapFromOtherSource` is true and the legacy recap content is shown (the `legacyRecap` path — the chapters path renders transcript-own data and needs no note), render a caption ABOVE the recap content: an `info.circle` icon + text like "Event recap — generated from a different recording or source of this meeting, not from this recording." styled `.caption`/`.secondary`. Keep it one short sentence.
- Update the RecordingRecapTab preview/instantiation sites (`RecordingDetailView.tabContent`) accordingly.

Part B — `recap_skipped` envelope handling:
- `TranscriptSaveService`: decode the new optional `recap_skipped` key (`decodeIfPresent`, default false) into `let recapSkipped: Bool`.
- `MeetingRecorderCenter` (the `!result.recapOK` branch around line 579): when `result.recapSkipped`, send notification title "\(title) — transcript saved (too short for recap)" instead of "…recap needs retry".
- Tests: extend the existing TranscriptSaveService envelope-decoding tests (find them via the existing test naming) with: (1) an envelope carrying `recap_skipped: true` decodes `recapSkipped == true`; (2) an envelope WITHOUT the key (the frozen pre-existing shape) still decodes, `recapSkipped == false`.
- Verify: `cd WatchtowerDesktop && swift build` then `swift test` (log-file + `$?` discipline). If the full suite is prohibitively slow, run at minimum the test targets touching TranscriptSaveService, and a full `swift build`.

## Task 3: Swift — calendar countdown must stop at meeting start

**File:** `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventRow.swift`.

Replace the countdown block in `timeColumn` (currently lines 28-40) with a `TimelineView`-gated version — `TimelineView(.explicit([event.startDate]))` re-evaluates the gate exactly once, at the meeting start, so the self-ticking `.relative` text disappears the moment the meeting begins instead of counting up until the next external re-render:

```swift
// Relative countdown next to the absolute range for events starting
// soon; `.relative` keeps it ticking without a timer. The explicit
// TimelineView schedule re-evaluates the gate exactly at startDate, so
// the countdown disappears the moment the meeting begins instead of
// counting UP until the next external re-render.
if event.isUpcoming {
    TimelineView(.explicit([event.startDate])) { context in
        if context.date < event.startDate {
            HStack(spacing: 3) {
                Text("in")
                Text(event.startDate, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.blue)
        }
    }
}
```

- No behavior change for events that have not started; no new state, no timers.
- Verify: `cd WatchtowerDesktop && swift build` (log-file + `$?` discipline). Pure view change — no unit test required; SwiftLint if configured.
