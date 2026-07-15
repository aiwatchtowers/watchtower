# Silence-Snapped Windows + Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Окна транскрипции режутся по паузам вместо жёстких 20 с, и сохранённый транскрипт получает роли `[Я]` / `[Speaker N]` через on-device диаризацию пост-проходом.

**Architecture:** Часть 1 — общий `WindowPlanner` (чистый DSP) даёт идентичные границы batch- и live-путям; снэппинг к самому тихому кадру в зоне ±`boundarySnapSec` вокруг номинальной границы. Часть 2 — `TranscriptionEngine` становится посегментным (таймстемпы), рекордер пишет sidecar RMS-активности микрофона, после Stop FluidAudio диаризует файл, `RoleAssigner` (чистая функция) сопоставляет сегменты кластерам и рендерит текст с ролями в существующую `text`-колонку. Спека: `docs/superpowers/specs/2026-07-15-window-snapping-and-diarization-design.md`.

**Tech Stack:** Swift 5.10 / macOS 14+, WhisperKit 0.18.x, FluidAudio (новая SPM-зависимость, Apache 2.0), XCTest.

> **СТАТУС (2026-07-15, решение владельца):** задачи 1–2 выполнены (коммиты `57185be`, `7998b0d`). Задачи 3–7 **отложены** до лендинга рефактора `2026-07-15-pluggable-transcription-engines-design.md` (тот же протокол/Center/зависимость) и подлежат **перепланированию** против нового `TranscriptionProvider`-шва: сегменты с таймстемпами закладываются в новый контракт сразу, диаризация становится engine-agnostic пост-проходом над provider-выходом. Части плана про sidecar (`Task 4`), `RoleAssigner` (`Task 6`) и FluidAudio-адаптер (`Task 5`, §3.4) переносятся почти как есть; Task 3 и Task 7 переписываются под новый шов.

## Global Constraints

- Манифест: `swift-tools-version: 5.10`, платформа `.macOS(.v14)` — не поднимать без крайней необходимости (контингенция задачи 5).
- `StreamingTranscriberTests.testMatchesBatchOnSameSamples` (и `testMatchesBatchWithOverlap`) нельзя ослаблять/переименовывать — только расширять (CLAUDE.md, guard-tests).
- Провал любого шага диаризации → сохранить транскрипт без ролей; **никогда** `.failed` из-за ролей. Аудиофайл переживает любые сбои.
- Go/схема БД не меняются. Sidecar-файлы именуются `rec_*` (контракт orphan-sweep в `internal/daemon/daemon.go:cleanupOrphanRecordings`).
- Никаких новых TCC-промптов (диаризация = файлы + сеть на скачивание модели, TCC не трогает).
- Проверка команд: реальный exit code (`> /tmp/xx.log 2>&1; echo "exit=$?"`), не через `| tail`.
- Тесты не грузят WhisperKit/CoreML/FluidAudio — только моки за протоколами.
- Все тесты гоняются из `WatchtowerDesktop/`: `swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"`.

---

### Task 1: WindowPlanner — чистая оконная математика со снэппингом

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/WindowPlanner.swift`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift` (поле `boundarySnapSec` + `fromDefaults`)
- Test: `WatchtowerDesktop/Tests/WindowPlannerTests.swift`

**Interfaces:**
- Consumes: `TranscriptionConfig` (существующий).
- Produces: `WindowPlanner(config:)` с `windowSamples/overlapSamples/toleranceSamples`, `isLastWindow(start:total:) -> Bool`, `decidableCount(start:) -> Int`, `nextRange(start:total:isFinal:sample:) -> Range<Int>?`, `nextStart(after:) -> Int`, `planWindows(total:sample:) -> [Range<Int>]`. `TranscriptionConfig.boundarySnapSec: Double = 2.5`.

- [ ] **Step 1: Поле конфига.** В `TranscriptionEngine.swift` в `TranscriptionConfig` после `overlapSec`:

```swift
    /// Snap window boundaries to the quietest point within ±boundarySnapSec
    /// of the nominal end (0 disables snapping — exact legacy boundaries).
    var boundarySnapSec: Double = 2.5
```

и в `fromDefaults` после блока `windowSec`:

```swift
        if defaults.object(forKey: "transcription.boundarySnapSec") != nil {
            let value = defaults.double(forKey: "transcription.boundarySnapSec")
            if value >= 0 { config.boundarySnapSec = value }
        }
```

- [ ] **Step 2: Написать падающие тесты** `WatchtowerDesktop/Tests/WindowPlannerTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class WindowPlannerTests: XCTestCase {

    /// windowSec 0.1 (1600 samples), overlap 0, snap 0.02 (320 samples,
    /// under the windowSamples/4 = 400 cap).
    private func config(snap: Double = 0.02, overlap: Double = 0) -> TranscriptionConfig {
        var c = TranscriptionConfig()
        c.windowSec = 0.1
        c.overlapSec = overlap
        c.boundarySnapSec = snap
        return c
    }

    /// Loud everywhere except a quiet dip of `dipLen` samples at `dipStart`.
    private func samples(count: Int, dipStart: Int, dipLen: Int) -> [Float] {
        var s = [Float](repeating: 0.5, count: count)
        for i in dipStart..<min(dipStart + dipLen, count) { s[i] = 0.0 }
        return s
    }

    func testSnapDisabledGivesNominalBoundaries() {
        let planner = WindowPlanner(config: config(snap: 0))
        let s = [Float](repeating: 0.5, count: 5600)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<1600, 1600..<3200, 3200..<4800, 4800..<5600])
    }

    func testCutSnapsToQuietDip() {
        // Dip covers samples 1700..<2100; zone for window 0 is [1280, 1920].
        // Quietest full 320-frame inside the zone starts at 1700-ish; frames
        // step by 160 from 1280: candidates 1280,1440,1600,... the frame at
        // 1600 covers 1600..<1920 with 220 quiet samples — the quietest.
        let planner = WindowPlanner(config: config())
        let s = samples(count: 6000, dipStart: 1700, dipLen: 400)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges[0], 0..<1760) // 1600 + 320/2
        XCTAssertEqual(ranges[1].lowerBound, 1760) // overlap 0 → next start = cut
    }

    func testAllSilenceCutsAtEarliestFrame() {
        // Equal energy everywhere → earliest frame in the zone wins (strict <).
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.0, count: 6000)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        // Zone [1280, 1920], earliest frame at 1280 → cut 1280+160 = 1440.
        XCTAssertEqual(ranges[0], 0..<1440)
    }

    func testLastWindowIsNeverSnapped() {
        let planner = WindowPlanner(config: config())
        let s = samples(count: 1600, dipStart: 800, dipLen: 100)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<1600]) // exact-length recording = one window
    }

    func testZoneClampedByTotal() {
        // total = 1700 lies inside the zone [1280, 1920] → zone ends at 1700;
        // the window at 0 is non-last (1600 < 1700).
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1700)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges[0].upperBound, 1440) // earliest frame 1280 → 1280+160
        XCTAssertEqual(ranges.last!.upperBound, 1700) // tail window to the end
    }

    func testTinyWindowZoneSmallerThanFrameFallsBackToNominal() {
        // windowSec 0.01 → 160 samples, tolerance cap 160/4 = 40 → zone 80 <
        // one 320-sample frame → nominal cut.
        var c = TranscriptionConfig()
        c.windowSec = 0.01
        c.overlapSec = 0
        c.boundarySnapSec = 2.5
        let planner = WindowPlanner(config: c)
        let s = [Float](repeating: 0.5, count: 400)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<160, 160..<320, 320..<400])
    }

    func testNextRangeNotDecidableUntilZoneBuffered() {
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1900) // decidable needs 1600+320=1920
        XCTAssertNil(planner.nextRange(start: 0, total: 1900, isFinal: false) { s[$0] })
        XCTAssertNotNil(planner.nextRange(start: 0, total: 1900, isFinal: true) { s[$0] })
    }

    func testNextRangeLastWindowOnlyWhenFinal() {
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1000)
        XCTAssertNil(planner.nextRange(start: 0, total: 1000, isFinal: false) { s[$0] })
        XCTAssertEqual(planner.nextRange(start: 0, total: 1000, isFinal: true) { s[$0] }, 0..<1000)
    }

    func testOverlapAppliedToSnappedCut() {
        // overlap 0.05 s = 800 samples: next start = cut − 800.
        let planner = WindowPlanner(config: config(snap: 0.02, overlap: 0.05))
        XCTAssertEqual(planner.nextStart(after: 0..<1440), 640)
    }

    func testEmptyInputPlansNothing() {
        let planner = WindowPlanner(config: config())
        XCTAssertEqual(planner.planWindows(total: 0) { _ in 0 }, [])
    }
}
```

