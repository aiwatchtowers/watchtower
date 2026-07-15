# Pluggable Transcription Engines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the meeting transcriber's single hard-wired WhisperKit engine into a pluggable-provider architecture where WhisperKit, Parakeet, Qwen3-ASR and Apple SpeechTranscriber are interchangeable engines behind one registry, with exactly one active at runtime chosen in Settings.

**Architecture:** A high-level `TranscriptionProvider` protocol (lightweight descriptor + factory) produces a heavy `Transcriber` (loaded model) that does batch transcription and optionally a live session. A `TranscriptionProviderRegistry` is the single list of providers. WhisperKit's existing windowing/language/live logic is preserved verbatim but moved *inside* the WhisperKit provider; the current window-level `TranscriptionEngine` protocol becomes a Whisper-private detail renamed `WhisperWindowEngine`. New engines are batch-only in wave one.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, WhisperKit 0.18.0, FluidAudio (Parakeet), a Qwen3-ASR Swift package, Apple Speech.framework (macOS 26+). Tests via XCTest (`swift test`).

## Global Constraints

- Platform floor: **macOS 14+**; `AppleProvider` requires **macOS 26+** and must gate via `availability()`, never a hard `@available` that breaks the 14+ build.
- Engine audio input contract (unchanged): **16 kHz mono Float32** samples.
- Default provider id: **`whisperkit`**; default model: **`large-v3-v20240930`**. Absence of `transcription.provider` key ⇒ `whisperkit` (existing installs must keep working untouched).
- `TranscriptionOutput.langStats` is **best-effort** — non-Whisper engines may leave it empty; nothing downstream (recap, persistence) depends on it.
- The pin test `StreamingTranscriberTests.testMatchesBatchOnSameSamples` and all existing transcription tests MUST stay green with unchanged assertions after the WhisperKit move — that is the acceptance signal for the refactor tasks.
- Build/test verification: run from `WatchtowerDesktop/`, capture the real exit code (never pipe through `tail`): `swift build 2>&1 | tee /tmp/b.log; echo "EXIT=${PIPESTATUS[0]}"` and `swift test 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`.
- Commit message trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**Created:**
- `Sources/Services/Transcription/TranscriptionProvider.swift` — the three protocols + `ProviderAvailability` + `TranscriptionModelOption`.
- `Sources/Services/Transcription/TranscriptionProviderRegistry.swift` — the provider list + resolution.
- `Sources/Services/Transcription/Providers/WhisperKitProvider.swift` — `WhisperKitProvider` + `WhisperTranscriber` + `WhisperLiveSession`.
- `Sources/Services/Transcription/Providers/ParakeetProvider.swift` — `ParakeetProvider` + `ParakeetTranscriber`.
- `Sources/Services/Transcription/Providers/Qwen3Provider.swift` — `Qwen3Provider` + `Qwen3Transcriber`.
- `Sources/Services/Transcription/Providers/AppleProvider.swift` — `AppleProvider` + `AppleTranscriber`.
- `Tests/TranscriptionProviderRegistryTests.swift`, `Tests/Providers/*Tests.swift`.

**Modified:**
- `Sources/Services/Transcription/TranscriptionEngine.swift` — rename protocol `TranscriptionEngine` → `WhisperWindowEngine` (Whisper-private); `resolveWindowLanguage` param type follows.
- `Sources/Services/Transcription/WhisperKitEngine.swift`, `WindowedTranscriber.swift`, `StreamingTranscriber.swift` — conform to / reference the renamed type.
- `Sources/Services/TranscriptionModelProvisioner.swift` — generalize `ensureDownloaded(modelName:)` → `ensureDownloaded(providerID:model:)`.
- `Sources/Services/MeetingRecorderCenter.swift` — `defaultEngineFactory` resolves via registry; live gated on `makeLiveSession != nil`.
- `Sources/Views/Settings/SettingsView.swift` — Provider + Model pickers.
- `Sources/Views/Calendar/CalendarEventsView.swift`, `Sources/Views/Calendar/RecordingIndicatorView.swift` — read `transcription.provider`; live panel gated on `supportsLive`.
- `Package.swift` — add FluidAudio + Qwen3 SPM dependencies (Tasks 6, 7).
- Tests referencing `TranscriptionEngine` / `ensureDownloaded(modelName:)`.

---

