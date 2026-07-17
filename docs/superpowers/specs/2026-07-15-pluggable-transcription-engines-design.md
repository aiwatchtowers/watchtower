# Pluggable Transcription Engines — Design

**Date:** 2026-07-15
**Status:** Approved (brainstorming)
**Component:** WatchtowerDesktop — Meeting Transcriber
**Related:** `2026-07-13-meeting-transcriber-design.md`, `2026-07-14-live-transcription-design.md`, `2026-07-15-apple-speechanalyzer-engine-design.md`

## Резюме

Сделать подключение нового движка транскрипции **плагинным**: единый высокоуровневый контракт `TranscriptionProvider` + реестр, за которым каждый движок реализуется независимо. Цель — раздать реализацию нескольких провайдеров параллельно (по одной независимой задаче на движок), при этом в рантайме приложения активен **ровно один** выбранный провайдер (как сейчас выбирается модель).

Текущий `TranscriptionEngine` (методы `detectLanguage` + `transcribeWindow(language:)`) заточен под Whisper-семантику (per-window детекция языка + принудительный язык по окну). Parakeet / Qwen3-ASR / Apple SpeechTranscriber так не работают — они мультиязычны сразу и сами делают long-form / VAD / стриминг. Поэтому граница плагина поднимается на уровень **«вот аудио → вот текст+языки»**, а Whisper-специфика инкапсулируется внутри Whisper-плагина.

### Ключевые решения (из брейншторминга)
1. **Runtime:** один активный провайдер, выбор в Settings (Provider + Model). Не режим сравнения и не fallback-цепочка.
2. **Первая волна:** WhisperKit (рефактор в первый плагин) + Parakeet v3 (FluidAudio) + Qwen3-ASR 0.6B + Apple SpeechTranscriber.
3. **Граница:** high-level `TranscriptionProvider` (batch + опционально live), НЕ текущий window-level seam.
4. **Live:** batch-first для новых провайдеров (`supportsLive=false`); live остаётся только у WhisperKit. Инвариант эквивалентности live↔batch — whisper-internal.
5. `TranscriptionEngine` → переименовать в `WhisperWindowEngine` (приватный контракт Whisper-плагина).
6. `TranscriptionOutput.langStats` — best-effort (не-Whisper-движки заполняют как умеют; recap на это не завязан).

## Мотивация (почему вообще)

На FLEURS Whisper large-v3 даёт по украинскому ~12.5% WER против ~5.1% у Parakeet v3 — а украинский в ядре продукта (смешанные ru/uk/en звонки). Нужен способ подключать и сравнивать альтернативные движки без переписывания оркестрации записи каждый раз. Плагинность — предусловие для этого.

## Архитектура

### A. Протоколы

```swift
/// Лёгкий дескриптор + фабрика. Регистрируется в реестре; модель НЕ грузит.
protocol TranscriptionProvider: Sendable {
    static var id: String { get }                        // "whisperkit" | "parakeet" | "qwen3" | "apple"
    var displayName: String { get }
    var models: [TranscriptionModelOption] { get }        // (id, label) для второго пикера
    var supportsLive: Bool { get }
    func availability() -> ProviderAvailability           // .available | .unavailable(reason)
    func supportedLanguages(model: String) -> Set<String>?  // nil = «не ограничено»
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber
}

/// Загруженный движок (тяжёлый; держит модель). Живёт на время записи/декода.
protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float],
                    config: TranscriptionConfig,
                    progress: @escaping @Sendable (_ window: Int, _ total: Int) -> Void)
        async throws -> TranscriptionOutput
    /// nil, если провайдер не поддерживает live (первая волна: только WhisperKit).
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession?
}

/// Живая сессия: принимает поток 16 kHz mono Float32, эмитит финализированные чанки.
/// Извлекается из текущего StreamingTranscriber-контракта.
protocol TranscriptionLiveSession: Sendable {
    func append(_ samples: [Float]) async
    func finish() async throws -> TranscriptionOutput
    var chunks: AsyncStream<String> { get }
}

enum ProviderAvailability: Equatable {
    case available
    case unavailable(reason: String)   // напр. "Требуется macOS 26" / "Нет украинского"
}

struct TranscriptionModelOption: Equatable, Identifiable {
    let id: String        // строка, уходящая в transcription.model + движку
    let label: String     // человекочитаемое имя в пикере
}
```