- [ ] **Step 3: Прогнать — убедиться, что падает** (нет `WindowPlanner`): `cd WatchtowerDesktop && swift test --filter WindowPlannerTests > /tmp/t1.log 2>&1; echo "exit=$?"` → exit≠0, в логе "cannot find 'WindowPlanner'".

- [ ] **Step 4: Реализация** `WindowPlanner.swift` (полный файл):

```swift
import Foundation

/// Single source of truth for window boundaries, shared by WindowedTranscriber
/// (batch) and StreamingTranscriber (live) so both cut identical windows on
/// identical samples — the live↔batch invariant pinned by
/// StreamingTranscriberTests.testMatchesBatchOnSameSamples.
///
/// A window's nominal end is `start + windowSamples`. With snapping enabled
/// (toleranceSamples > 0) the actual cut is the centre of the quietest 20 ms
/// frame (10 ms hop, earliest wins ties) within ±tolerance of the nominal end,
/// so boundaries land in speech pauses instead of mid-word. The last window
/// (nominal end reaching the total count) is never snapped: it is truncated to
/// the real end — the legacy rule verbatim.
struct WindowPlanner {
    let windowSamples: Int
    let overlapSamples: Int
    /// Configured snap tolerance capped at a quarter window, so degenerate
    /// configs (tiny test windows) keep making progress.
    let toleranceSamples: Int

    static let frameSamples = 320 // 20 ms @ 16 kHz
    static let hopSamples = 160   // 10 ms @ 16 kHz

    init(config: TranscriptionConfig) {
        let rate = Double(TranscriptionConfig.sampleRate)
        let window = max(1, Int(config.windowSec * rate))
        windowSamples = window
        overlapSamples = Int(config.overlapSec * rate)
        toleranceSamples = min(max(0, Int(config.boundarySnapSec * rate)), window / 4)
    }

    /// A window reaching the end of the samples is the last one: a further
    /// start would lie inside this window's overlap and only duplicate audio.
    func isLastWindow(start: Int, total: Int) -> Bool {
        start + windowSamples >= total
    }

    /// Samples that must exist before the cut for the window at `start` is
    /// decidable without seeing the stream end: the full snap zone (or, with
    /// snapping off, one sample past the nominal end to prove non-last).
    func decidableCount(start: Int) -> Int {
        start + windowSamples + max(toleranceSamples, 1)
    }

    /// The window starting at `start` given `total` samples so far; `isFinal`
    /// means `total` is the stream's true end. Returns nil while the window is
    /// not yet decidable (or `start` is past the end). `sample` is indexed by
    /// absolute sample position.
    func nextRange(start: Int, total: Int, isFinal: Bool, sample: (Int) -> Float) -> Range<Int>? {
        guard start < total else { return nil }
        if isLastWindow(start: start, total: total) {
            return isFinal ? start..<total : nil
        }
        if !isFinal && total < decidableCount(start: start) { return nil }
        return start..<cut(nominalEnd: start + windowSamples, total: total, sample: sample)
    }

    /// Start of the window following `range` (meaningless for a last window).
    func nextStart(after range: Range<Int>) -> Int {
        max(range.lowerBound + 1, range.upperBound - overlapSamples)
    }

    /// All windows of a fully-known recording (the batch path).
    func planWindows(total: Int, sample: (Int) -> Float) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while let range = nextRange(start: start, total: total, isFinal: true, sample: sample) {
            ranges.append(range)
            if isLastWindow(start: range.lowerBound, total: total) { break }
            start = nextStart(after: range)
        }
        return ranges
    }

    private func cut(nominalEnd: Int, total: Int, sample: (Int) -> Float) -> Int {
        guard toleranceSamples > 0 else { return min(nominalEnd, total) }
        let lo = nominalEnd - toleranceSamples
        let hi = min(nominalEnd + toleranceSamples, total)
        var bestStart = -1
        var bestEnergy = Float.greatestFiniteMagnitude
        var frame = lo
        while frame + Self.frameSamples <= hi {
            var energy: Float = 0
            for i in frame..<(frame + Self.frameSamples) {
                let v = sample(i)
                energy += v * v
            }
            if energy < bestEnergy { // strict <: the earliest quietest frame wins
                bestEnergy = energy
                bestStart = frame
            }
            frame += Self.hopSamples
        }
        guard bestStart >= 0 else { return min(nominalEnd, total) } // zone < one frame
        return bestStart + Self.frameSamples / 2
    }
}
```

- [ ] **Step 5: Прогнать тесты планировщика** — тот же фильтр, exit=0. Проверить в тестах арифметику зон по факту (если ассерты границ разошлись с реализацией — пересчитать руками ОЖИДАЕМОЕ, а не подгонять реализацию).

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/WindowPlanner.swift \
        WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift \
        WatchtowerDesktop/Tests/WindowPlannerTests.swift