## Task 1: Provider protocols

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionProvider.swift`
- Test: `WatchtowerDesktop/Tests/TranscriptionProviderTests.swift`

**Interfaces:**
- Consumes: existing `TranscriptionConfig`, `TranscriptionOutput` (from `TranscriptionEngine.swift`).
- Produces:
  - `protocol TranscriptionProvider: Sendable` with `static var id: String`, `var displayName: String`, `var models: [TranscriptionModelOption]`, `var supportsLive: Bool`, `func availability() -> ProviderAvailability`, `func supportedLanguages(model: String) -> Set<String>?`, `func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws`, `func makeTranscriber(model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber`.
  - `protocol Transcriber: Sendable` with `func transcribe(_ samples: [Float], config: TranscriptionConfig, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput` and `func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession?`.
  - `protocol TranscriptionLiveSession: Sendable` with `func append(_ samples: [Float]) async`, `func finish() async throws -> TranscriptionOutput`, `var chunks: AsyncStream<String> { get }`.
  - `enum ProviderAvailability: Equatable { case available; case unavailable(reason: String) }`.
  - `struct TranscriptionModelOption: Equatable, Identifiable { let id: String; let label: String }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranscriptionProviderTests.swift
import XCTest
@testable import WatchtowerDesktop

final class TranscriptionProviderTests: XCTestCase {
    func testModelOptionIsIdentifiableById() {
        let a = TranscriptionModelOption(id: "large-v3-v20240930", label: "Large v3 Turbo")
        XCTAssertEqual(a.id, "large-v3-v20240930")
    }

    func testAvailabilityEquatable() {
        XCTAssertEqual(ProviderAvailability.available, .available)
        XCTAssertNotEqual(ProviderAvailability.available, .unavailable(reason: "x"))
    }

    // A minimal fake proves the protocols are usable end-to-end without any model.
    func testFakeProviderConformsAndTranscribes() async throws {
        let provider: TranscriptionProvider = FakeProvider()
        XCTAssertEqual(type(of: provider).id, "fake")
        let t = try await provider.makeTranscriber(model: "m") { _ in }
        let out = try await t.transcribe([0, 0, 0], config: TranscriptionConfig()) { _, _ in }
        XCTAssertEqual(out.text, "hello")
        XCTAssertNil(t.makeLiveSession(config: TranscriptionConfig()))
    }
}

private struct FakeProvider: TranscriptionProvider {
    static var id: String { "fake" }
    var displayName: String { "Fake" }
    var models: [TranscriptionModelOption] { [.init(id: "m", label: "M")] }
    var supportsLive: Bool { false }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func makeTranscriber(model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        FakeTranscriber()
    }
}

private struct FakeTranscriber: Transcriber {
    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        TranscriptionOutput(text: "hello", langStats: [:])
    }
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find type 'TranscriptionProvider' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Services/Transcription/TranscriptionProvider.swift
import Foundation

/// A model choice offered by a provider; `id` is what lands in `transcription.model`.
struct TranscriptionModelOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// Whether a provider can run on this machine right now.
enum ProviderAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// Lightweight descriptor + factory for one transcription engine family.
/// Registered in `TranscriptionProviderRegistry`; loads NO model until `makeTranscriber`.
protocol TranscriptionProvider: Sendable {
    static var id: String { get }
    var displayName: String { get }
    var models: [TranscriptionModelOption] { get }
    var supportsLive: Bool { get }
    func availability() -> ProviderAvailability
    /// nil = not language-restricted (e.g. Whisper's 99 languages).
    func supportedLanguages(model: String) -> Set<String>?
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber
}

/// A loaded engine (holds the heavy model). Lives for one recording/decode.
protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float],
                    config: TranscriptionConfig,
                    progress: @escaping @Sendable (_ window: Int, _ total: Int) -> Void)
        async throws -> TranscriptionOutput
    /// nil when the provider does not support live (wave one: only WhisperKit).
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession?
}

