# Apple SpeechAnalyzer / SpeechTranscriber as an alternative transcription engine — Design

**Date:** 2026-07-15
**Branch:** feature/meeting-transcriber
**Builds on:** [2026-07-13-meeting-transcriber-design.md](2026-07-13-meeting-transcriber-design.md), [2026-07-14-live-transcription-design.md](2026-07-14-live-transcription-design.md)
**Status:** research + design decision — **NOT approved for implementation** (blocked by language support, see §1)

---

## 1. Резюме и вывод (главный ответ — читать первым)

Задача: рассмотреть Apple `SpeechAnalyzer` / `SpeechTranscriber` (нативный `Speech` framework, представлен на WWDC 2025, доступен с **macOS 26 Tahoe / iOS 26**) как альтернативный движок за существующей абстракцией `TranscriptionEngine`.

**Вывод: для целевого набора языков проекта `{ru, uk, en}` движок НЕПРИМЕНИМ как замена WhisperKit — потому что Apple не поддерживает украинский язык.**

Разбор по языкам (детали и источники в §2):

| Язык | `SpeechTranscriber.supportedLocales` | Годен для проекта |
|------|--------------------------------------|-------------------|
| Английский (`en_*`) | ✅ есть (en_US, en_GB, en_IE, …) | да |
| Русский (`ru_RU`) | ✅ есть | да |
| **Украинский (`uk`)** | ❌ **отсутствует** | **нет** |

Проект строился вокруг смешанных ru/uk/en звонков (windowed sticky language detection над `{ru, uk, en}`, борьба с "суржик collapse" — прямая цель дизайна 2026-07-13). Движок, который физически не умеет украинский, ломает центральное качество-требование: украинская речь будет распознаваться как что-то другое (скорее всего русский), без какого-либо честного сигнала об этом. Это не деградация "на пару процентов WER" — это отсутствие языка.

**Рекомендация:**

1. **Не заменять** WhisperKit на Apple-движок. WhisperKit остаётся движком по умолчанию и единственным, который покрывает весь `{ru, uk, en}`.
2. **Опционально** (и только если появится явный запрос владельца) — добавить Apple-движок как **необязательный, opt-in движок для ru/en-only рабочих пространств** и/или для устройств на macOS 26+, где пользователь готов пожертвовать украинским ради скорости/батареи/меньшего футпринта. Это чистое расширение за абстракцией `TranscriptionEngine`, не трогающее WhisperKit-путь. Условия и цена этого варианта — в §4–§8.
3. **Пересмотреть** это решение, если/когда Apple добавит `uk` в `supportedLocales` (список загружается динамически с сервера ассетов — см. §2 — поэтому украинский может появиться без изменений в нашем коде; проверка сводится к рантайм-запросу `supportedLocales`, а не к перечитыванию документации).

Всё, что ниже (§3–§8) — проектирование **опционального** варианта (пункт 2). Если владелец не заинтересован в ru/en-only движке, спека закрывается на этом выводе и §3–§8 можно не реализовывать.

---

## 2. Результаты ресёрча по языкам и API

### 2.1 Что такое SpeechAnalyzer / SpeechTranscriber

`SpeechAnalyzer` — новый on-device speech-to-text стек Apple, представленный на WWDC25 (сессия 277 "Bring advanced speech-to-text to your app"). Он приходит на смену `SFSpeechRecognizer` и состоит из модулей, добавляемых в сессию анализа:

- **`SpeechTranscriber`** — long-form / диктовка минутами и часами (наш кейс: транскрипция встреч);
- `DictationTranscriber` — короткие фразы (эквивалент старого `SFSpeechRecognizer`);
- `SpeechDetector` — voice activity detection.

Модель под `SpeechTranscriber` — новая, обученная Apple специально под sustained-транскрипцию, работает **полностью on-device**, не увеличивает размер/память приложения (модели живут вне адресного пространства приложения) и обновляется системой автоматически. По независимым бенчмаркам (MacStories) командная утилита на `SpeechAnalyzer`/`SpeechTranscriber` прошла 7 GB видео ~2.2× быстрее MacWhisper Large V3 Turbo без заметной потери качества.