git commit -m "feat(transcriber): WindowPlanner — silence-snapped window boundaries"
```

---

### Task 2: Планировщик в обоих транскрайберах + расширенный пин-тест

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/WindowedTranscriber.swift`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/StreamingTranscriber.swift`
- Modify: `WatchtowerDesktop/Tests/WindowedTranscriberTests.swift`, `WatchtowerDesktop/Tests/StreamingTranscriberTests.swift`

**Interfaces:**
- Consumes: `WindowPlanner` из Task 1.
- Produces: поведение транскрайберов со снэппингом; существующие сигнатуры не меняются.

- [ ] **Step 1: Выключить снэппинг в конфиг-хелперах существующих тестов** (они ассертят точные размеры окон): в `WindowedTranscriberTests.tinyConfig()` и обоих местах `var config = TranscriptionConfig()` (`testWindowingMath`, `testExactWindowLengthIsSingleWindow`, `testJustOverWindowLengthIsTwoWindows`) добавить `config.boundarySnapSec = 0`; в `StreamingTranscriberTests.forcedConfig()` добавить `c.boundarySnapSec = 0`.

- [ ] **Step 2: Добавить падающий пин-тест снэппинг-эквивалентности** в `StreamingTranscriberTests.swift`:

```swift
    func testMatchesBatchWithSnappingOnSameSamples() async throws {
        // The snapping path must cut IDENTICAL windows live and batch. Loud
        // signal with quiet dips at irregular offsets so cuts land off the
        // nominal boundaries.
        var samples = [Float](repeating: 0.5, count: 8000)
        for dip in [1650..<2050, 3100..<3400, 4700..<5000] {
            for i in dip { samples[i] = 0.0 }
        }
        var cfg = forcedConfig() // windowSec 0.1, overlap 0, snap re-enabled below
        cfg.boundarySnapSec = 0.02

        let batchEngine = MockEngine()
        batchEngine.texts = (0..<8).map { .success("w\($0)") }
        let batchOut = try await WindowedTranscriber(engine: batchEngine, config: cfg)
            .transcribe(samples: samples) { _, _ in }

        let streamEngine = MockEngine()
        streamEngine.texts = (0..<8).map { .success("w\($0)") }
        let streamOut = try await StreamingTranscriber(engine: streamEngine, config: cfg)
            .run(samples: stream(of: samples, pieceSize: 271)) { _ in }

        XCTAssertEqual(streamOut, batchOut)
        XCTAssertEqual(streamEngine.windowSizes, batchEngine.windowSizes)
        XCTAssertNotEqual(batchEngine.windowSizes.first, 1600,
                          "sanity: snapping actually moved the first boundary")
    }
```

- [ ] **Step 3: Прогнать** `swift test --filter StreamingTranscriberTests > /tmp/t2.log 2>&1; echo "exit=$?"` — новый тест падает (границы пока номинальные, `windowSizes.first == 1600`), остальные зелёные.

- [ ] **Step 4: WindowedTranscriber на планировщик.** Заменить в `transcribe` блок вычисления `starts` (строки ~25–39) на:

```swift
        let planner = WindowPlanner(config: config)
        let ranges = planner.planWindows(total: samples.count) { samples[$0] }
        let windowCount = ranges.count
```

и цикл `for (index, windowStart) in starts.enumerated()` на `for (index, range) in ranges.enumerated()` с `let window = Array(samples[range])` (переменные `sampleRate/windowSamples/step` больше не нужны). Комментарий про «last window» переезжает в doc-comment планировщика — из файла убрать.

- [ ] **Step 5: StreamingTranscriber на планировщик.** Заменить вычисление `windowSamples/step` на `let planner = WindowPlanner(config: config)`; внутренний цикл эмита на:

```swift
            while let range = planner.nextRange(
                start: absStart,
                total: consumedBase + buffer.count,
                isFinal: false,
                sample: { buffer[$0 - consumedBase] }
            ) {
                if Task.isCancelled { break }
                let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
                await process(window: window)
                absStart = planner.nextStart(after: range)
                let drop = absStart - consumedBase
                if drop > 0 {
                    buffer.removeFirst(min(drop, buffer.count))
                    consumedBase += drop
                }
            }
```

а хвостовой блок после закрытия стрима (`let totalCount = ...` и ниже) на цикл — со снэппингом в остатке может лежать больше одного окна:

```swift
        // Stream closed: total is now final. The remainder can hold several
        // windows (snapped cuts land short of nominal ends), so keep planning
        // with isFinal until the truncated last window is emitted.
        while !Task.isCancelled,
              let range = planner.nextRange(
                  start: absStart,
                  total: consumedBase + buffer.count,
                  isFinal: true,
                  sample: { buffer[$0 - consumedBase] }
              ) {
            let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
            await process(window: window)
            if planner.isLastWindow(start: range.lowerBound, total: consumedBase + buffer.count) { break }
            absStart = planner.nextStart(after: range)
            let drop = absStart - consumedBase
            if drop > 0 {
                buffer.removeFirst(min(drop, buffer.count))
                consumedBase += drop
            }
        }
```

Обновить doc-comment структуры: условие эмита теперь «буфер покрывает окно + снэппинг-зону» (`planner.decidableCount`), хвост — «оставшиеся окна по финальному total».

- [ ] **Step 6: Полный прогон транскрайбер-тестов** `swift test --filter "WindowedTranscriberTests|StreamingTranscriberTests|WindowPlannerTests" > /tmp/t2b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 7: Commit**

```bash
git add -u WatchtowerDesktop
git commit -m "feat(transcriber): snap window boundaries to silence in batch and live paths"
```

---

### Task 3: Сегменты с таймстемпами через весь STT-путь

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/WhisperKitEngine.swift`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/WindowedTranscriber.swift`, `StreamingTranscriber.swift`
- Modify: `WatchtowerDesktop/Tests/WindowedTranscriberTests.swift`, `StreamingTranscriberTests.swift`, `MeetingRecorderCenterTests.swift` (моки)

**Interfaces:**
- Produces (для задач 6–7):
  - `struct TranscribedSegment: Equatable, Sendable { let text: String; let startSec: Double; let endSec: Double }` (окно-относительные секунды),
  - `TranscriptionEngine.transcribeWindow(_:language:) async throws -> [TranscribedSegment]`,
  - `struct TranscriptSegment: Equatable, Sendable { let text: String; let startSec: Double; let endSec: Double; let language: String }` (абсолютные секунды),
  - `TranscriptionOutput { let text: String; let langStats: [String: Int]; var segments: [TranscriptSegment] = [] }`.

- [ ] **Step 1: Типы и протокол** в `TranscriptionEngine.swift`:

```swift
/// One timestamped segment of a transcribed window (seconds relative to the
/// window start). Empty array from the engine = no speech in the window.
struct TranscribedSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
}

/// Abstraction over the on-device STT engine so tests never load WhisperKit/CoreML.
protocol TranscriptionEngine: Sendable {
    /// Language probabilities for one audio window (16 kHz mono Float32 samples).
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    /// Transcribe one window with the language forced.
    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment]
}

/// One timestamped segment of the full recording (absolute seconds), carrying
/// the language of its parent window.
struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    let language: String
}
```

и `TranscriptionOutput`:

```swift
/// Result of transcribing a full recording.
struct TranscriptionOutput: Equatable {
    let text: String                 // newline-joined non-empty window texts
    let langStats: [String: Int]     // windows per language (speech windows only)
    var segments: [TranscriptSegment] = [] // absolute-timestamped, for diarization
}
```