**Контракты входа/выхода (без изменений от текущих):**
- Вход всех движков — 16 kHz mono Float32 (тот же поток из `.caf`, что сейчас питает `WindowedTranscriber`).
- `TranscriptionConfig` и `TranscriptionOutput` переиспользуются как есть. Единственное ослабление: `TranscriptionOutput.langStats` объявляется **best-effort** — Whisper заполняет точно (по окнам), остальные движки — как умеют (может быть один доминирующий язык или пусто). Recap и persistence на langStats не завязаны.

### B. Реестр

```swift
enum TranscriptionProviderRegistry {
    static let all: [TranscriptionProvider] = [
        WhisperKitProvider(),
        ParakeetProvider(),
        Qwen3Provider(),
        AppleProvider(),
    ]
    static func provider(id: String) -> TranscriptionProvider?
    static func availableProviders() -> [TranscriptionProvider]   // фильтр по availability()
    static func resolve(providerID: String, model: String) -> TranscriptionProvider  // + fallback на whisperkit
}
```

Единственное место со списком движков. Добавить новый = одна строка регистрации + один файл провайдера.

### C. WhisperKit как первый плагин (поведение-сохраняюще)

- `WhisperKitProvider: TranscriptionProvider` — `id="whisperkit"`, `models = [large-v3-turbo (default), large-v3, distil-large-v3 (English only), medium]`, `supportsLive=true`, `availability=.available`, `prefetch` = существующий `WhisperKitEngine.ensureModelFilesDownloaded`, `supportedLanguages` = nil (99 языков), `makeTranscriber` грузит `WhisperKitEngine` и оборачивает в `WhisperTranscriber`.
- `WhisperTranscriber: Transcriber` — `transcribe` запускает существующий `WindowedTranscriber` (над `WhisperKitEngine` + `resolveWindowLanguage`); `makeLiveSession` оборачивает существующий `StreamingTranscriber`.
- `TranscriptionEngine` (detectLanguage/transcribeWindow) переименовывается в **`WhisperWindowEngine`** и становится приватным контрактом Whisper-плагина. `resolveWindowLanguage`, per-window forced language и пин-тест `StreamingTranscriberTests.testMatchesBatchOnSameSamples` переезжают внутрь Whisper-плагина и **перестают быть общим кодом**, навязанным другим движкам.
- **Критерий успеха T0:** все существующие тесты (`WindowedTranscriberTests`, `StreamingTranscriberTests`, `TranscriptionModelProvisionerTests`, `MeetingRecorderCenterTests`) проходят без изменения ассертов — доказательство, что рефактор ничего не сломал.

### D. Новые провайдеры (batch-only, независимые)

| Провайдер | Зависимость | Модель | Языки | Live |
|---|---|---|---|---|
| `ParakeetProvider` | FluidAudio (SPM) | `parakeet-tdt-0.6b-v3` | 25 европейских (ru/uk/en ✓) | false |
| `Qwen3Provider` | `soniqo/speech-swift` или `FluidInference/qwen3-asr-0.6b-coreml` (SPM) | `Qwen3-ASR-0.6B` | 52 языка | false |
| `AppleProvider` | Speech.framework (system) | системная | supportedLocales **без uk** | false |

- Каждый реализует `transcribe` через свой нативный long-form/VAD путь и заполняет `TranscriptionOutput.text` + best-effort `langStats`.
- `AppleProvider.availability()` → `.unavailable("Требуется macOS 26")` на более старых ОС; `supportedLanguages` не содержит `uk`.
- CoreML/MLX-модели качаются в рантайме (как WhisperKit), в бандл не кладутся.

### E. Настройки + миграция

- Два пикера в `SettingsView` «Transcription»: **Provider** и **Model** (список моделей = `provider.models`).
- Новый ключ `transcription.provider` (default `whisperkit`); существующий `transcription.model` интерпретируется в контексте провайдера.
- **Миграция:** отсутствие `transcription.provider` → `whisperkit`. Существующие установки (у которых `transcription.model` = `large-v3` / `large-v3-v20240930`) продолжают работать без действий пользователя.
- Провайдеры с `availability == .unavailable` скрыты/задизейблены. Если выбранный провайдер не поддерживает язык из `langset` (напр. `uk` при Apple) — инлайн-warning.
- `onChange` любого из двух пикеров → `provisioner.ensureDownloaded(providerID:, model:)`.