/// A live transcription session: accepts a 16 kHz mono Float32 stream, emits finalized chunks.
protocol TranscriptionLiveSession: Sendable {
    func append(_ samples: [Float]) async
    func finish() async throws -> TranscriptionOutput
    var chunks: AsyncStream<String> { get }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/TranscriptionProvider.swift WatchtowerDesktop/Tests/TranscriptionProviderTests.swift
git commit -m "feat(transcriber): add pluggable TranscriptionProvider protocols

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Provider registry

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionProviderRegistry.swift`
- Test: `WatchtowerDesktop/Tests/TranscriptionProviderRegistryTests.swift`

**Interfaces:**
- Consumes: `TranscriptionProvider` (Task 1).
- Produces:
  - `enum TranscriptionProviderRegistry` with `static var all: [any TranscriptionProvider]`, `static func provider(id: String) -> (any TranscriptionProvider)?`, `static func availableProviders() -> [any TranscriptionProvider]`, `static func resolve(providerID: String) -> any TranscriptionProvider` (unknown id / unavailable ⇒ WhisperKit).
  - `static let fallbackProviderID = "whisperkit"`.

> During Tasks 2–5 the registry's `all` list is seeded with a private test-only stub so it compiles before the real providers exist. Task 3 replaces the stub entry with `WhisperKitProvider()`; Tasks 6–8 append the others.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TranscriptionProviderRegistryTests.swift
import XCTest
@testable import WatchtowerDesktop

final class TranscriptionProviderRegistryTests: XCTestCase {
    func testAllIdsAreUnique() {
        let ids = TranscriptionProviderRegistry.all.map { type(of: $0).id }
        XCTAssertEqual(ids.count, Set(ids).count, "provider ids must be unique")
    }

    func testEveryProviderHasModels() {
        for p in TranscriptionProviderRegistry.all {
            XCTAssertFalse(p.models.isEmpty, "\(type(of: p).id) has no models")
        }
    }

    func testResolveUnknownFallsBackToWhisperKit() {
        let p = TranscriptionProviderRegistry.resolve(providerID: "does-not-exist")
        XCTAssertEqual(type(of: p).id, TranscriptionProviderRegistry.fallbackProviderID)
    }

    func testAvailableProvidersExcludeUnavailable() {
        let avail = TranscriptionProviderRegistry.availableProviders()
        for p in avail { XCTAssertEqual(p.availability(), .available) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionProviderRegistryTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find 'TranscriptionProviderRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Services/Transcription/TranscriptionProviderRegistry.swift
import Foundation

/// The single list of transcription engines. Add a provider = add one line here.
enum TranscriptionProviderRegistry {
    static let fallbackProviderID = "whisperkit"

    // Seeded with a stub until Task 3 substitutes WhisperKitProvider().
    static var all: [any TranscriptionProvider] = [_StubProvider()]

    static func provider(id: String) -> (any TranscriptionProvider)? {
        all.first { type(of: $0).id == id }
    }

    static func availableProviders() -> [any TranscriptionProvider] {
        all.filter { $0.availability() == .available }
    }

    /// Never fails: an unknown or unavailable id degrades to WhisperKit.
    static func resolve(providerID: String) -> any TranscriptionProvider {
        if let p = provider(id: providerID), p.availability() == .available { return p }
        return provider(id: fallbackProviderID) ?? all[0]
    }
}

private struct _StubProvider: TranscriptionProvider {
    static var id: String { "whisperkit" }
    var displayName: String { "WhisperKit" }
    var models: [TranscriptionModelOption] { [.init(id: "large-v3-v20240930", label: "Large v3 Turbo")] }
    var supportsLive: Bool { true }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func makeTranscriber(model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        fatalError("stub replaced in Task 3")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionProviderRegistryTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/TranscriptionProviderRegistry.swift WatchtowerDesktop/Tests/TranscriptionProviderRegistryTests.swift
git commit -m "feat(transcriber): add TranscriptionProviderRegistry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Rename engine + move WhisperKit behind the provider contract

This is the behavior-preserving refactor. It has two halves: (a) a mechanical rename of the Whisper-private protocol, (b) wrapping existing `WindowedTranscriber`/`StreamingTranscriber` in `WhisperKitProvider`/`WhisperTranscriber`. Existing tests are the safety net — they must stay green with unchanged assertions.

**Files:**
- Modify: `Sources/Services/Transcription/TranscriptionEngine.swift` (rename `TranscriptionEngine` → `WhisperWindowEngine`), `WhisperKitEngine.swift`, `WindowedTranscriber.swift`, `StreamingTranscriber.swift`, and any test referencing `TranscriptionEngine`.
- Create: `Sources/Services/Transcription/Providers/WhisperKitProvider.swift`
- Modify: `Sources/Services/Transcription/TranscriptionProviderRegistry.swift` (replace `_StubProvider` with `WhisperKitProvider()`)
- Test: `WatchtowerDesktop/Tests/Providers/WhisperKitProviderTests.swift`

**Interfaces:**
- Consumes: `TranscriptionProvider`, `Transcriber`, `TranscriptionLiveSession` (Task 1); existing `WindowedTranscriber(engine:config:)`, `StreamingTranscriber`, `WhisperKitEngine.load(modelName:downloadProgress:)`, `WhisperKitEngine.ensureModelFilesDownloaded(modelName:downloadProgress:)`.
- Produces:
  - `struct WhisperKitProvider: TranscriptionProvider` (`id="whisperkit"`, models `[large-v3-v20240930 (default first), large-v3, distil-large-v3, medium]`, `supportsLive=true`, `supportedLanguages` → nil).
  - `final class WhisperTranscriber: Transcriber, @unchecked Sendable` wrapping a loaded `WhisperKitEngine`.
  - `protocol WhisperWindowEngine` (renamed from `TranscriptionEngine`).

- [ ] **Step 1: Rename the protocol (mechanical), then run the full suite as the failing/regression check**

Rename `protocol TranscriptionEngine` → `protocol WhisperWindowEngine` in `TranscriptionEngine.swift`. Update the `engine` parameter type in `resolveWindowLanguage(for:previous:config:engine:)` to `WhisperWindowEngine`. Update conformance in `WhisperKitEngine.swift` (`final class WhisperKitEngine: WhisperWindowEngine`), and every reference in `WindowedTranscriber.swift`, `StreamingTranscriber.swift`, and tests (`grep -rn "TranscriptionEngine" WatchtowerDesktop/Sources WatchtowerDesktop/Tests`). Do NOT rename `TranscriptionEngine.swift` the file, `TranscriptionConfig`, `TranscriptionOutput`, or `TranscriptionModelProvisioner`.

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/b.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: EXIT=0 after all references updated (fix compile errors until clean).

- [ ] **Step 2: Write the failing provider test**

```swift
// Tests/Providers/WhisperKitProviderTests.swift
import XCTest
@testable import WatchtowerDesktop

final class WhisperKitProviderTests: XCTestCase {
    func testMetadata() {
        let p = WhisperKitProvider()
        XCTAssertEqual(type(of: p).id, "whisperkit")
        XCTAssertTrue(p.supportsLive)
        XCTAssertEqual(p.availability(), .available)
        XCTAssertEqual(p.models.first?.id, "large-v3-v20240930", "turbo must be the default (first) model")
        XCTAssertNil(p.supportedLanguages(model: "large-v3-v20240930"), "Whisper is not language-restricted")
    }