- [ ] **Step 2: Моки в трёх тест-файлах.** В обоих `MockEngine` (`WindowedTranscriberTests`, `StreamingTranscriberTests`) `transcribeWindow` возвращает один сегмент на всё окно (пустая строка → без изменений: транскрайбер сам отфильтрует):

```swift
    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment] {
        windowSizes.append(samples.count)
        transcribedLanguages.append(language)
        let idx = transcribedLanguages.count - 1
        let text = idx < texts.count ? try texts[idx].get() : ""
        return [TranscribedSegment(text: text, startSec: 0, endSec: Double(samples.count) / Double(TranscriptionConfig.sampleRate))]
    }
```

В `MeetingRecorderCenterTests` найти fake-движок (`grep -n "TranscriptionEngine" WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift`) и обновить той же обёрткой; конструкции `TranscriptionOutput(text:langStats:)` продолжают компилироваться (у `segments` есть дефолт).

- [ ] **Step 3: Прогон — компиляция падает** (протокол изменился, транскрайберы ждут `String`): `swift build > /tmp/t3.log 2>&1; echo "exit=$?"` → ≠0.

- [ ] **Step 4: WindowedTranscriber.** В `transcribe`: `var segments: [TranscriptSegment] = []` рядом с `texts`; тело окна:

```swift
            let rawSegments: [TranscribedSegment]
            do {
                rawSegments = try await engine.transcribeWindow(window, language: language)
            } catch {
                // A failed window is skipped: nothing counted, language does not stick.
                lastEngineError = error
                progress(index + 1, windowCount)
                continue
            }

            let windowStartSec = Double(range.lowerBound) / Double(TranscriptionConfig.sampleRate)
            let cleaned = rawSegments
                .map { TranscribedSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          startSec: $0.startSec, endSec: $0.endSec) }
                .filter { !$0.text.isEmpty }
            if !cleaned.isEmpty {
                texts.append(cleaned.map(\.text).joined(separator: " "))
                segments.append(contentsOf: cleaned.map {
                    TranscriptSegment(text: $0.text,
                                      startSec: windowStartSec + $0.startSec,
                                      endSec: windowStartSec + $0.endSec,
                                      language: language)
                })
                prevLang = language
                langStats[language, default: 0] += 1
            }
            progress(index + 1, windowCount)
```

и возврат `TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats, segments: segments)` (обе точки возврата — пустой вход остаётся `TranscriptionOutput(text: "", langStats: [:])`).

- [ ] **Step 5: StreamingTranscriber.** `process` получает `windowStart: Int` (обе точки вызова передают `range.lowerBound`), та же обработка `rawSegments/cleaned`, аккумулирует `segments`, возврат с `segments:`. `StreamChunk` не меняется — `text` чанка = `cleaned.map(\.text).joined(separator: " ")`.

- [ ] **Step 6: WhisperKitEngine.transcribeWindow:**

```swift
    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment] {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results.flatMap { result in
            result.segments.map {
                TranscribedSegment(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startSec: Double($0.start),
                    endSec: Double($0.end)
                )
            }
        }
    }
```

(Поля `TranscriptionSegment.start/.end/.text` сверить с WhisperKit 0.18: `grep -n "public let start" ~/.../checkouts/WhisperKit/Sources/WhisperKit/Core/Models.swift` из `.build/checkouts` — правится только этот адаптер.)

- [ ] **Step 7: Новый тест абсолютных таймстемпов** в `WindowedTranscriberTests.swift`:

```swift
    func testSegmentsCarryAbsoluteTimestamps() async throws {
        // tinyConfig: 0.01 s windows (160 samples), snap off. Mock returns one
        // segment per window spanning [0, windowDur) → absolute offsets must
        // shift by k·0.01 s.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b")]

        let output = try await run(engine, config, windows: 2)

        XCTAssertEqual(output.segments.map(\.text), ["a", "b"])
        XCTAssertEqual(output.segments.map(\.language), ["en", "en"])
        XCTAssertEqual(output.segments[0].startSec, 0.0, accuracy: 1e-9)
        XCTAssertEqual(output.segments[1].startSec, 0.01, accuracy: 1e-9)
        XCTAssertEqual(output.segments[1].endSec, 0.02, accuracy: 1e-9)
    }
```

- [ ] **Step 8: Полный прогон** `swift test > /tmp/t3b.log 2>&1; echo "exit=$?"` → exit=0 (пин-тесты эквивалентности теперь сравнивают и `segments` — через `Equatable`).

- [ ] **Step 9: Commit** `git add -u WatchtowerDesktop && git commit -m "feat(transcriber): timestamped segments through the STT path"`

---

### Task 4: Sidecar активности микрофона (`rec_X.activity`)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/MicActivity.swift`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/SystemAudioRecorder.swift`
- Test: `WatchtowerDesktop/Tests/MicActivityTests.swift`

**Interfaces:**
- Produces (для задач 6–7):
  - `struct MicActivity { static let binDuration = 0.1; struct Bin: Equatable { let mic: Float; let sys: Float }; let bins: [Bin]; static func url(for audioURL: URL) -> URL; static func load(for audioURL: URL) -> MicActivity?; func bin(at timeSec: Double) -> Bin? }`
  - `struct MicActivityAccumulator { init(sampleRate: Double); mutating func add(mic: Float, sys: Float); mutating func flushLines() -> [String] }`

- [ ] **Step 1: Падающие тесты** `WatchtowerDesktop/Tests/MicActivityTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class MicActivityTests: XCTestCase {

    func testAccumulatorEmitsRMSPerBin() {
        // sampleRate 40 → 4 samples per 0.1 s bin.
        var acc = MicActivityAccumulator(sampleRate: 40)
        for _ in 0..<4 { acc.add(mic: 0.5, sys: 0.0) }
        for _ in 0..<4 { acc.add(mic: 0.0, sys: 0.25) }
        let lines = acc.flushLines()
        XCTAssertEqual(lines, ["0.500000 0.000000", "0.000000 0.250000"])
        XCTAssertEqual(acc.flushLines(), [], "flushed bins are not re-emitted")
    }

    func testAccumulatorKeepsPartialBinBuffered() {
        var acc = MicActivityAccumulator(sampleRate: 40)
        for _ in 0..<3 { acc.add(mic: 1.0, sys: 1.0) } // 3 of 4 samples
        XCTAssertEqual(acc.flushLines(), [])
    }

    func testLoadParsesSidecarAndIndexesByTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec_test.caf")
        try "0.100000 0.000000\n0.000000 0.300000\ngarbage line\n"
            .write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)

        let activity = try XCTUnwrap(MicActivity.load(for: audio))
        XCTAssertEqual(activity.bins.count, 2) // garbage line skipped
        XCTAssertEqual(activity.bin(at: 0.05), MicActivity.Bin(mic: 0.1, sys: 0.0))
        XCTAssertEqual(activity.bin(at: 0.15), MicActivity.Bin(mic: 0.0, sys: 0.3))
        XCTAssertNil(activity.bin(at: 0.25), "past the recorded end")
        XCTAssertNil(activity.bin(at: -1))
    }

    func testLoadMissingOrEmptySidecarReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec_test.caf")
        XCTAssertNil(MicActivity.load(for: audio)) // missing
        try "".write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)
        XCTAssertNil(MicActivity.load(for: audio)) // empty → degenerate, still nil
    }

    func testSidecarURLKeepsRecPrefix() {
        // The Go daemon's orphan sweep only manages rec_* files.
        let url = MicActivity.url(for: URL(fileURLWithPath: "/tmp/rec_20260715_120000.caf"))
        XCTAssertEqual(url.lastPathComponent, "rec_20260715_120000.activity")
    }
}
```