### F. MeetingRecorderCenter + Provisioner

- `defaultEngineFactory` читает `transcription.provider` + `transcription.model` → `TranscriptionProviderRegistry.resolve(...).makeTranscriber(...)`.
- Batch: `transcriber.transcribe(...)`.
- Live: если `transcriber.makeLiveSession(config:) != nil` → live-панель как сейчас; иначе панель показывает «идёт запись», транскрипт появляется после Stop. `RecordingIndicatorView` учитывает `supportsLive`.
- Fallback (engine-load / stream fail → batch из `.caf`) сохраняется, становясь провайдер-специфичным (движок уже выбран из реестра, тот же).
- `TranscriptionModelProvisioner` (уже модель-агностичен, принимает `modelName`) обобщается до `(providerID, model)`; download-функция берётся у провайдера (`provider.prefetch`). Регистр состояний (idle/downloading/failed, supersede) без изменений.

## Тестирование

- **Реестр:** уникальность `id`, непустые `models`, `resolve` с неизвестным id падает на whisperkit.
- **WhisperKit-рефактор:** все существующие тесты зелёные без ослабления ассертов (главный критерий T0).
- **Availability:** `AppleProvider` отфильтрован на macOS < 26; `supportedLanguages` не содержит `uk`.
- **Оркестрация с fake-провайдером:** `MeetingRecorderCenter` тестируется с подставным `TranscriptionProvider`/`Transcriber` (как сейчас с fake engine) — реальные CoreML-модели в юнит-тесты не тянутся.
- **Новые провайдеры:** batch smoke-тест на короткой аудио-фикстуре — опциональный/помеченный (может требовать загрузки модели), не в обязательном CI-прогоне.

## Гранулярная разбивка (под параллельную реализацию)

- **T0 — Фундамент (блокирующий, делается первым):** протоколы (`TranscriptionProvider`/`Transcriber`/`TranscriptionLiveSession`/`ProviderAvailability`/`TranscriptionModelOption`) + `TranscriptionProviderRegistry` + обобщение `TranscriptionModelProvisioner` до `(providerID, model)` + два пикера в Settings + миграция ключа `transcription.provider` + рефактор `MeetingRecorderCenter.defaultEngineFactory` + перенос WhisperKit за новый контракт (`WhisperKitProvider`/`WhisperTranscriber`, переименование `TranscriptionEngine`→`WhisperWindowEngine`). Все существующие тесты зелёные.
- **T1 ∥ ParakeetProvider:** FluidAudio SPM-зависимость + batch `Transcriber` + регистрация + языки + тест.
- **T2 ∥ Qwen3Provider:** Swift Package + batch `Transcriber` + регистрация + языки + тест.
- **T3 ∥ AppleProvider:** Speech.framework + `availability` (macOS 26+) + batch `Transcriber` + uk-warning + регистрация + тест.

T1/T2/T3 зависят **только** от T0 и независимы между собой → раздаются трём исполнителям параллельно.

## Риски и открытые вопросы

- Точные API FluidAudio и Qwen3-Swift (сигнатуры, инициализация, формат языкового вывода), их лицензии и вес — выясняются внутри T1/T2 при реализации.
- Семантика `langStats` для не-Whisper: best-effort, не блокирует recap/persistence. Если провайдер не даёт язык — `langStats` может быть пустым.
- Apple SpeechAnalyzer натурально стриминговый; в первой волне аккумулируем финальный результат как batch (live отложено).
- Inventory: контракта на транскрайбер в `docs/inventory/` нет; эквивалентность live↔batch держится пин-тестом `StreamingTranscriberTests.testMatchesBatchOnSameSamples`, который остаётся whisper-internal. При переносе — сохранить его зелёным.
- `docs/superpowers/plans/2026-07-14-model-prefetch.md` и CLAUDE.md-секция «Meeting Transcriber» упоминают single-provider модель — обновить после реализации T0.