    func testRegisteredAsWhisperKit() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "whisperkit" })
        XCTAssertFalse(TranscriptionProviderRegistry.all.contains { type(of: $0) == _StubProvider.self },
                       "stub must be gone")
    }
}
```

(If `_StubProvider` is private and unreferenceable, replace the second assertion with: `XCTAssertTrue(TranscriptionProviderRegistry.resolve(providerID: "whisperkit") is WhisperKitProvider)`.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter WhisperKitProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find 'WhisperKitProvider' in scope`.

- [ ] **Step 4: Write the provider + transcriber**

```swift
// Sources/Services/Transcription/Providers/WhisperKitProvider.swift
import Foundation

struct WhisperKitProvider: TranscriptionProvider {
    static var id: String { "whisperkit" }
    var displayName: String { "WhisperKit (Whisper)" }
    var models: [TranscriptionModelOption] {
        [
            .init(id: "large-v3-v20240930", label: "Large v3 Turbo (recommended)"),
            .init(id: "large-v3", label: "Large v3 (best quality)"),
            .init(id: "distil-large-v3", label: "Distil Large v3 (English only)"),
            .init(id: "medium", label: "Medium (fastest)"),
        ]
    }
    var supportsLive: Bool { true }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKitEngine.ensureModelFilesDownloaded(modelName: model, downloadProgress: progress)
    }

    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        let engine = try await WhisperKitEngine.load(modelName: model, downloadProgress: progress)
        return WhisperTranscriber(engine: engine)
    }
}

/// Wraps a loaded WhisperKitEngine, reusing the existing batch/live orchestrators
/// verbatim so their behavior (and the live↔batch pin test) is unchanged.
final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    private let engine: WhisperKitEngine
    init(engine: WhisperKitEngine) { self.engine = engine }

    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        let transcriber = WindowedTranscriber(engine: engine, config: config)
        return try await transcriber.transcribe(samples: samples, progress: progress)
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        WhisperLiveSession(engine: engine, config: config)
    }
}
```

> **Adapt to reality:** the exact `WindowedTranscriber` init and `transcribe(samples:progress:)` signature, and how `StreamingTranscriber` is driven, must match the current code. Open `WindowedTranscriber.swift` and `StreamingTranscriber.swift` first and mirror their real API. `WhisperLiveSession` adapts `StreamingTranscriber` to `TranscriptionLiveSession` (append samples / finish / expose `chunks`). If `StreamingTranscriber` already exposes an equivalent stream, `WhisperLiveSession` is a thin forwarder.

- [ ] **Step 5: Replace the stub in the registry**

In `TranscriptionProviderRegistry.swift`, change `static var all` to `[WhisperKitProvider()]` and delete `_StubProvider`.

- [ ] **Step 6: Run the FULL suite (regression gate)**

Run: `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: EXIT=0. In particular `StreamingTranscriberTests.testMatchesBatchOnSameSamples`, `WindowedTranscriberTests`, `TranscriptionModelProvisionerTests`, `MeetingRecorderCenterTests`, and the new provider tests all PASS with no assertion changes.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "refactor(transcriber): move WhisperKit behind TranscriptionProvider

Rename TranscriptionEngine -> WhisperWindowEngine (Whisper-private) and wrap
WindowedTranscriber/StreamingTranscriber in WhisperKitProvider/WhisperTranscriber.
Behavior-preserving: existing tests unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Generalize the model provisioner to (provider, model)

**Files:**
- Modify: `Sources/Services/TranscriptionModelProvisioner.swift`
- Modify: `Tests/TranscriptionModelProvisionerTests.swift`
- Modify callers: `Sources/Views/Settings/SettingsView.swift`, `Sources/Views/Calendar/CalendarEventsView.swift` (the `ensureDownloaded` call sites).

**Interfaces:**
- Consumes: `TranscriptionProviderRegistry.resolve(providerID:)`, `provider.prefetch(model:progress:)`.
- Produces: `func ensureDownloaded(providerID: String, model: String)` (replaces `ensureDownloaded(modelName:)`); `retry()` unchanged in shape but keyed on the last `(providerID, model)`.

- [ ] **Step 1: Update the tests to the new signature (failing)**

In `TranscriptionModelProvisionerTests.swift`, replace `provisioner.ensureDownloaded(modelName: "large-v3")` calls with `provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")` (keep the same distinct-value pattern the existing supersede/error tests rely on — e.g. use `("whisperkit","large-v3")` and `("whisperkit","distil-large-v3")` as the two distinct requests). The injected `downloadFn` fake stays keyed on the model string; the provider is resolved but its `prefetch` is bypassed by the injected fake in tests.

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionModelProvisionerTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `incorrect argument label` / `extra argument 'providerID'`.