- [ ] **Step 2: Прогон — падает** (`--filter MicActivityTests`, нет типов).

- [ ] **Step 3: Реализация** `MicActivity.swift` (полный файл):

```swift
import Foundation

/// Per-100 ms mic/system RMS timeline captured alongside a recording as a
/// `rec_X.activity` sidecar. The mic and system signals exist separately only
/// inside the recorder's IO callback — this file preserves that "is the owner
/// speaking" signal so the diarization post-pass can label one speaker
/// cluster as «Я». Losing the sidecar only loses that label, never a failure.
struct MicActivity: Equatable {
    static let binDuration: Double = 0.1

    struct Bin: Equatable {
        let mic: Float
        let sys: Float
    }

    let bins: [Bin]

    /// rec_X.caf → rec_X.activity: the rec_ prefix keeps the sidecar inside
    /// the Go daemon's orphan-sweep contract (cleanupOrphanRecordings), so it
    /// is deleted alongside the audio after the retention window.
    static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("activity")
    }

    /// nil when the sidecar is missing, unreadable, or holds no valid bins.
    static func load(for audioURL: URL) -> MicActivity? {
        guard let text = try? String(contentsOf: url(for: audioURL), encoding: .utf8) else { return nil }
        let bins: [Bin] = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let mic = Float(parts[0]), let sys = Float(parts[1]) else { return nil }
            return Bin(mic: mic, sys: sys)
        }
        guard !bins.isEmpty else { return nil }
        return MicActivity(bins: bins)
    }

    /// RMS pair at `timeSec`; nil outside the recorded timeline.
    func bin(at timeSec: Double) -> Bin? {
        guard timeSec >= 0 else { return nil }
        let index = Int(timeSec / Self.binDuration)
        return index < bins.count ? bins[index] : nil
    }
}

/// Accumulates per-frame mic/system samples into 100 ms RMS bins and renders
/// completed bins as sidecar lines. Pure (no I/O) so it is unit-testable; the
/// recorder drains `flushLines()` on its write queue. The trailing partial
/// bin is simply dropped at stop — a <100 ms tail carries no role signal.
struct MicActivityAccumulator {
    private let samplesPerBin: Int
    private var micSquares: Double = 0
    private var sysSquares: Double = 0
    private var count = 0
    private var pendingLines: [String] = []

    init(sampleRate: Double) {
        samplesPerBin = max(1, Int(sampleRate * MicActivity.binDuration))
    }

    mutating func add(mic: Float, sys: Float) {
        micSquares += Double(mic * mic)
        sysSquares += Double(sys * sys)
        count += 1
        if count == samplesPerBin {
            let micRMS = (micSquares / Double(count)).squareRoot()
            let sysRMS = (sysSquares / Double(count)).squareRoot()
            pendingLines.append(String(format: "%.6f %.6f", micRMS, sysRMS))
            micSquares = 0
            sysSquares = 0
            count = 0
        }
    }

    mutating func flushLines() -> [String] {
        defer { pendingLines = [] }
        return pendingLines
    }
}
```

- [ ] **Step 4: Прогон тестов** (`--filter MicActivityTests`) → exit=0.

- [ ] **Step 5: Вплести в рекордер** (`SystemAudioRecorder.swift`, `TapRecorderImpl`):
  - Свойства: `private var activityAccumulator: MicActivityAccumulator?`, `private var activityHandle: FileHandle?`.
  - В `start(to:)` после `openOutputFile`/`fileURL = url` (best-effort — провал не роняет запись):

```swift
        // Best-effort mic/system activity sidecar (rec_X.activity): losing it
        // only loses the «Я» diarization label, so failures are ignored and
        // never latched into firstWriteError.
        let activityURL = MicActivity.url(for: url)
        FileManager.default.createFile(atPath: activityURL.path, contents: nil)
        activityHandle = try? FileHandle(forWritingTo: activityURL)
        activityAccumulator = MicActivityAccumulator(sampleRate: Self.nominalSampleRate(of: aggregateID))
```

  - В `handleInput` в цикле по кадрам после вычисления `mic`/`system` (перед `out[frame] = ...`): `activityAccumulator?.add(mic: mic, sys: system)`; после цикла:

```swift
        if !(activityAccumulator?.isEmptyPending ?? true) {} // (не нужно — см. ниже)
        if let lines = activityAccumulator?.flushLines(), !lines.isEmpty {
            activityHandle.map { try? $0.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8)) }
        }
```

  (без вспомогательного `isEmptyPending` — просто `flushLines()` и запись при непустом результате; `handleInput` уже выполняется на `writeQueue`, гонок нет).
  - В `stop()` внутри `writeQueue.sync`-блока: `try? activityHandle?.close(); activityHandle = nil; activityAccumulator = nil`. В `deinit` ничего не добавлять (файл закроется деаллокацией `FileHandle`).

- [ ] **Step 6: Сборка + полный тест-прогон** `swift build > /tmp/t4.log 2>&1; echo "exit=$?"` и `swift test > /tmp/t4b.log 2>&1; echo "exit=$?"` → оба exit=0 (рекордер под `swift test` не гоняется — только компиляция).

- [ ] **Step 7: Commit** `git add -A WatchtowerDesktop && git commit -m "feat(transcriber): mic/system activity sidecar for owner-speaker detection"`

---

### Task 5: FluidAudio — зависимость, SpeakerDiarizing, адаптер, prefetch

**Files:**
- Modify: `WatchtowerDesktop/Package.swift`
- Create: `WatchtowerDesktop/Sources/Services/Transcription/SpeakerDiarizer.swift`
- Create: `WatchtowerDesktop/Sources/Services/Transcription/FluidAudioDiarizer.swift`
- Modify: `WatchtowerDesktop/Sources/Services/TranscriptionModelProvisioner.swift` + место конструирования в AppState

**Interfaces:**
- Produces (для задач 6–7):
  - `struct SpeakerSegment: Equatable, Sendable { let speakerID: String; let startSec: Double; let endSec: Double }`
  - `protocol SpeakerDiarizing: Sendable { func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] }`
  - `FluidAudioDiarizer.load() async throws -> FluidAudioDiarizer`, `FluidAudioDiarizer.prefetchModels() async throws`
  - `TranscriptionModelProvisioner.init(downloadFn:prefetchExtras:)` — новый параметр `prefetchExtras: @Sendable () async -> Void = {}`.