Источники: [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer), [Bringing advanced speech-to-text capabilities to your app](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app), [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/), [MacStories hands-on](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/), [DEV: The Next Evolution of Speech-to-Text using SpeechAnalyzer](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo).

### 2.2 Поддержка языков — решающий вопрос

`SpeechTranscriber.supportedLocales` возвращает (на момент ресёрча, iOS/macOS 26):

```
ar_SA, da_DK, de_AT, de_CH, de_DE,
en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ, en_SG, en_US, en_ZA,
es_CL, es_ES, es_MX, es_US, fi_FI,
fr_BE, fr_CA, fr_CH, fr_FR, he_IL,
it_CH, it_IT, ja_JP, ko_KR, ms_MY, nb_NO,
nl_BE, nl_NL, pt_BR, ru_RU, sv_SE, th_TH, tr_TR, vi_VN,
yue_CN, zh_CN, zh_HK, zh_TW
```

- **Русский `ru_RU` — ЕСТЬ.**
- **Английский — ЕСТЬ** (много региональных вариантов).
- **Украинского `uk` / `uk_UA` — НЕТ.** Его нет в списке ни в каком виде.

`supportedLocales` документирован как "локали, которые транскрайбер умеет, включая ещё не установленные, но загружаемые" — то есть это полный каталог с сервера ассетов, а не только локально установленное. Отсутствие `uk` означает, что модель украинского у Apple попросту нет, а не "не докачана".

Важное следствие для будущего: список приходит с сервера ассетов и может расширяться независимо от версии ОС и от нашего кода. Поэтому "поддержан ли украинский" — это **рантайм-проверка `SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == "uk" }`**, а не константа в коде. Наша интеграция (если делаем) обязана проверять доступность локали в рантайме и честно отключаться, если языка нет.

Источники: [SpeechTranscriber.supportedLocales — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales), [SpeechTranscriber — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber), [iOS 26: SpeechAnalyzer Guide — Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide).

### 2.3 Мультиязычность / code-switching

`SpeechTranscriber(locale:)` инициализируется **одной локалью на сессию**. По части источников модель заявлена способной подхватывать смену языка внутри потока, но это не подтверждается документацией и, что важнее, ограничено набором **поддержанных** локалей — украинского там всё равно нет. Для наших смешанных ru/uk/en звонков это двойная проблема: (а) нет украинского вообще; (б) модель "одна локаль на сессию" концептуально противоречит нашему per-window sticky-переключению (см. §5).

Источник: [SpeechAnalyzer vs SFSpeechRecognizer — Blake Crosley](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer).

### 2.4 Загрузка языковых моделей (`AssetInventory`)

Паттерн из гайдов и WWDC:

```swift
func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
    guard await SpeechTranscriber.supportedLocales.contains(where: {
        $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }) else { throw UnsupportedLocaleError() }

    if await SpeechTranscriber.installedLocales.contains(...) { return }

    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        // request.progress — Progress-объект для UI
        try await request.downloadAndInstall()
    }
}
```

- Транскрипция полностью on-device; **модели скачиваются один раз** с серверов Apple (нужен интернет на первую загрузку локали), дальше офлайн.
- Есть лимит на число одновременно "зарезервированных" локалей; при переборе `AssetInventory` может освободить лишние (`reserveLocale` / deallocation).
- Загрузка даёт `Progress` — можно показывать пользователю, ровно как мы показываем WhisperKit download progress (`TranscriptionModelProvisioner`).
- **Точные размеры моделей Apple не публикует.** Плюс относительно WhisperKit large-v3: модели живут вне бандла/памяти приложения и обновляются системой (нам не нужен свой кэш и своя логика докачки).