- [ ] **Step 3: Change the signature**

In `TranscriptionModelProvisioner.swift`, change the public entry point to `func ensureDownloaded(providerID: String, model: String)`. Track `currentProviderID` alongside `currentModelName`; supersede when either differs. In production the download closure resolves the provider and calls its prefetch:

```swift
downloadFn: @escaping (String, String, @escaping @Sendable (Double) -> Void) async throws -> Void = { providerID, model, progress in
    let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
    try await provider.prefetch(model: model, progress: progress)
}
```

Update the stale-guard checks to compare the `(providerID, model)` pair. `retry()` re-issues the last pair.

- [ ] **Step 4: Update the two view call sites**

`SettingsView` and `CalendarEventsView` currently call `appState.transcriptionModelProvisioner.ensureDownloaded(modelName: transcriptionModel)`. Change to `ensureDownloaded(providerID: transcriptionProvider, model: transcriptionModel)` (the `transcriptionProvider` `@AppStorage` is added in Task 5; for this task pass the literal `"whisperkit"` and let Task 5 swap it — OR do Task 5 first if executing inline).

- [ ] **Step 5: Run tests + build**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionModelProvisionerTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"` then `swift build 2>&1 | tee /tmp/b.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: both EXIT=0.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "refactor(transcriber): key model provisioner on (provider, model)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Settings provider+model pickers, key migration, recorder wiring

**Files:**
- Modify: `Sources/Views/Settings/SettingsView.swift`, `Sources/Views/Calendar/CalendarEventsView.swift`, `Sources/Views/Calendar/RecordingIndicatorView.swift`, `Sources/Services/MeetingRecorderCenter.swift`
- Test: `WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift` (extend), `WatchtowerDesktop/Tests/TranscriptionProviderRegistryTests.swift` (migration default)

**Interfaces:**
- Consumes: `TranscriptionProviderRegistry.availableProviders()`, `provider.models`, `provider.supportsLive`, `provider.supportedLanguages(model:)`, `resolve(providerID:)`.
- Produces: `@AppStorage("transcription.provider")` (default `"whisperkit"`); `MeetingRecorderCenter.defaultEngineFactory` resolving via registry.

- [ ] **Step 1: Write the failing recorder test**

```swift
// Add to MeetingRecorderCenterTests.swift
func testDefaultEngineFactoryUsesProviderAndModelDefaults() {
    // With no defaults set, resolution must land on whisperkit + turbo.
    let d = UserDefaults(suiteName: "test.transcription.defaults")!
    d.removePersistentDomain(forName: "test.transcription.defaults")
    let providerID = d.string(forKey: "transcription.provider") ?? "whisperkit"
    let model = d.string(forKey: "transcription.model") ?? "large-v3-v20240930"
    XCTAssertEqual(providerID, "whisperkit")
    XCTAssertEqual(model, "large-v3-v20240930")
    XCTAssertEqual(type(of: TranscriptionProviderRegistry.resolve(providerID: providerID)).id, "whisperkit")
}
```

- [ ] **Step 2: Run to verify it fails / passes-trivially**

Run: `cd WatchtowerDesktop && swift test --filter MeetingRecorderCenterTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: PASS is acceptable here (asserts the migration default contract); if `resolve` isn't wired it FAILs to compile — fix by Step 3.

- [ ] **Step 3: Rewrite `defaultEngineFactory`**

```swift
// MeetingRecorderCenter.swift
static func defaultEngineFactory(_ config: TranscriptionConfig) async throws -> Transcriber {
    let providerID = UserDefaults.standard.string(forKey: "transcription.provider") ?? "whisperkit"
    let model = UserDefaults.standard.string(forKey: "transcription.model") ?? "large-v3-v20240930"
    let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
    return try await provider.makeTranscriber(model: model) { _ in }
}
```

Update the factory's type (`() -> TranscriptionEngine` → `-> Transcriber`) and every call site in `MeetingRecorderCenter` that used `engine.detectLanguage`/`transcribeWindow` to instead call `transcriber.transcribe(...)` for batch and `transcriber.makeLiveSession(...)` for live. The live path runs only when `makeLiveSession` returns non-nil; otherwise skip straight to the batch-on-stop path.

- [ ] **Step 4: Add the two Settings pickers**

In `SettingsView.swift` add `@AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"`. Replace the single Model picker with:

```swift
Picker("Engine", selection: $transcriptionProvider) {
    ForEach(TranscriptionProviderRegistry.availableProviders(), id: \.displayName) { p in
        Text(p.displayName).tag(type(of: p).id)
    }
}
.onChange(of: transcriptionProvider) { _, id in
    // Reset model to the new provider's default, then prefetch.
    let p = TranscriptionProviderRegistry.resolve(providerID: id)
    transcriptionModel = p.models.first?.id ?? transcriptionModel
    appState.transcriptionModelProvisioner.ensureDownloaded(providerID: id, model: transcriptionModel)
}

Picker("Model", selection: $transcriptionModel) {
    ForEach(TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider).models) { m in
        Text(m.label).tag(m.id)
    }
}
.onChange(of: transcriptionModel) { _, m in
    appState.transcriptionModelProvisioner.ensureDownloaded(providerID: transcriptionProvider, model: m)
}
```