- [ ] **Step 1: РИСК-ГЕЙТ — зависимость и сборка.** В `Package.swift` dependencies добавить:

```swift
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
```

и в target dependencies: `.product(name: "FluidAudio", package: "FluidAudio"),`. Прогнать `swift build > /tmp/t5.log 2>&1; echo "exit=$?"`. FluidAudio заявляет Swift 6 — SPM собирает зависимости их собственным language mode, при Xcode 16+ должно пройти. Если сборка падает из-за tools-version: поднять первую строку манифеста до `// swift-tools-version: 6.0` и добавить `swiftSettings: [.swiftLanguageMode(.v5)]` в оба таргета, пересобрать; если продукт называется иначе — взять имя из их `Package.swift` в `.build/checkouts/FluidAudio`. Если минимальная платформа FluidAudio > macOS 14 — остановиться и доложить владельцу (блокер спеки).

- [ ] **Step 2: Протокол** `SpeakerDiarizer.swift` (полный файл):

```swift
import Foundation

/// One diarized interval. `speakerID` is an opaque cluster label, stable only
/// within a single diarization run.
struct SpeakerSegment: Equatable, Sendable {
    let speakerID: String
    let startSec: Double
    let endSec: Double
}

/// Abstraction over the speaker-diarization engine so tests never load CoreML.
protocol SpeakerDiarizing: Sendable {
    /// Speaker timeline for a full recording (16 kHz mono Float32 samples).
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]
}
```

- [ ] **Step 3: Адаптер** `FluidAudioDiarizer.swift` — код ниже писался по README FluidAudio; **сверить имена** (`DiarizerManager`, `DiarizerModels.downloadIfNeeded`, `performCompleteDiarization`, поля `speakerId/startTimeSeconds/endTimeSeconds`) с исходниками в `.build/checkouts/FluidAudio/Sources` и поправить только этот файл:

```swift
import FluidAudio
import Foundation

/// Adapts FluidAudio's offline (pyannote + VBx) diarization pipeline to
/// `SpeakerDiarizing`. Everything FluidAudio-specific stays inside this file,
/// the same way WhisperKitEngine contains WhisperKit churn.
final class FluidAudioDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let manager: DiarizerManager

    private init(manager: DiarizerManager) {
        self.manager = manager
    }

    /// Downloads the diarizer models on first use (HuggingFace, then cached
    /// on disk) and initializes the pipeline.
    static func load() async throws -> FluidAudioDiarizer {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return FluidAudioDiarizer(manager: manager)
    }

    /// Model prefetch without keeping an instance (Settings/Calendar warmup).
    static func prefetchModels() async throws {
        _ = try await DiarizerModels.downloadIfNeeded()
    }

    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        let manager = self.manager
        // performCompleteDiarization is synchronous and heavy — run it off
        // the caller's (main) actor.
        return try await Task.detached(priority: .userInitiated) {
            let result = try manager.performCompleteDiarization(
                samples, sampleRate: TranscriptionConfig.sampleRate
            )
            return result.segments.map {
                SpeakerSegment(
                    speakerID: $0.speakerId,
                    startSec: Double($0.startTimeSeconds),
                    endSec: Double($0.endTimeSeconds)
                )
            }
        }.value
    }
}
```

- [ ] **Step 4: Prefetch в провижионере.** В `TranscriptionModelProvisioner`: новое поле и параметр init:

```swift
    private let prefetchExtras: @Sendable () async -> Void

    init(
        downloadFn: @escaping (String, @escaping @Sendable (Double) -> Void) async throws -> Void = { modelName, progress in
            _ = try await WhisperKitEngine.ensureModelFilesDownloaded(modelName: modelName, downloadProgress: progress)
        },
        prefetchExtras: @escaping @Sendable () async -> Void = {}
    ) {
        self.downloadFn = downloadFn
        self.prefetchExtras = prefetchExtras
    }
```

В `ensureDownloaded` внутри `Task.detached` после успешного `downloadFn` (до `continuation.finish()`): `await prefetchExtras()` — доп. прогрев не двигает прогресс Whisper-модели и не влияет на success/failure. Где конструируется провижионер (`grep -rn "TranscriptionModelProvisioner(" WatchtowerDesktop/Sources`), передать боевой клозур:

```swift
            prefetchExtras: {
                // Diarizer models are prefetched only when roles are enabled;
                // failure is fine — the post-pass retries and degrades to a
                // role-less transcript.
                let defaults = UserDefaults.standard
                let enabled = defaults.object(forKey: "transcription.diarization") == nil
                    || defaults.bool(forKey: "transcription.diarization")
                if enabled { try? await FluidAudioDiarizer.prefetchModels() }
            }
```

- [ ] **Step 5: Сборка + существующие тесты провижионера** `swift build > /tmp/t5b.log 2>&1; echo "exit=$?"`; `swift test --filter TranscriptionModelProvisionerTests > /tmp/t5c.log 2>&1; echo "exit=$?"` → оба 0 (дефолт `prefetchExtras = {}` не меняет поведение тестов).

- [ ] **Step 6: Commit** `git add -A WatchtowerDesktop && git commit -m "feat(transcriber): FluidAudio dependency and SpeakerDiarizing seam"`

---

### Task 6: RoleAssigner — назначение и рендер ролей

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/RoleAssigner.swift`
- Test: `WatchtowerDesktop/Tests/RoleAssignerTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` (Task 3), `SpeakerSegment` (Task 5), `MicActivity` (Task 4).
- Produces: `RoleAssigner.render(segments:speakers:activity:) -> String?` — nil, когда роли невыводимы (пустые входы); Center тогда сохраняет `output.text`.

- [ ] **Step 1: Падающие тесты** `RoleAssignerTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class RoleAssignerTests: XCTestCase {

    private func seg(_ text: String, _ start: Double, _ end: Double, lang: String = "ru") -> TranscriptSegment {
        TranscriptSegment(text: text, startSec: start, endSec: end, language: lang)
    }

    private func spk(_ id: String, _ start: Double, _ end: Double) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, startSec: start, endSec: end)
    }

    /// activity where the owner's mic dominates during [selfFrom, selfTo).
    private func activity(duration: Double, selfFrom: Double, selfTo: Double) -> MicActivity {
        let bins = (0..<Int(duration / MicActivity.binDuration)).map { i -> MicActivity.Bin in
            let t = Double(i) * MicActivity.binDuration
            return t >= selfFrom && t < selfTo
                ? MicActivity.Bin(mic: 0.5, sys: 0.01)
                : MicActivity.Bin(mic: 0.01, sys: 0.5)
        }
        return MicActivity(bins: bins)
    }

    func testSpeakersLabelledByFirstAppearanceAndMerged() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("как дела", 2, 4), seg("нормально", 5, 7)],
            speakers: [spk("A", 0, 4.5), spk("B", 4.5, 8)],
            activity: nil
        )
        XCTAssertEqual(text, "[Speaker 1] привет как дела\n[Speaker 2] нормально")
    }

    func testMicDominatedClusterBecomesSelf() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5)
        )
        XCTAssertEqual(text, "[Я] привет\n[Speaker 1] ответ")
    }

    func testSegmentWithoutOverlapInheritsPreviousSpeaker() {
        let text = RoleAssigner.render(
            segments: [seg("раз", 0, 2), seg("два", 10, 11)], // second overlaps nothing
            speakers: [spk("A", 0, 3)],
            activity: nil
        )
        XCTAssertEqual(text, "[Speaker 1] раз два")
    }

    func testEmptyInputsGiveNil() {
        XCTAssertNil(RoleAssigner.render(segments: [], speakers: [spk("A", 0, 1)], activity: nil))
        XCTAssertNil(RoleAssigner.render(segments: [seg("а", 0, 1)], speakers: [], activity: nil))
    }

    func testWeakMicDominanceDoesNotLabelSelf() {
        // Owner share below the 0.6 threshold → nobody is «Я».
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 4)],
            speakers: [spk("A", 0, 4)],
            activity: activity(duration: 4, selfFrom: 0, selfTo: 1) // 25% < 60%
        )
        XCTAssertEqual(text, "[Speaker 1] привет")
    }

    func testSingleSpeakerWholeCall() {
        let text = RoleAssigner.render(
            segments: [seg("монолог", 0, 10), seg("продолжение", 10, 20)],
            speakers: [spk("A", 0, 20)],
            activity: activity(duration: 20, selfFrom: 0, selfTo: 20)
        )
        XCTAssertEqual(text, "[Я] монолог продолжение")
    }
}
```

- [ ] **Step 2: Прогон — падает** (`--filter RoleAssignerTests`).

- [ ] **Step 3: Реализация** `RoleAssigner.swift` (полный файл):

```swift
import Foundation