Источники: [assetInstallationRequest / AssetInventory (через гайды выше)](https://developer.apple.com/documentation/speech/speechanalyzer), [The Next Evolution of Speech-to-Text using SpeechAnalyzer](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo).

### 2.5 Живая (streaming) транскрипция и формат аудио

- Вход — `AsyncStream` из `AnalyzerInput`, обёртывающих `AVAudioPCMBuffer`. Аудио-вход декуплирован от результатов (built-in backpressure).
- **Формат аудио диктует Apple**, не мы: нужно привести буферы к `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` (обычно НЕ наши 16 kHz mono Float32 — потребуется свой `AVAudioConverter`).
- Результаты приходят как `AsyncSequence` у модуля (`transcriber.results`), каждый со свойством `isFinal`:
  - **volatile results** — быстрые черновые гипотезы, могут переписываться (для live-субтитров);
  - **final results** — максимально точные, после доставки не меняются.
- Для файловой (batch) транскрипции: `analyzer.finalizeAndFinishThroughEndOfInput()` + чтение `results` где `isFinal`.

Пример (из гайдов):

```swift
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange]
)
let analyzer = SpeechAnalyzer(modules: [transcriber])
// live: yield AnalyzerInput в makeStream(); batch: finalizeAndFinishThroughEndOfInput()
for try await r in transcriber.results where r.isFinal {
    finalText.append(r.text)   // r.text: AttributedString
}
```

Источники: [Transcribe Audio With SpeechAnalyzer In Swift — The Swift Dev](https://www.theswift.dev/posts/transcribe-audio-with-speechanalyzer-in-swift/), [iOS 26: SpeechAnalyzer Guide](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide), [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/).

### 2.6 Минимальная версия ОС

`SpeechAnalyzer`/`SpeechTranscriber` — **только macOS 26 (Tahoe) / iOS 26+**. Проект таргетит **macOS 14+** (см. `WatchtowerDesktop/Package.swift`, спека 2026-07-13 гейтит запись на 14.4+). Значит движок доступен лишь меньшинству пользователей и требует `@available` гейтинга (см. §6).

---

## 3. Как SpeechAnalyzer ложится на абстракцию `TranscriptionEngine`

Текущая абстракция (`TranscriptionEngine.swift`) — двухметодный протокол, заточенный под Whisper-модель "per-window":

```swift
protocol TranscriptionEngine: Sendable {
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    func transcribeWindow(_ samples: [Float], language: String) async throws -> String
}
```

Обе точки — синхронные "дай окно 16 kHz Float32, верни результат по этому окну". `WindowedTranscriber` и `StreamingTranscriber` строятся поверх, деля `resolveWindowLanguage`.

**Проблема соответствия.** SpeechAnalyzer — это НЕ "окно → текст". Это долгоживущая сессия с внутренним VAD, собственным окном контекста, собственной моделью, потоком volatile/final результатов и **фиксированной локалью на сессию**. Наша модель `detectLanguage(window)` + `transcribeWindow(window, forcedLanguage)` ей чужда:

- у SpeechTranscriber нет публичного "определи вероятности языков для этого куска" (`detectLanguage` не на что маппить — язык задаётся при создании сессии);
- окна/чанки нарезает и контекст держит сама Apple; наша ручная нарезка на 20 s ломает её преимущество (long-form контекст) и не даёт нам ничего взамен.

Значит **нельзя реализовать текущий `TranscriptionEngine` через SpeechAnalyzer честно** — семантика `detectLanguage`/`transcribeWindow` не имеет аналога.

**Вывод по абстракции:** если движок и добавлять, то **не** через существующий `TranscriptionEngine`, а через новый, более высокоуровневый seam. Предлагается ввести протокол уровня "движок целиком", а не "движок одного окна":

```swift
protocol MeetingTranscriptionEngine: Sendable {
    /// Полная транскрипция набора сэмплов (batch путь).
    func transcribe(samples: [Float],
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput
    /// Живая транскрипция над потоком сэмплов (live путь).
    func transcribeStream(_ samples: AsyncStream<[Float]>,
                          onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput
}
```

- **WhisperKit-путь** реализует этот протокол тривиально: `WindowedTranscriber`/`StreamingTranscriber` уже имеют ровно эти сигнатуры (`transcribe(samples:progress:)`, `run(samples:onChunk:)`) — обёртка на несколько строк, старый `TranscriptionEngine` остаётся внутренней деталью WhisperKit-реализации и не трогается.
- **Apple-путь** реализует тот же протокол поверх `SpeechAnalyzer` напрямую: batch = сессия по всему файлу с `finalizeAndFinishThroughEndOfInput`; live = сессия над `AsyncStream<AnalyzerInput>`, куда мы конвертим live-сэмплы recorder'а. Нарезку на окна и sticky-язык мы НЕ делаем — их роль берёт на себя Apple-сессия (одна локаль).

`MeetingRecorderCenter` уже держит `engineFactory` и оперирует `TranscriptionOutput` + `StreamChunk` — если seam сдвинуть на этот уровень, Center почти не меняется (см. §6).

Что мапится, что нет:

| Возможность | WhisperKit | Apple SpeechAnalyzer |
|---|---|---|
| Batch из файла | `WindowedTranscriber` | сессия + `finalizeAndFinishThroughEndOfInput` |
| Live поток | `StreamingTranscriber` | сессия + `AsyncStream<AnalyzerInput>`, volatile→final |
| Формат входа | 16 kHz mono Float32 (наш) | `bestAvailableAudioFormat` (свой конвертер) |
| Мульти-язык в звонке | per-window sticky {ru,uk,en} | одна локаль/сессия; **uk отсутствует** |
| `langStats` | реальные счётчики окон по языкам | синтетические (одна локаль → `{ "ru": N }`) |
| Прогресс | window N/M | `Progress` от Apple, маппить в N/M |

---

## 4. Инвариант live↔batch эквивалентности

Сегодня инвариант жёсткий: `StreamingTranscriber` и `WindowedTranscriber` дают **побитово эквивалентный** финальный `TranscriptionOutput` на одних и тех же сэмплах (границы окон, sticky-язык, форма `langStats`), пин-тест `StreamingTranscriberTests.testMatchesBatchOnSameSamples`. Это работает, потому что оба пути — наш собственный код над общей `resolveWindowLanguage`.

**С Apple-движком этот инвариант в прежнем виде недостижим и не нужен:**

- Нарезку окон и накопление контекста делает Apple внутри, детерминизм границ нам не гарантирован; volatile-результаты по определению переписываются.
- Live и batch у Apple — это две разные конфигурации одной сессии (`makeStream` vs `finalizeAndFinishThroughEndOfInput`). Apple не обещает, что поток volatile→final даст ровно тот же финальный текст, что и файловый прогон того же аудио.

Поэтому для Apple-реализации инвариант переопределяется мягче:

- **Не** "побитовое равенство live и batch", а "**оба финализируются только по `isFinal`-результатам**" — то есть в сохранённый транскрипт и live-панель, и batch кладут одинаково финализированный текст (volatile-гипотезы наружу в сохранение не текут). Это и есть аналог single-pass гарантии из 2026-07-14: показанное ≈ сохранённому, потому что сохраняем только `isFinal`.
- Пин-тест `StreamingTranscriberTests.testMatchesBatchOnSameSamples` остаётся жить **как есть для WhisperKit-пути** (он и есть про WhisperKit-транскрайберы) — его нельзя ослаблять или переименовывать (это inventory-guard соглашение из CLAUDE.md). Apple-путь пинуется **отдельным** тестом с более слабым, но честным контрактом: "live-поток и batch над одинаковым входом дают одинаковый набор final-сегментов" (на фейковом `SpeechAnalyzer`-адаптере, без реального фреймворка в CI).

Иными словами: не трогаем существующий инвариант WhisperKit, а для Apple вводим параллельный, соответствующий тому, что Apple реально гарантирует.

---

## 5. Почему одна-локаль-на-сессию — это регресс качества, а не просто "другой способ"

Ядро качества проекта (спека 2026-07-13, §4.2) — per-window sticky detection над `{ru, uk, en}`: каждое 20 s окно получает свой язык при уверенности ≥ порога, иначе липнет к предыдущему. Это то, что не даёт смешанному ru/uk/en звонку схлопнуться в "суржик".

Apple `SpeechTranscriber` — одна локаль на сессию. Даже если игнорировать отсутствие `uk`, для двуязычного ru/en звонка мы бы получили либо (а) одну локаль на весь звонок (английские куски в русской сессии деградируют, и наоборот), либо (б) необходимость запускать и переключать несколько сессий — чего публичный API "из коробки" под наш sticky-алгоритм не предоставляет. Заявленное "подхватывает смену языка" не документировано и, повторюсь, не спасает от отсутствия украинского.

Вывод усиливается: Apple-движок хорош для **моноязычных** (или ru-only / en-only) записей на macOS 26, но по смешанному мультиязычному кейсу — центральному для проекта — он строго слабее WhisperKit.

---

## 6. Гейтинг по версии ОС и выбор движка в Settings

### 6.1 Доступность

- WhisperKit-движок: macOS 14.4+ (текущий гейт записи). Движок по умолчанию, всегда доступен.
- Apple-движок: `@available(macOS 26, *)` — весь Apple-специфичный код изолируется в одном файле (`AppleSpeechEngine.swift`), как `WhisperKitEngine.swift` изолирует WhisperKit churn. На macOS < 26 файл компилируется, но фабрика движка на рантайме его не предлагает.

### 6.2 Выбор в Settings

Новый ключ `transcription.engine` ∈ `{ whisperkit (default), apple }`, читается фабрикой движка (рядом с существующим `transcription.model`, который остаётся Whisper-specific). Правила показа опции:

1. Пункт "Apple Speech (on-device, macOS 26+)" виден в Settings **только если** `#available(macOS 26, *)`.
2. При выборе Apple-движка выполняется **рантайм-проверка `supportedLocales`** против сконфигурированного `langset`:
   - если в langset есть `uk` (или любой не поддержанный Apple язык) — показать честное предупреждение: "Apple Speech не поддерживает украинский; украинская речь будет распознана неверно. Для ru/uk/en используйте WhisperKit." и НЕ давать выбрать Apple молча;
   - если langset ⊆ supportedLocales (например только `ru,en`) — выбор разрешён.
3. Фабрика движка (`engineFactory` в `MeetingRecorderCenter`) на старте записи ещё раз валидирует доступность и при несовместимости **падает обратно на WhisperKit** (никогда не тихо выдаёт мусорный транскрипт). Это соответствует правилу проекта "async-операция переживает сбой, аудиофайл всегда цел" и духу live-фолбэка из 2026-07-14 (движок не поднялся → batch WhisperKit из файла).

### 6.3 Прогресс загрузки моделей

`TranscriptionModelProvisioner` сейчас знает только про WhisperKit download. Для Apple-движка prefetch идёт через `AssetInventory.assetInstallationRequest(...).progress`. Провижионер обобщается до "убедись, что модель выбранного движка скачана", маппя оба `Progress`-источника в тот же UI capsule прогресса (см. недавний коммит `feat(transcriber): show model-download progress as its own capsule`).

---

## 7. Открытые вопросы и риски

1. **Украинский (блокер).** Всё держится на отсутствии `uk`. Если Apple добавит — пересматриваем (проверка рантайм-`supportedLocales`, кода менять не нужно). До тех пор Apple-движок не может быть дефолтом.
2. **Мульти-язык в одной сессии.** Не подтверждено документацией, что `SpeechTranscriber` реально переключает языки внутри сессии и с каким качеством. Нужен эмпирический тест на реальном ru/en звонке, прежде чем даже ru/en-only вариант обещать пользователю.
3. **`langStats`.** Наша схема (`meeting_transcripts.lang_stats` JSON, спека 2026-07-13 §5.1) ожидает счётчики окон по языкам. Apple-путь даст в лучшем случае `{ "<locale>": <segments> }` — семантика другая. Нужно решить: синтезировать совместимую форму или пометить как "engine=apple" в данных. Схему БД это НЕ меняет (`lang_stats` уже свободный JSON), но UI лэйбл языков надо не сломать.
4. **Формат аудио.** `bestAvailableAudioFormat` почти наверняка не 16 kHz mono Float32. Нужен отдельный `AVAudioConverter` для Apple-пути и для live, и для batch — лишний код и точка расхождения с WhisperKit-путём (который живёт на 16 kHz).
5. **volatile→final и live-панель.** UI live-панели (2026-07-14) показывает готовые чанки с языковым тегом. Под Apple volatile-результаты мерцают/переписываются — надо решить, показываем ли volatile (живее, но "прыгает") или только final (стабильно, но с задержкой). Языкового тега на чанк у Apple, по сути, нет (локаль фиксирована).
6. **Размеры и лимиты ассетов.** Apple не публикует размеры моделей; есть лимит зарезервированных локалей с авто-деаллокацией — на многоязычной машине пользователя это может внезапно выгрузить нашу локаль. Нужен рантайм-`reserveLocale` и повторная проверка перед записью.
7. **CI.** `SpeechAnalyzer` нельзя гонять в CI (нет macOS 26 раннеров, нужны системные модели). Как и WhisperKit, Apple-движок изолируется за фейковым адаптером; реальный прогон — только ручная приёмка на живой машине macOS 26 ("drive the feature, not tests").
8. **Дубль путей (Go↔Swift, live↔batch).** Проект уже несёт "transcriber dual paths" (memory: recap collision guard + live/batch эквивалентность). Второй движок добавляет **третье и четвёртое** измерение расхождения (whisper-live/whisper-batch/apple-live/apple-batch). Стоимость поддержки нетривиальна — ещё один аргумент не делать это без явной пользы.

---

## 8. Оценка объёма работ (грубо)

Только для **опционального ru/en-only Apple-движка** (пункт 2 §1); если владелец не хочет — 0.

| Блок | Объём |
|---|---|
| Новый seam `MeetingTranscriptionEngine` + обёртка WhisperKit-пути под него | S (0.5 дня) |
| `AppleSpeechEngine.swift` (batch + live, `@available(macOS 26)`, конвертер формата, isFinal-финализация) | L (2–3 дня, плюс возня с реальным API на живой 26) |
| Рантайм-проверка `supportedLocales` + фолбэк на WhisperKit при несовместимости | S–M (0.5–1 день) |
| Settings: ключ `transcription.engine`, `@available`-гейт, предупреждение про uk | S (0.5 дня) |
| `TranscriptionModelProvisioner`: обобщение под `AssetInventory` прогресс | S–M (0.5–1 день) |
| Live-панель UI под volatile/final и отсутствие языкового тега | M (1 день) |
| Тесты: фейковый Apple-адаптер, отдельный live↔batch пин-тест для Apple-пути, гейт/фолбэк | M (1–1.5 дня) |
| Ручная приёмка на macOS 26 (реальный ru/en звонок, качество, батарея) | M (1 день) |
| **Итого** | **~7–9 дней инженера + машина на macOS 26** |

Плюс постоянная стоимость поддержки четырёх путей транскрипции (§7.8).

**Рекомендация по объёму:** учитывая, что дефолтом Apple-движок стать не может (нет `uk`), а выгода ограничена ru/en-only подмножеством пользователей на macOS 26, — **отложить** до одного из триггеров: (а) Apple добавляет украинский, либо (б) появляется конкретный пользователь/рабочее пространство с ru/en-only профилем, которому критичны скорость/батарея/футпринт Apple-движка. Абстракцию (`MeetingTranscriptionEngine` seam, пункт первый в таблице) можно ввести заранее и дёшево — она полезна сама по себе и не требует Apple.

---

## 9. Источники

- [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
- [SpeechTranscriber.supportedLocales — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)
- [Bringing advanced speech-to-text capabilities to your app — Apple](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [WWDC25 session 277 — Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [iOS 26: SpeechAnalyzer Guide — Anton Gubarenko](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [The Next Evolution of Speech-to-Text using SpeechAnalyzer — DEV](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo)
- [Transcribe Audio With SpeechAnalyzer In Swift — The Swift Dev](https://www.theswift.dev/posts/transcribe-audio-with-speechanalyzer-in-swift/)
- [Hands-On: How Apple's New Speech APIs Outpace Whisper — MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- [Apple's New Speech Framework: SpeechAnalyzer vs SFSpeechRecognizer — Blake Crosley](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
- [Apple SpeechAnalyzer and Argmax WhisperKit — Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
