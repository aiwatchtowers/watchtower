# Умные границы окон (silence-snapping) + роли говорящих (диаризация) — Design

**Date:** 2026-07-15
**Branch:** feature/meeting-transcriber
**Builds on:** [2026-07-13-meeting-transcriber-design.md](2026-07-13-meeting-transcriber-design.md), [2026-07-14-live-transcription-design.md](2026-07-14-live-transcription-design.md)

---

## 1. Проблемы

1. **Резка «по живому».** `WindowedTranscriber`/`StreamingTranscriber` режут аудио жёстко: окно `windowSec` (20 с) + перехлёст `overlapSec` (1 с). Граница попадает посреди слова — Whisper теряет/коверкает слова на стыках, перехлёст порождает дубли.
2. **Нет ролей.** Транскрипт — сплошной текст без указания, кто говорит. При этом mic и system audio физически приходят раздельными буферами в `TapRecorderImpl.handleInput` и смешиваются в моно у нас — сигнал «говорю я или собеседник» сейчас выбрасывается.

Решение — две независимые части. Обе не меняют схему БД и не меняют Go (кроме нуля строк: sidecar-файлы подметаются существующим orphan-sweep'ом `cleanupOrphanRecordings`, т.к. именуются с префиксом `rec_`).

Утверждённые владельцем решения: полная диаризация Speaker 1/2/3 (не только «я/собеседник»), метки ролей **только в сохранённом транскрипте** (live-панель без ролей, диаризация — пост-проход по файлу после Stop).

---

## 2. Часть 1 — привязка границ окон к тишине

### 2.1 Алгоритм

Вместо реза ровно на номинальной границе `start + windowSamples` ищем самую тихую точку в зоне допуска вокруг неё:

- Новое поле `TranscriptionConfig.boundarySnapSec: Double = 2.5` (`0` — снэппинг выключен, поведение байт-в-байт старое). Читается из `transcription.boundarySnapSec` в `fromDefaults`.
- Эффективный допуск: `tol = min(boundarySnapSec·16k, windowSamples/4)` — чтобы крошечные тестовые окна (0.01 с) не вырождались.
- Зона поиска: `[nominalEnd − tol, min(nominalEnd + tol, samples.count)]`. Энергия — RMS по кадрам 20 мс с шагом 10 мс; рез в центре самого тихого кадра, при равенстве побеждает самый ранний (детерминизм).
- Следующий старт: `max(start + 1, cutEnd − overlapSamples)` (guard от нулевого прогресса).
- Правило «последнего окна» не меняется: если `nominalEnd ≥ samples.count`, окно — последнее, обрезанное по факту (снэппинг к нему не применяется).

### 2.2 Общий код и live↔batch эквивалентность

Вся оконная математика (границы + снэппинг) выносится в **один общий планировщик** (`WindowPlanner`, новый файл рядом с `TranscriptionEngine.swift`), который потребляют оба транскрайбера:

- **Batch (`WindowedTranscriber`)**: двухпроходно — сначала планировщик по всем сэмплам вычисляет все границы (чистый DSP, дёшево), затем транскрипция; `progress(done, total)` сохраняет точный `total`.
- **Live (`StreamingTranscriber`)**: окно с началом `absStart` эмитится, как только буфер покрывает `absStart + windowSamples + tol` (полная зона снэппинга доступна) **или** стрим закрылся. Обе ветки дают ровно те же границы, что batch на тех же сэмплах: клампинг зоны по `samples.count` у batch эквивалентен клампингу по факту конца стрима у live. Лаг live-панели растёт на ~`boundarySnapSec` — незаметно.

Инвариант `StreamingTranscriberTests.testMatchesBatchOnSameSamples` остаётся жёстким и дополняется вариантом со включённым снэппингом и синтетическим энергетическим рельефом (тихие «паузы» в известных местах) — пин того, что оба пути режут в одних и тех же точках. Существующие тесты с точными `windowSizes`-ассертами переводятся на `boundarySnapSec = 0` в своих конфиг-хелперах; поведение снэппинга покрывается новыми тестами планировщика (граничные случаи: всё-тишина → рез в начале зоны; пик тишины ровно на краю зоны; зона за концом сэмплов; `tol`-кламп на крошечном окне).

### 2.3 Что не меняется

Sticky-детект языка, `overlapSec`-семантика, форма `TranscriptionOutput.text`/`langStats`, contract «total engine failure throws», single-pass сохранение live-результата.

---

## 3. Часть 2 — диаризация ролей (пост-проход)

### 3.1 Обзор конвейера

```
запись:      TapRecorderImpl → rec_X.caf (как сейчас)
                            → rec_X.activity   (новое: RMS mic/system по 100 мс бинам)
Stop:        транскрипция (live или batch, как сейчас) → сегменты с таймстемпами
             → диаризация файла (FluidAudio, on-device)          — новая фаза .diarizing
             → сопоставление сегментов кластерам спикеров
             → кластер, коррелирующий с mic-активностью → «Я»; остальные Speaker 1/2/3
             → рендер "[Я] …\n[Speaker 1] …" → существующий save (та же text-колонка)
```

Любой сбой диаризационной части (модель не скачалась, decode упал, activity-файла нет) → **сохраняем транскрипт без ролей**, как сегодня. Роли — прогрессивное улучшение; аудио и текст переживают всё (контракт 2026-07-13 не трогается).

### 3.2 Таймстемпы сегментов из Whisper

Ролям нужны таймстемпы текста. `withoutTimestamps: true` выключается, протокол становится посегментным:

```swift
struct TranscribedSegment: Equatable, Sendable {
    let text: String
    let startSec: Double   // относительно начала окна
    let endSec: Double
}
protocol TranscriptionEngine: Sendable {
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment]
}
```

`WhisperKitEngine` мапит `TranscriptionResult.segments` (start/end в секундах окна). Оба транскрайбера складывают сегменты со смещением окна в абсолютные таймстемпы:

```swift
struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let startSec: Double   // абсолютно от начала записи
    let endSec: Double
    let language: String   // язык окна-родителя
}
struct TranscriptionOutput: Equatable {
    let text: String                    // как сегодня: join непустых окон через \n
    let langStats: [String: Int]        // как сегодня
    let segments: [TranscriptSegment]   // новое
}
```

Текст окна = join текстов его сегментов (trim как сегодня) — `text`/`langStats`/`StreamChunk`/live-панель не меняют форму. Эквивалентность live↔batch распространяется и на `segments` (общая логика, тот же пин-тест — `TranscriptionOutput: Equatable` сравнит и их).

Сегменты в перехлёсте окон могут дублироваться — как и сегодня дублируется текст; для назначения ролей это безвредно (оба экземпляра попадут к одному спикеру). Дедупликация — вне скоупа.

### 3.3 Дорожка активности микрофона (`rec_X.activity`)

`TapRecorderImpl` уже держит mic (буфер 0) и system (остальные) раздельно в `handleInput`. Добавляется аккумуляция RMS обоих сигналов по бинам 100 мс (на 16 кГц-таймлайне файла, т.е. по `framesWritten`) и инкрементальная дозапись в текстовый sidecar `rec_X.activity` (строка на бин: `"<micRMS> <sysRMS>\n"`, флаш раз в ~5 с на `writeQueue`). Свойства:

- Крэш-толерантно (append-only текст); потеря файла = роли без метки «Я» (все — Speaker N), не сбой.
- Файл живёт рядом с `.caf`, пока его не подметёт существующий Go orphan-sweep (`rec_*`-префикс, старше retention, не в `audio_path`) — **ноль изменений в Go**; повторная транскрипция («Re-transcribe») в течение retention-окна сохраняет метку «Я».
- Ошибка записи sidecar-а не латчится в `firstWriteError` — активность вторична к аудио.

### 3.4 Диаризация: FluidAudio

Новая SPM-зависимость [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0): offline-пайплайн (pyannote-модели на CoreML + VBx-кластеризация), вход ровно наш — 16 кГц mono Float32, модели автоскачиваются с HuggingFace при первом использовании, скорость ~60× реального времени на M1 (час звонка ≈ минута).

Сим за протоколом (тесты не грузят CoreML):

```swift
struct SpeakerSegment: Equatable, Sendable {
    let speakerID: String
    let startSec: Double
    let endSec: Double
}
protocol SpeakerDiarizing: Sendable {
    func diarize(samples: [Float]) async throws -> [SpeakerSegment]
}
```

`FluidAudioDiarizer` — единственный файл, знающий FluidAudio API (как `WhisperKitEngine` изолирует WhisperKit). `MeetingRecorderCenter` получает инжектируемую `diarizerFactory` рядом с `engineFactory`; фабрика возвращает `nil`, когда диаризация выключена в Settings.

**Риск (проверить первым шагом имплементации):** FluidAudio требует Swift 6.0 toolchain; наш манифест — `swift-tools-version 5.10`. SPM собирает зависимости их собственным language mode, так что при Xcode 16+ должно собраться; если нет — поднимаем tools-version манифеста с `.swiftLanguageMode(.v5)` на нашем таргете. Проверяется одной сборкой до всей остальной работы.

### 3.5 Назначение ролей (чистая функция, полностью тестируемая)

`RoleAssigner.render(segments: [TranscriptSegment], speakers: [SpeakerSegment], activity: MicActivity?) -> String`:

1. Каждому транскрипт-сегменту — спикер с максимальным перекрытием интервалов; без перекрытия — спикер предыдущего сегмента (или первый появившийся).
2. Метка «Я»: для каждого кластера считается доля его речевого времени, где `micRMS > k·sysRMS` (k≈2). Кластер с наибольшей долей и долей > 0.6 → `Я`; прочие — `Speaker 1..N` в порядке первого появления. Нет activity-дорожки → все `Speaker N`.
3. Рендер: соседние сегменты одного спикера сливаются в один абзац `[Я] …` / `[Speaker N] …`, абзацы через `\n`.

Итог кладётся в существующую `text`-колонку через существующий save-CLI: Go, схема БД, recap-промпт, MCP-тулзы — без изменений (recap автоматически выигрывает от ролей). Диаризация выключена/упала → рендер = сегодняшний `output.text`.

### 3.6 Оркестрация в `MeetingRecorderCenter`

- Новая фаза `Phase.diarizing` между транскрипцией и save (капсула в `RecordingIndicatorView`: «Identifying speakers…»).
- Live-путь: live-результат больше не идёт в save напрямую — после `liveTask.value` декодируем файл (только при включённой диаризации; decode дёшев относительно STT), диаризуем, рендерим. Batch-путь уже держит сэмплы — переиспользует.
- Персист рядом с аудио (`rec_X.txt`) — **уже отрендеренный** текст с ролями: retry сейва не повторяет диаризацию. «Re-transcribe» (`prepareRetry`) чистит сайдкары как сегодня и проходит весь конвейер заново.
- Провал любого шага диаризации → лог в консоль + save без ролей (**никогда** не `.failed` из-за ролей).

### 3.7 Settings и prefetch модели

- Тумблер `transcription.diarization` (Bool, default **on**) в секции Transcription.
- `TranscriptionModelProvisioner` дополнительно прогревает модели FluidAudio (его API отдаёт прогресс скачивания) под тем же UI-капсюлем, что и WhisperKit-prefetch. Провал prefetch-а диаризатора не блокирует prefetch Whisper-модели.

---

## 4. Тестирование

- **Планировщик окон**: чистые юнит-тесты границ (см. §2.2) + расширенный пин-тест эквивалентности live↔batch со снэппингом и рельефом энергии.
- **Сегменты**: `MockEngine` в обоих тест-файлах переходит на `[TranscribedSegment]`; ассерты `text`/`langStats` не меняются; новые ассерты абсолютных таймстемпов (смещение окна учтено).
- **RoleAssigner**: чистые тесты — перекрытия, сегмент без спикера, слияние абзацев, «Я»-детект по activity, отсутствие activity, один спикер, пустые входы (валидно-вырожденные кейсы по [[feedback_test_degenerate_clean_exit]]).
- **Center**: fake-диаризатор — happy path (роли в тексте), провал диаризации → save без ролей и без `.failed`, тумблер off → диаризация не вызывается, retry-персист содержит роли.
- **Sidecar активности**: формат/бины тестируются на чистой аккумулирующей структуре (`MicActivityAccumulator`), без CoreAudio.
- **FluidAudio/WhisperKit живьём**: только ручная приёмка реальной записью (make app-dev), как принято для этого модуля.

## 5. Объём

| Блок | Оценка |
|---|---|
| Часть 1: планировщик + оба транскрайбера + тесты | 1–2 дня |
| Часть 2: сегменты с таймстемпами (протокол, движок, транскрайберы, моки) | 1 день |
| Часть 2: activity-sidecar в рекордере | 0.5–1 день |
| Часть 2: FluidAudio-интеграция + провижионер + Settings | 1–1.5 дня |
| Часть 2: RoleAssigner + оркестрация Center + тесты | 1.5–2 дня |
| Ручная приёмка (реальные звонки ru/uk/en) | 0.5 дня |
| **Итого** | **~5.5–8 дней** |