/// Pure mapping of a diarized speaker timeline onto timestamped transcript
/// segments, plus rendering of the final role-tagged text. No I/O.
enum RoleAssigner {
    static let selfLabel = "Я"
    /// Mic RMS must exceed system RMS by this factor for a bin to read as
    /// "the owner is speaking" (the mic channel leaks meeting audio quietly).
    static let micDominanceFactor: Float = 2.0
    /// Minimum share of a cluster's speech bins with mic dominance for the
    /// cluster to be labelled as the owner.
    static let selfShareThreshold = 0.6

    /// nil when roles cannot be derived (no segments / no speakers) — the
    /// caller then keeps the plain transcript text.
    static func render(
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        activity: MicActivity?
    ) -> String? {
        guard !segments.isEmpty, !speakers.isEmpty else { return nil }

        // Cluster order by first appearance drives Speaker 1..N numbering.
        var clusterOrder: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) where !clusterOrder.contains(s.speakerID) {
            clusterOrder.append(s.speakerID)
        }

        // 1. Each transcript segment → cluster with the largest temporal
        //    overlap; no overlap → the previous segment's cluster.
        var assigned: [(segment: TranscriptSegment, cluster: String)] = []
        var previous = clusterOrder[0]
        for segment in segments {
            var best: (id: String, overlap: Double)?
            for s in speakers {
                let overlap = min(segment.endSec, s.endSec) - max(segment.startSec, s.startSec)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (s.speakerID, overlap)
                }
            }
            let cluster = best?.id ?? previous
            assigned.append((segment, cluster))
            previous = cluster
        }

        // 2. Labels: the mic-dominated cluster is «Я», the rest are numbered.
        let selfCluster = detectSelfCluster(speakers: speakers, activity: activity)
        var labels: [String: String] = [:]
        var counter = 0
        for id in clusterOrder {
            if id == selfCluster {
                labels[id] = selfLabel
            } else {
                counter += 1
                labels[id] = "Speaker \(counter)"
            }
        }

        // 3. Merge consecutive same-cluster segments into one paragraph.
        var lines: [String] = []
        var currentCluster: String?
        var currentTexts: [String] = []
        func flush() {
            guard let cluster = currentCluster, !currentTexts.isEmpty else { return }
            lines.append("[\(labels[cluster] ?? cluster)] " + currentTexts.joined(separator: " "))
        }
        for (segment, cluster) in assigned {
            if cluster != currentCluster {
                flush()
                currentCluster = cluster
                currentTexts = []
            }
            currentTexts.append(segment.text)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// The cluster whose speech time is dominated by the mic channel — the
    /// machine's owner. nil without an activity sidecar or when no cluster
    /// clears the threshold (then every speaker stays a numbered stranger).
    private static func detectSelfCluster(speakers: [SpeakerSegment], activity: MicActivity?) -> String? {
        guard let activity else { return nil }
        var stats: [String: (dominated: Int, total: Int)] = [:]
        for s in speakers {
            var t = s.startSec
            while t < s.endSec {
                if let bin = activity.bin(at: t) {
                    var entry = stats[s.speakerID] ?? (0, 0)
                    entry.total += 1
                    if bin.mic > bin.sys * micDominanceFactor {
                        entry.dominated += 1
                    }
                    stats[s.speakerID] = entry
                }
                t += MicActivity.binDuration
            }
        }
        let best = stats
            .compactMap { id, entry -> (id: String, share: Double)? in
                entry.total > 0 ? (id, Double(entry.dominated) / Double(entry.total)) : nil
            }
            .max { $0.share < $1.share }
        guard let best, best.share > selfShareThreshold else { return nil }
        return best.id
    }
}
```

- [ ] **Step 4: Прогон** (`--filter RoleAssignerTests`) → exit=0. Примечание: при равных share `max` недетерминирован по порядку словаря — если тест на это наткнётся, добить tie-break по `clusterOrder` (стабильность), но НЕ менять ассерты.

- [ ] **Step 5: Commit** `git add -A WatchtowerDesktop && git commit -m "feat(transcriber): RoleAssigner — speaker labels over timestamped segments"`

---

### Task 7: Оркестрация в MeetingRecorderCenter + Settings + индикатор

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`
- Test: `WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift`

**Interfaces:**
- Consumes: `RoleAssigner.render` (Task 6), `SpeakerDiarizing`/`FluidAudioDiarizer.load` (Task 5), `MicActivity.load` (Task 4), `TranscriptionOutput.segments` (Task 3).
- Produces: `Phase.diarizing`; init-параметр `diarizerFactory: @escaping () async throws -> SpeakerDiarizing = { try await FluidAudioDiarizer.load() }`; ключ `transcription.diarization` (Bool, default true).

- [ ] **Step 1: Падающие тесты.** Открыть `MeetingRecorderCenterTests.swift`, найти существующие фейки (recorder/engine/runner) и хелпер создания Center; добавить фейк-диаризатор и три теста (адаптировать создание Center под локальные хелперы файла):

```swift
private struct FakeDiarizer: SpeakerDiarizing {
    var segments: [SpeakerSegment] = []
    var error: Error?
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        if let error { throw error }
        return segments
    }
}
```