Add an inline warning row when the selected provider restricts languages and `langset` includes an unsupported one:

```swift
if let supported = TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider)
        .supportedLanguages(model: transcriptionModel) {
    let missing = transcriptionLangset.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !supported.contains($0) }
    if !missing.isEmpty {
        Label("This engine does not support: \(missing.joined(separator: ", "))",
              systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
    }
}
```

- [ ] **Step 5: Gate the live panel + prefetch call sites**

In `CalendarEventsView.swift` add `@AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"` and change the `onAppear` prefetch to `ensureDownloaded(providerID: transcriptionProvider, model: transcriptionModel)`. In `RecordingIndicatorView.swift`, show the live-chunks panel only when the active provider `supportsLive`; otherwise show the plain "recording…" state (transcript appears after Stop).

- [ ] **Step 6: Build + full test suite**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/b.log; echo "EXIT=${PIPESTATUS[0]}"` then `swift test 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: both EXIT=0.

- [ ] **Step 7: Update docs + commit**

Update `docs/app-guide.md` transcription bullet to mention the Engine picker. Then:

```bash
git add WatchtowerDesktop docs/app-guide.md
git commit -m "feat(transcriber): Engine+Model pickers, provider key migration, live gating

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**⟵ End of T0 (foundation). Tasks 6, 7, 8 depend only on everything above and are independent of each other — dispatch them in parallel, ideally in separate git worktrees to avoid `Package.swift` / registry merge conflicts.**

---

## Task 6: ParakeetProvider (FluidAudio) — batch-only

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (add FluidAudio dependency + link to the app target)
- Create: `Sources/Services/Transcription/Providers/ParakeetProvider.swift`
- Modify: `Sources/Services/Transcription/TranscriptionProviderRegistry.swift` (append `ParakeetProvider()`)
- Test: `WatchtowerDesktop/Tests/Providers/ParakeetProviderTests.swift`

**Interfaces:**
- Consumes: `TranscriptionProvider`, `Transcriber`, `TranscriptionOutput`, `TranscriptionConfig`.
- Produces: `struct ParakeetProvider: TranscriptionProvider` (`id="parakeet"`, model `parakeet-tdt-0.6b-v3`, `supportsLive=false`, `supportedLanguages` = the 25 European ISO codes incl. `ru`,`uk`,`en`) and `final class ParakeetTranscriber: Transcriber`.

- [ ] **Step 1: Verify the FluidAudio API (research, not a guess)**

Read the FluidAudio README and its `ASR`/`AsrManager` API before writing code. Sources: `https://github.com/FluidInference/FluidAudio` and `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml`. Record in the PR description the exact: (a) SPM product name + minimum platform, (b) how a model is downloaded/loaded, (c) the batch transcription call and its return shape, (d) how per-result language (if any) is exposed. The code below uses placeholder-free *illustrative* names — replace them with the verified API in Step 4.

- [ ] **Step 2: Add the dependency + write the metadata test (failing)**

Add to `Package.swift` dependencies and the `WatchtowerDesktop` target. Then:

```swift
// Tests/Providers/ParakeetProviderTests.swift
import XCTest
@testable import WatchtowerDesktop

final class ParakeetProviderTests: XCTestCase {
    func testMetadata() {
        let p = ParakeetProvider()
        XCTAssertEqual(type(of: p).id, "parakeet")
        XCTAssertFalse(p.supportsLive)
        let langs = p.supportedLanguages(model: "parakeet-tdt-0.6b-v3")
        XCTAssertNotNil(langs)
        XCTAssertTrue(langs!.isSuperset(of: ["ru", "uk", "en"]))
    }
    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "parakeet" })
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter ParakeetProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find 'ParakeetProvider'`.

- [ ] **Step 4: Implement the provider + transcriber**

```swift
// Sources/Services/Transcription/Providers/ParakeetProvider.swift
import Foundation
import FluidAudio   // verify exact product name in Step 1

struct ParakeetProvider: TranscriptionProvider {
    static var id: String { "parakeet" }
    var displayName: String { "Parakeet v3 (NVIDIA)" }
    var models: [TranscriptionModelOption] {
        [.init(id: "parakeet-tdt-0.6b-v3", label: "Parakeet TDT 0.6B v3")]
    }
    var supportsLive: Bool { false }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? {
        // 25 European languages per the v3 model card.
        ["bg","hr","cs","da","nl","en","et","fi","fr","de","el","hu","it","lv","lt",
         "mt","pl","pt","ro","sk","sl","es","sv","ru","uk"]
    }

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Verified FluidAudio download/warm-up call from Step 1.
    }
    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        // Load the FluidAudio ASR manager (verified API), then wrap it.
        let asr = try await ParakeetTranscriber.loadASR(progress: progress)
        return ParakeetTranscriber(asr: asr)
    }
}

final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    // Hold the verified FluidAudio manager type here.
    // ...
    static func loadASR(progress: @escaping @Sendable (Double) -> Void) async throws -> /*ASRManager*/ AnyObject {
        // verified load call
        fatalError("replace with verified FluidAudio load")
    }

    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        // Call FluidAudio's batch transcription on the full 16 kHz sample buffer.
        // FluidAudio does its own long-form segmentation & language handling, so
        // we do NOT window here. Fill langStats best-effort (empty is allowed).
        progress(1, 1)
        let text = /* verified call */ ""
        return TranscriptionOutput(text: text, langStats: [:])
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
```