```swift
    func testDiarizationRendersRolesIntoSavedText() async { /*
        Center с fake engine, дающим output c segments [("привет",0,2),("ответ",3,5)],
        fake diarizer → [spk("A",0,2.5), spk("B",2.5,5)], БЕЗ activity-файла.
        После stopAndProcess/retryTranscription сохранённый текст (через fake runner,
        перехватывающий TranscriptSaveService-вызов или persisted .txt сайдкар)
        начинается с "[Speaker 1] привет" и содержит "[Speaker 2] ответ". */ }

    func testDiarizerFailureSavesPlainTranscript() async { /*
        diarizer.error = MockError() → сохранённый текст РАВЕН output.text,
        phase дошла до idle (не .failed). */ }

    func testDiarizationDisabledSkipsDiarizer() async { /*
        defaults.set(false, forKey: "transcription.diarization") в изолированной
        suite → diarizerFactory не вызывается (счётчик в фабрике), текст plain. */ }
```

Полные тела написать по образцу соседних тестов файла (там уже есть изолированный `UserDefaults(suiteName:)` и fake-runner — переиспользовать их подход; сохранённый текст доступен через существующий в тестах перехват save).

- [ ] **Step 2: Прогон — падает/не компилируется** (`--filter MeetingRecorderCenterTests`).

- [ ] **Step 3: Center.** Изменения:
  - `Phase`: добавить `case diarizing`; в `isBusy` — `case .recording, .transcribing, .diarizing, .summarizing: return true`.
  - init: параметр `diarizerFactory: @escaping () async throws -> SpeakerDiarizing = { try await FluidAudioDiarizer.load() }`, сохранить в `private let diarizerFactory`.
  - Свойство-вычисление:

```swift
    /// Roles are on unless the Settings toggle explicitly turned them off.
    private var diarizationEnabled: Bool {
        defaults.object(forKey: "transcription.diarization") == nil
            || defaults.bool(forKey: "transcription.diarization")
    }
```

  - Новый метод:

```swift
    /// Diarization post-pass: renders role-tagged text from the finished
    /// transcription. Every failure returns the plain text — roles are a
    /// progressive enhancement and must never fail the pipeline (spec §3.6).
    /// `samples` avoids a re-decode when the batch path already has them.
    private func renderRoles(output: TranscriptionOutput, audioURL: URL, samples: [Float]?) async -> String {
        guard diarizationEnabled, !output.segments.isEmpty else { return output.text }
        phase = .diarizing
        do {
            let pcm = try samples ?? decode(audioURL)
            let diarizer = try await diarizerFactory()
            let speakers = try await diarizer.diarize(pcm)
            let activity = MicActivity.load(for: audioURL)
            return RoleAssigner.render(segments: output.segments, speakers: speakers, activity: activity)
                ?? output.text
        } catch {
            return output.text
        }
    }
```

  - `stopAndProcess` live-ветка: между получением `liveOutput` и persist/save:

```swift
                let text = await renderRoles(output: liveOutput, audioURL: result.audioURL, samples: nil)
                Self.persistTranscript(text: text, durationSec: durationSec,
                                       langStats: liveOutput.langStats, audioURL: result.audioURL)
                await saveTranscript(text: text, durationSec: durationSec,
                                     langStats: liveOutput.langStats, audioURL: result.audioURL)
```

  - `transcribeAndSave`: `let text = await renderRoles(output: output, audioURL: audioURL, samples: samples)`, дальше `persistTranscript(text:...)` + `saveTranscript(text: text, ...)`.
  - `persistTranscript` меняет сигнатуру на `(text: String, durationSec: Int, langStats: [String: Int], audioURL: URL)` (пишет `text` вместо `output.text`); `loadPersistedTranscript`/`retryTranscription` не меняются — персист уже с ролями, retry сейва не повторяет диаризацию.

- [ ] **Step 4: RecordingIndicatorView** — в `recorderContent` после `.transcribing`:

```swift
        case .diarizing:
            capsule {
                ProgressView().controlSize(.small)
                Text("Identifying speakers…").font(.callout)
            }
```

- [ ] **Step 5: SettingsView** — `@AppStorage("transcription.diarization") private var transcriptionDiarization = true` рядом с остальными transcription-ключами; в `transcriptionSection` после `TextField("Languages", ...)`:

```swift
            Toggle("Speaker roles", isOn: $transcriptionDiarization)
                .help("Label transcript lines with who was speaking ([Я] / [Speaker N]) using on-device diarization")
```

- [ ] **Step 6: Полный прогон** `swift test > /tmp/t7.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 7: Commit** `git add -A WatchtowerDesktop && git commit -m "feat(transcriber): diarization post-pass renders speaker roles into saved transcripts"`

---

### Task 8: Документация + финальная верификация

**Files:**
- Modify: `docs/app-guide.md` (секция транскрайбера), `CLAUDE.md` (раздел Meeting Transcriber)
- Modify: `docs/superpowers/plans/2026-07-15-window-snapping-and-diarization.md` (галочки)

- [ ] **Step 1: `CLAUDE.md`** — в раздел «Meeting Transcriber (v74+)» добавить два предложения: (1) окна режутся `WindowPlanner`-ом по тишине (`boundarySnapSec`, общий для live/batch — инвариант эквивалентности включает границы); (2) после Stop — диаризация пост-проходом (FluidAudio за `SpeakerDiarizing`, sidecar `rec_X.activity` для метки `[Я]`, любой сбой → сохранение без ролей; Go не участвует, роли — префиксы строк в той же `text`-колонке).

- [ ] **Step 2: `docs/app-guide.md`** — обновить описание транскрайбера: транскрипт с ролями `[Я]`/`[Speaker N]`, тумблер Speaker roles в Settings → Transcription, капсула "Identifying speakers…".

- [ ] **Step 3: Полная верификация:** `cd WatchtowerDesktop && swift build > /tmp/final-build.log 2>&1; echo "exit=$?"` и `swift test > /tmp/final-test.log 2>&1; echo "exit=$?"`; Go не менялся — `go build ./... > /tmp/go.log 2>&1; echo "exit=$?"` для порядка.

- [ ] **Step 4: Commit** `git add -u && git commit -m "docs: silence-snapped windows and speaker roles"`

- [ ] **Step 5: local-review** — прогнать скилл local-review по накопленному диффу ветки (per-item панель), исправить принятые находки.

---

## Self-Review (выполнен при написании)

- Покрытие спеки: §2 → Tasks 1–2; §3.2 → Task 3; §3.3 → Task 4; §3.4 + §3.7-prefetch → Task 5; §3.5 → Task 6; §3.6 + §3.7-toggle → Task 7; §4 тесты распределены по задачам; докам — Task 8. Пробелов нет.
- Типы сквозные: `TranscribedSegment`/`TranscriptSegment`/`SpeakerSegment`/`MicActivity`/`RoleAssigner.render(segments:speakers:activity:)`/`renderRoles(output:audioURL:samples:)` — имена совпадают между задачами.
- Известные точки неопределённости внешних API помечены инструкциями сверки с `.build/checkouts` (WhisperKit `TranscriptionSegment`, FluidAudio `DiarizerManager`) — правится только соответствующий адаптер, seam стабилен.