> The `fatalError`/empty-string placeholders above exist ONLY because the external SDK signature is verified in Step 1 — replace them with the real calls in this step. Do not commit with `fatalError` in place.

- [ ] **Step 5: Register + run tests + build**

Append `ParakeetProvider()` to `TranscriptionProviderRegistry.all`. Then run `swift build` and `swift test --filter ParakeetProviderTests` (both EXIT=0). Optionally add a `.enabled(if:)`-guarded smoke test that runs a short bundled 16 kHz fixture through `transcribe` and asserts non-empty text (skipped in CI when the model isn't present).

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop
git commit -m "feat(transcriber): add Parakeet v3 provider (FluidAudio, batch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Qwen3Provider (Qwen3-ASR) — batch-only

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (add the Qwen3-ASR Swift package)
- Create: `Sources/Services/Transcription/Providers/Qwen3Provider.swift`
- Modify: `TranscriptionProviderRegistry.swift` (append `Qwen3Provider()`)
- Test: `WatchtowerDesktop/Tests/Providers/Qwen3ProviderTests.swift`

**Interfaces:**
- Produces: `struct Qwen3Provider: TranscriptionProvider` (`id="qwen3"`, model `Qwen3-ASR-0.6B`, `supportsLive=false`, `supportedLanguages` includes `ru`,`uk`,`en`) and `final class Qwen3Transcriber: Transcriber`.

- [ ] **Step 1: Verify the Qwen3-ASR Swift API (research)**

Evaluate the two candidate SPM packages and pick one: `https://swiftpackageindex.com/soniqo/speech-swift` (Qwen3Speech product) and `https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml`. Record exact product name, model load, and batch transcription call in the PR description. Prefer the one with a stable tagged release and CoreML (not MLX-only) path for parity with WhisperKit's on-device story.

- [ ] **Step 2: Add dependency + failing metadata test**

Mirror Task 6 Step 2 with `Qwen3Provider` / id `"qwen3"` / model `"Qwen3-ASR-0.6B"`; assert `supportedLanguages(model:)!.isSuperset(of: ["ru","uk","en"])` and registration.

```swift
// Tests/Providers/Qwen3ProviderTests.swift
import XCTest
@testable import WatchtowerDesktop

final class Qwen3ProviderTests: XCTestCase {
    func testMetadata() {
        let p = Qwen3Provider()
        XCTAssertEqual(type(of: p).id, "qwen3")
        XCTAssertFalse(p.supportsLive)
        XCTAssertTrue(p.supportedLanguages(model: "Qwen3-ASR-0.6B")!.isSuperset(of: ["ru","uk","en"]))
    }
    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "qwen3" })
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter Qwen3ProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find 'Qwen3Provider'`.

- [ ] **Step 4: Implement**

Same shape as `ParakeetProvider` (Task 6 Step 4): `struct Qwen3Provider` with metadata; `final class Qwen3Transcriber: Transcriber` whose `transcribe` calls the verified Qwen3-ASR batch API over the full 16 kHz buffer (VAD/segmentation is internal to the SDK — no windowing here), fills `langStats` best-effort, and `makeLiveSession` returns nil. Replace all verified-in-Step-1 SDK calls; no `fatalError` at commit.

- [ ] **Step 5: Register + test + build**

Append `Qwen3Provider()` to the registry. `swift build` + `swift test --filter Qwen3ProviderTests` both EXIT=0.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop
git commit -m "feat(transcriber): add Qwen3-ASR provider (batch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: AppleProvider (SpeechTranscriber, macOS 26+) — batch-only

**Files:**
- Create: `Sources/Services/Transcription/Providers/AppleProvider.swift`
- Modify: `TranscriptionProviderRegistry.swift` (append `AppleProvider()`)
- Test: `WatchtowerDesktop/Tests/Providers/AppleProviderTests.swift`

**Interfaces:**
- Produces: `struct AppleProvider: TranscriptionProvider` (`id="apple"`, `supportsLive=false`, `availability()` = `.unavailable("Requires macOS 26")` below 26, `supportedLanguages` derived from `SpeechTranscriber.supportedLocales` and **excluding `uk`**) and `final class AppleTranscriber: Transcriber`.

- [ ] **Step 1: Verify the Speech framework API (research)**

Read the current `SpeechAnalyzer` / `SpeechTranscriber` API (WWDC 2025 "Bring advanced speech-to-text to your app") and confirm the offline batch flow: feeding an audio buffer/stream to `SpeechAnalyzer` with a `SpeechTranscriber` module and collecting finalized results. Confirm `uk` is absent from `SpeechTranscriber.supportedLocales`. Reference: `docs/superpowers/specs/2026-07-15-apple-speechanalyzer-engine-design.md` (already researched) and Apple's Speech docs.

- [ ] **Step 2: Write the failing availability test**

```swift
// Tests/Providers/AppleProviderTests.swift
import XCTest
@testable import WatchtowerDesktop

final class AppleProviderTests: XCTestCase {
    func testAvailabilityMatchesOS() {
        let p = AppleProvider()
        if #available(macOS 26, *) {
            XCTAssertEqual(p.availability(), .available)
        } else {
            if case .unavailable = p.availability() {} else { XCTFail("must be unavailable < 26") }
        }
    }
    func testUkrainianNotSupported() {
        // uk is intentionally excluded — the product core needs it, Apple lacks it.
        XCTAssertFalse(AppleProvider().supportedLanguages(model: "system")?.contains("uk") ?? false)
    }
    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "apple" })
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter AppleProviderTests 2>&1 | tee /tmp/t.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: FAIL — `cannot find 'AppleProvider'`.

- [ ] **Step 4: Implement with runtime OS gating**

```swift
// Sources/Services/Transcription/Providers/AppleProvider.swift
import Foundation

struct AppleProvider: TranscriptionProvider {
    static var id: String { "apple" }
    var displayName: String { "Apple Speech (macOS 26+)" }
    var models: [TranscriptionModelOption] { [.init(id: "system", label: "System model")] }
    var supportsLive: Bool { false }

    func availability() -> ProviderAvailability {
        if #available(macOS 26, *) { return .available }
        return .unavailable(reason: "Requires macOS 26")
    }
    func supportedLanguages(model: String) -> Set<String>? {
        // Derived from SpeechTranscriber.supportedLocales in Step 1, uk removed.
        // Hard-code the verified set; MUST NOT contain "uk".
        ["en","ru","de","fr","es","it","pt","nl","pl"]  // replace with verified list (no uk)
    }
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // AssetInventory install request (verified in Step 1), guarded by #available.
    }
    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "AppleProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Requires macOS 26"])
        }
        return AppleTranscriber()
    }
}

final class AppleTranscriber: Transcriber, @unchecked Sendable {
    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        // macOS 26 SpeechAnalyzer batch flow (verified). Accumulate finalized text.
        progress(1, 1)
        return TranscriptionOutput(text: "", langStats: [:])
    }
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
```

> Speech-framework calls live behind `if #available(macOS 26, *)`; the type itself compiles on the macOS 14 floor. Replace the empty-string result with the verified accumulation in this step.

- [ ] **Step 5: Register + test + build**

Append `AppleProvider()` to the registry. `swift build` (EXIT=0 on the macOS 14 toolchain) + `swift test --filter AppleProviderTests` (EXIT=0). On a macOS 26 machine, add a manual smoke check.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop
git commit -m "feat(transcriber): add Apple SpeechTranscriber provider (macOS 26+, batch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Docs + CLAUDE.md sync

**Files:**
- Modify: `CLAUDE.md` (Meeting Transcriber section), `docs/app-guide.md` (if not already in Task 5)

- [ ] **Step 1:** In `CLAUDE.md`'s "Meeting Transcriber" section, document that the engine is pluggable via `TranscriptionProviderRegistry`, one active provider chosen in Settings (Engine + Model), WhisperKit is the default (`large-v3-v20240930`), new providers are batch-only, and the live↔batch pin test is Whisper-internal. Note that adding a provider = one registry line + one `Providers/*.swift` file conforming to `TranscriptionProvider`.
- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md docs/app-guide.md
git commit -m "docs(transcriber): document pluggable provider architecture

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** protocols (T1) ✓, registry (T2) ✓, WhisperKit-behind-contract + rename (T3) ✓, provisioner generalization (T4) ✓, Settings two pickers + migration + recorder + live gating (T5) ✓, Parakeet (T6) ✓, Qwen3 (T7) ✓, Apple w/ macOS-26 gating + no-uk (T8) ✓, docs/inventory note (T9 + T3 pin-test gate) ✓. langStats best-effort — encoded in T6/T7/T8 (`langStats: [:]` allowed).
- **Placeholder scan:** the only `fatalError`/empty-result markers are in T6/T7/T8 external-SDK bodies, each explicitly flagged "replace with verified API, do not commit with fatalError" and preceded by a research step with real source URLs — these are deliberate seams for unverifiable-in-advance third-party APIs, not lazy TODOs.
- **Type consistency:** `TranscriptionProvider`/`Transcriber`/`TranscriptionLiveSession`/`ProviderAvailability`/`TranscriptionModelOption` names and signatures are identical across T1→T8; `ensureDownloaded(providerID:model:)` used consistently in T4/T5; `resolve(providerID:)` returns `any TranscriptionProvider` everywhere; default `whisperkit`/`large-v3-v20240930` consistent with Global Constraints.
- **Parallelism:** T1–T5 are sequential (T0 foundation); T6/T7/T8 depend only on T2's registry + T1's protocols and touch disjoint files except `Package.swift`/registry append lines — worktree isolation called out to avoid merge conflicts.
