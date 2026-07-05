# Архитектурные проблемы — аудит 2026-07-05

Аудит охватывает архитектурный срез проекта Watchtower: связность и границы пакетов Go-бэкенда (`internal/*`, `cmd/*`), дублирование сквозных механизмов (AI-подсистема, парсинг ответов LLM, учёт токенов) и структуру macOS-приложения (`WatchtowerDesktop/`, MVVM-слой Models→Queries→ViewModel→View, дублирование бизнес-логики между Go и Swift). Метод: несколько специализированных агентов-искателей (`arch-go`, `arch-swift`) независимо собирали находки, после чего каждая находка прошла отдельную состязательную верификацию с трассировкой по коду; ниже приведены только подтверждённые находки (опровергнутые удалены). Итог: 16 подтверждённых находок — 0 critical, 3 high, 6 medium, 7 low.

## High

### Кастомизация промптов — молчаливый no-op для digest, tracks, inbox, briefing, guide, catchup

- **Где:** `cmd/sync.go:294`
- **Статус верификации:** ✅ подтверждено
- Каждый пайплайн предоставляет `SetPromptStore`, и его `getPrompt()` обращается к БД-хранилищу промптов только если store не nil (например, `internal/digest/pipeline.go:222-247`, `internal/inbox/pipeline.go:805-813`, `internal/briefing/pipeline.go:274-292`). Однако единственный продакшн-вызов `SetPromptStore` во всём репозитории — это `cmd/sync.go:294` для пайплайна dayplan. Ни обвязка демона (`cmd/sync.go:277-291`), ни CLI-команды `generate` (`cmd/digest.go:338`, `cmd/inbox.go:389`, `cmd/briefing.go:139`, `cmd/tracks.go:617`, `cmd/people.go:352`, `cmd/catchup.go:97`, `cmd/meeting.go:88`), ни `runPostSyncPipelines` (`cmd/sync.go:485-508`) не передают store. В результате вся пользовательская фича `watchtower prompts show/reset/rollback` + `watchtower tune --apply` (`cmd/prompts.go`) пишет версии промптов в БД, которые не читает ни один пайплайн, кроме dayplan: пользователь тюнит `digest.channel`, получает подтверждение и новую версию в истории, а демон продолжает вечно использовать встроенный дефолт — без единого предупреждения.

```go
// cmd/sync.go:293-295 — единственный вызов SetPromptStore в продакшене
dayPlanPipe := dayplan.New(...)
dayPlanPipe.SetPromptStore(prompts.New(database, nil))

// digest getPrompt (pipeline.go:228-246): при nil store — тихий fallback на дефолт
if p.promptStore != nil { ... } // Fallback to default
```

- **Рекомендация:** Вынести инъекцию prompt store в общий конструктор/обвязку, через которую строятся все пайплайны (и в обвязке демона, и в CLI-командах `generate`, и в `runPostSyncPipelines`), либо сделать store обязательным параметром фабрики пайплайна, чтобы «забыть» его было невозможно. Как минимум — логировать warning, если пайплайн запущен без store, а в БД для его промпта есть кастомная версия.

### Watermark inbox сдвигается по стенным часам даже при сбое Slack-sync или детекторов — упоминания/DM теряются навсегда

- **Где:** `internal/inbox/pipeline.go:329`
- **Статус верификации:** ✅ подтверждено
- `inbox.Pipeline.Run` безусловно сдвигает watermark обработки на `now-30min` в конце каждого прогона (строки 321-331), независимо от того, успешно ли отработала детекция. Два конкретных сценария потери: (1) демон намеренно запускает пайплайны при сбое Slack-sync (`internal/daemon/daemon.go:218-220`: «sync had errors, but running pipelines on existing data»). Если sync сломан дольше 30-минутного буфера (истёкший/отозванный токен, сетевой сбой при бодрствующей машине), каждый цикл всё равно двигает `inbox_last_processed_ts` на `now-30m`; когда sync восстановится и вставит пропущенные сообщения, их `ts_unix` окажется ниже watermark, и `FindPendingMentions`/`FindPendingDMs` (вызываемые с `lastTS` как нижней границей, строки 435/440) их никогда не увидят — упоминание тихо не попадёт в inbox и не будет повторено. (2) `detectAll` проглатывает ошибки детекторов (строки 407-421, log-and-continue), поэтому транзиентная ошибка SQLite при детекции тоже приводит к сдвигу watermark за эти сообщения. Это нарушает документированный контракт INBOX-03 (`docs/inventory/inbox-pulse.md`): «If 200 messages flow past me in a day and one needed a reaction, Inbox surfaces it». Watermark должен выводиться из прогресса sync (как `search_last_date`), а не из стенных часов.

```go
// pipeline.go:325-331 — безусловный сдвиг watermark после detectAll
bufferTS := float64(time.Now().Add(-30 * time.Minute).Unix())
if bufferTS < lastTS { bufferTS = lastTS }
if err := p.db.SetInboxLastProcessedTS(bufferTS); ...
// detectAll: ошибки только логируются
if n, err := p.detectSlackTriggers(...); err != nil { p.logger.Printf(...) }
```

- **Рекомендация:** Привязать watermark inbox к фактически обработанному прогрессу sync (аналогично `search_last_date`), а не к `time.Now()`, и сдвигать его только при отсутствии ошибок детекции. При сбое sync или ошибке детектора watermark двигать нельзя — иначе сообщения, попавшие в БД после восстановления с исходным (прошлым) `ts_unix`, будут пропущены. Добавить guard-тест на сценарий «sync упал > 30 мин, затем восстановился».

### Схема БД, вручную скопированная в `TestDatabase.swift`, разошлась с реальной — тесты зеленеют на SQL к удалённым таблицам

- **Где:** `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift:469`
- **Статус верификации:** ✅ подтверждено
- Swift-фикстура тестов держит собственную копию схемы на 39 таблиц вместо того, чтобы выводить её из `internal/db/schema.sql` или прогонять Go-миграции CLI, которые использует продакшн (`DatabaseManager.runCLIMigrations`). Фикстура всё ещё содержит удалённую таблицу `tasks` (со старым, до-`targets`, набором колонок) — именно поэтому `DayPlanQueriesTests` и `ChannelStatsTests` проходят, тогда как тот же SQL падает на любой реальной БД. Это и есть механизм, стоящий за рантайм-багами `ChannelStatsQueries.fetchValueSignals` (FROM tasks) и `DayPlanQueries.cascadeTaskStatus` (UPDATE tasks). Структурно это подрывает любую будущую Go-миграцию: любое переименование таблицы/колонки (флоу skill `add-migration`) молча оставляет тестовую схему Desktop — и, значит, Desktop-SQL — невалидированной против реальности.

```sql
-- TestDatabase.swift:469 — таблицы больше нет в schema.sql / migrations
CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ...
    source_type     TEXT ... CHECK(source_type IN ('track','digest','briefing','manual','chat','inbox'))
);
```

- **Рекомендация:** Заменить руками поддерживаемую схему на единый источник истины — прогонять реальные Go-миграции (или встраивать `internal/db/schema.sql`) при создании тестовой БД, чтобы Desktop-SQL валидировался против той же схемы, что и продакшн. Как немедленный шаг — удалить `tasks` и все ссылки на неё, чтобы соответствующие запросы начали падать в тестах так же, как в проде.

## Medium

### Роутинг моделей Codex — мёртвый код: несовпадение типов ключа контекста между пакетами digest и codex

- **Где:** `internal/codex/generator.go:20`
- **Статус верификации:** ✅ подтверждено
- Все пайплайны помечают AI-вызовы через `digest.WithSource(ctx, "inbox.prioritize")`, который кладёт source под неэкспортируемый тип `digest.sessionSourceKey` (`internal/digest/pooled.go:69-73`). `CodexGenerator.Generate` не может сослаться на этот неэкспортируемый ключ, поэтому переобъявляет собственный `type sessionSourceKey struct{}` и читает `ctx.Value(codex.sessionSourceKey{})`. Ключи контекста сравниваются по динамическому типу, а `codex.sessionSourceKey` — другой тип, нежели `digest.sessionSourceKey`, поэтому lookup ВСЕГДА возвращает nil. Итог: при `ai.provider=codex` `ModelForSource` (`internal/codex/models.go:13`, роутящий `inbox.prioritize` / `digest.channel_batch` / `people.batch` / `catchup.peel` / `customtrack.*` на `gpt-5.4-mini`) никогда не срабатывает — каждый вызов в каждом пайплайне идёт на дефолтную модель `gpt-5.4`. Комментарий у codex-`ModelForSource` даже утверждает, что он «Honors digest.SourceLight as the cross-harness contract» — а увидеть его он не может. Claude-роутинг работает лишь потому, что `digest/generator.go` — в том же пакете, что и ключ. Дефект деградирует стоимость/латентность, а не корректность вывода, отсюда medium.

```go
// codex/generator.go:17-20
// sessionSourceKey is the context key used by digest.WithSource. We re-declare it here...
type sessionSourceKey struct{}
// :38
if s, ok := ctx.Value(sessionSourceKey{}).(string); ok { ... }

// vs digest/pooled.go:69,73 — другой пакет → другой тип → Value() промахивается
type sessionSourceKey struct{}
context.WithValue(ctx, sessionSourceKey{}, source)
```

- **Рекомендация:** Экспортировать из пакета `digest` типизированный аксессор (например `digest.SourceFromContext(ctx) (string, bool)`) и заставить codex использовать именно его вместо переобъявленного локального ключа. Это устранит мёртвый роутинг и убьёт вторую расходящуюся таблицу маршрутизации моделей.

### `internal/digest` — де-факто хаб AI-абстракции: Generator/Usage/WithSource/роутинг живут внутри конкретного пайплайна, связывая 10+ пакетов

- **Где:** `internal/digest/pipeline.go:38`
- **Статус верификации:** ✅ подтверждено
- Сквозной AI-шов (интерфейс `Generator`, структура `Usage`, тегирование контекста `WithSource`/`SourceLight` в `pooled.go`, роутинг `ModelForSource` в `models.go`, `LearnedPreferencesBlock` в `preferences.go`) определён внутри `internal/digest` — конкретного пайплайна на ~2000 строк. Каждый другой пайплайн (guide, dayplan, inbox, customtracks, tracks, targets, briefing, meeting, catchup) плюс `internal/codex` импортируют digest только ради этих типов. Уже проявившиеся конкретные издержки: (1) tracks не может быть импортирован в digest (цикл), поэтому зависимость залатана дважды — через интерфейс `TrackLinker` (`pipeline.go:93-98`) для CLI-пути И через мутацию демоном экспортированного поля `digestPipe.TrackContext` (`daemon.go:447-452`), два расходящихся механизма для одних данных; (2) codex вынужден был продублировать неэкспортируемый ключ контекста и сломал его (см. находку выше); (3) таблицы роутинга `digest/models.go` и `codex/models.go` нужно вести параллельно руками. Добавление метода в `Generator` (стриминг, отмена, override модели на вызов) затрагивает 11 пакетов; переименование/выделение пакета digest фактически заморожено. Демон аналогично держит конкретные поля `*digest.Pipeline`/`*tracks.Pipeline`/…; интерфейс получил только dayplan (`DayPlanRunner`, `daemon.go:34`), поэтому тесты демона вынуждены конструировать полные реальные пайплайны для всех прочих фаз (`daemon_test.go:406-455`).

```go
// digest/pipeline.go:38
type Generator interface { Generate(...) }
// pipeline.go:95
// Defined as an interface to avoid import cycles (tracks imports digest)
// daemon.go:448-451 — второй, дублирующий механизм передачи того же контекста
if trackCtx, err := d.tracksPipe.FormatActiveTracksForPrompt(); ... {
    d.digestPipe.TrackContext = trackCtx
}
```

- **Рекомендация:** Выделить AI-шов (`Generator`, `Usage`, `WithSource`/`SourceLight`, `ModelForSource`, `LearnedPreferencesBlock`) в отдельный нейтральный пакет (например `internal/aiseam` или `internal/llm`), от которого зависят все пайплайны и оба провайдера, а `internal/digest` оставить только конкретной реализацией. Это разорвёт цикл tracks↔digest (убрав двойной механизм `TrackLinker`/`TrackContext`) и позволит codex переиспользовать ключ контекста и таблицу роутинга без дублирования.

### Стек Claude-CLI-подпроцесса продублирован в `internal/ai` и `internal/digest` с поведенческим дрейфом: обработка CLAUDECODE и cwd различаются

- **Где:** `internal/ai/client.go:173`
- **Статус верификации:** ✅ подтверждено
- `internal/ai/client.go` и `internal/digest/generator.go` содержат каждый свою копию `cliResponse`, `cliUsage`, `parseCLIOutput`, `limitedWriter`, `classifyError` и настройки exec-окружения/TCC (а `internal/codex` — третью копию `limitedWriter`/`classifyError`). Они уже разошлись: `digest/generator.go:211-219` вырезает переменную окружения `CLAUDECODE` («avoid nested-session detection when launched from a parent process that is itself a Claude Code session») и запускается из `~/.config/watchtower`, тогда как `ai.Client.Query`/`QuerySync` (строки 173-175, 253-255) сохраняет `CLAUDECODE` и запускается из `os.TempDir()`. Значит вызовы `watchtower ask`/chat/REPL/jira-board-analyzer (использующие `ai.Client`), запущенные из демона, порождённого сессией Claude Code, натыкаются ровно на тот сбой вложенной сессии, от которого была пропатчена сторона digest. Учитывая, что в истории проекта фиксы TCC responsibility-chain — это P0, каждый такой фикс приходится находить и применять в 2-3 местах, и один (CLAUDECODE) на стороне `ai.Client` уже пропущен.

```go
// digest/generator.go:203-213
// - Remove CLAUDECODE to avoid "nested session" detection...
if strings.HasPrefix(e, "CLAUDECODE=") { continue }

// ai/client.go:173-175 — аналога нет, только PATH
cmd.Env = append(os.Environ(), "PATH="+claude.RichPATH())
```

- **Рекомендация:** Вынести конструирование Claude-CLI-подпроцесса (env-setup, cwd, `parseCLIOutput`, `limitedWriter`, `classifyError`) в один общий хелпер, используемый и `ai.Client`, и `digest.ClaudeGenerator`, чтобы TCC/env-фиксы (включая вырезание `CLAUDECODE`) применялись в одном месте. Немедленно — продублировать вырезание `CLAUDECODE` и корректный cwd на сторону `ai.Client`.

### Снятие markdown-«забора» с JSON-ответов AI переизобретено ≥7 раз с расходящимся поведением на краях

- **Где:** `internal/inbox/pipeline.go:962`
- **Статус верификации:** ✅ подтверждено
- Каждый пайплайн вручную вычленяет JSON из markdown-fence: `inbox.parseAIResult` (`pipeline.go:962-978`, отбрасывает первую И последнюю строки всякий раз, когда ответ начинается с ```` ``` ```` — портит ответ, у которого закрывающий забор не на последней строке), `briefing.parseBriefingResult` (`pipeline.go:635-653`, использует `LastIndex("```")`), `tracks.cleanJSON` (`pipeline.go:1755`), `meeting.cleanJSON` (`pipeline.go:507`), `guide.extractJSON` (`pipeline.go:1068`), `jira.extractJSON` (`board_analyzer.go:746`), `dayplan.parseResponse` (`prompt.go:171`), плюс `inbox/pinned_selector.parsePinnedResponse` (`pinned_selector.go:113`) и `targets.parseExtractResponse`/`parseLinkResponse`. Все реализуют один контракт («модель может обернуть JSON в забор / добавить прозу») с разной толерантностью к прозе до/после забора, поэтому один и тот же вывод модели парсится в одном пайплайне и падает в другом. Показательно: канонический толерантный хелпер `prompts.ExtractJSONObject` (`internal/prompts/json.go`) уже существует, но принят лишь ОДНИМ call-site (`targets/nextstep.go`) — намерение консолидации доказано, но не завершено. Когда провайдер начнёт предварять ответ фразой перед забором (известный сдвиг поведения Codex/Claude), фикс придётся искать и править в 7+ копиях; применённый лишь к одной, он оставит остальные молча дропать результаты AI — а в inbox/briefing это значит, что прогон логируется как parse error и его токены тратятся впустую каждый цикл.

```go
// inbox/pipeline.go:964-971 — отбрасывает первую И последнюю строку
if strings.HasPrefix(response, "```") {
    lines := strings.Split(response, "\n")
    if len(lines) > 2 { lines = lines[1 : len(lines)-1] ... }
}
// vs briefing/pipeline.go:637-645 — SplitN + LastIndex, иной алгоритм для той же задачи
lines := strings.SplitN(response, "\n", 2) ...
if idx := strings.LastIndex(response, "```"); idx >= 0 { response = response[:idx] }
```

- **Рекомендация:** Перевести все call-sites на существующий `prompts.ExtractJSONObject` и удалить локальные копии, оставив один толерантный алгоритм (забор с любым языком + fallback по крайним фигурным скобкам). Добавить общий тест на «прозе до и после забора».

### Поведенческие контракты реализованы дважды (Go + Swift) без общего энфорсмента — одно зеркало уже разошлось и сломалось

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:228`
- **Статус верификации:** ✅ подтверждено
- Существует минимум 8 самообъявленных «Mirrors Go» дублирований бизнес-логики в Swift: каскад INBOX-02 target-close→inbox-resolve (`TargetQueries.updateStatus` vs `internal/db/targets.go UpdateTargetStatus`), каскад catch-up acknowledge (`CatchUpQueries.acknowledge:76` vs `internal/catchup/pipeline.go:443`), деривация правил из inbox-фидбэка (`InboxFeedbackQueries.record:11` vs `internal/inbox/feedback.go:14`), channel value signals (`ChannelStatsQueries:169` — уже разошлось), SHA256 `ComputeConfigHash` Jira-доски (`JiraBoard.swift:100`), allowlist внешних ссылок (`TargetQueries:200`), thread context (`MessageQueries:65`). Ни у одного нет кросс-языкового теста на эквивалентность. Верификация вскрыла две реальные расходимости: (1) Go `GetChannelValueSignals` (`internal/db/channel_stats.go:137,145`) читает `FROM targets`, а Swift-зеркало `ChannelStatsQueries.fetchValueSignals` — `FROM tasks` (таблицы нет → рантайм-сбой); (2) Swift `TargetQueries.updateStatus` (строка 217) опускает пересчёт progress листа/родителя, который Go `UpdateTargetStatus` (`targets.go:261`) выполняет — поэтому Desktop-путь «Done» оставляет progress устаревшим. Файлы инвентаря (`docs/inventory/`) каталогизируют эти контракты как load-bearing, удваивая радиус поражения каждого изменения.

```swift
// Mirrors the Go-side cascade in `UpdateTargetStatus`
// (internal/db/targets.go); Desktop "Done" bypasses Go, so the two
// paths must stay in sync (same dual-path convention as
// `CatchUpQueries.acknowledge`).
```

- **Рекомендация:** Для каждого «Mirrors Go» контракта добавить кросс-языковой золотой тест: фиксированный вход → сериализованный результат, проверяемый одинаково в `go test` и `swift test` (общий JSON-фикстур). Немедленно исправить расхождения `FROM tasks`→`FROM targets` и добавить недостающий пересчёт progress в Swift `updateStatus`.

### Стек AI-чата дублирован пятикратно: цикл dedup стрима скопирован 5×, блок LINKING RULES системного промпта — 4× (3 Swift + 1 Go)

- **Где:** `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift:8`
- **Статус верификации:** ✅ подтверждено
- Идентичный конечный автомат дедупликации стрима `sawTurnComplete`/`turnComplete` скопирован в `ChatViewModel` (дважды: строки 167 и 561), `OnboardingChatViewModel:277`, `TargetChatViewModel:223` и `TrackChatViewModel:166` — последний представляет собой полноценную ViewModel на ~380 строк, определённую внутри файла из `Views/` с собственными хелперами персистентности, дублирующими обработку `ChatMessageQueries`/`ChatConversationQueries`. Блок промпта `=== LINKING RULES ===` (формат slack://-ссылок) отдельно поддерживается в `ChatViewModel:454`, `TargetChatViewModel:564`, `TrackChatView.swift:351` и `internal/ai/prompt.go`. Дрейф, о котором предупреждает находка, уже реален: LINKING RULES в `ChatViewModel` («ALWAYS include Slack links as descriptive markdown», плоский формат сообщений) существенно отличается от `TrackChatView` («ALWAYS use markdown links with descriptive text», с отдельными правилами `thread_ts` и web-permalink), так что рекомендации по рендеру ссылок уже расходятся между вкладками. Фикс известного edge-case «chunk после turnComplete», добавление нового `AIStreamEvent`-кейса или смена формата deep-link требуют 4-5 синхронных правок в двух языках.

```swift
// TrackChatView.swift:166 — байт-в-байт совпадает с ChatViewModel:167 и :561,
// OnboardingChatViewModel:277, TargetChatViewModel:223
var sawTurnComplete = false
...
case .turnComplete(let text): fullText = text; sawTurnComplete = true
```

- **Рекомендация:** Вынести автомат дедупликации стрима в один общий тип (например `ChatStreamAccumulator`), а блок LINKING RULES — в единый источник (общий Swift-конструктор системного промпта + один Go-источник), из которого генерируются все чат-вкладки. `TrackChatViewModel` вынести из `Views/` в слой ViewModels и переиспользовать общие query-хелперы.

## Low

### Системное нарушение MVVM: множество прямых `dbPool.write` в файлах View; целые фичи реализованы внутри Views

- **Где:** `WatchtowerDesktop/Sources/Views/Calendar/MeetingNotesView.swift:457`
- **Статус верификации:** ✅ подтверждено
- Документированная архитектура проекта (`.claude/skills/add-desktop-feature`: Model → Queries → ViewModel → View, «writes via await dbPool.write» в ViewModel) нарушается повсеместно: grep показывает 90 упоминаний `dbPool` в `Sources/Views` по 30 файлам, включая синхронные `try db.dbPool.write` call-sites, исполняемые на main actor (UI подвисает, когда Go-демон держит write-lock, `busy_timeout=5000ms`). `MeetingNotesView` вообще не имеет ViewModel — CRUD заметок, toggle, delete и кросс-фичевое создание target (`TargetQueries.create` + `MeetingNoteQueries.setTaskID`) живут во View. Верификация уточнила: фактически 23 write-site (19 синхронных), а не 24, и два флагманских кейса «вся фича во View» частично мисхарактеризованы (`createTargetAndPromote` асинхронна и делегирует batch-promote канонической `TargetsViewModel`) — поэтому severity понижен до low. Тем не менее синхронная main-thread-запись до 5 с при удержании write-lock демоном реально достижима и обходит документированный паттерн.

```swift
private func createTask(from note: MeetingNote) {
    ...
    let taskID = try db.dbPool.write { dbConn in
        let id = try TargetQueries.create(dbConn, text: note.text, ...)
        try MeetingNoteQueries.setTaskID(dbConn, noteID: noteID, taskID: Int64(id))
        return id
    }  // бизнес-флоу + синхронная main-thread запись внутри SwiftUI View, без ViewModel
}
```

- **Рекомендация:** Перевести записи в Views на `await dbPool.write` (off-main) внутри соответствующих ViewModel; для `MeetingNotesView` создать `MeetingNotesViewModel`, инкапсулирующий CRUD и создание target. Как минимум — сделать все `dbPool.write` в Views асинхронными, чтобы убрать блокировку main actor.

### Фазы пайплайнов демона не изолированы от паник; паникующая горутина пайплайна убивает весь демон

- **Где:** `internal/daemon/daemon.go:233`
- **Статус верификации:** ✅ подтверждено
- `runSync` запускает `phaseTracksAndRollups` и `phasePeopleCards` в «голых» горутинах (`daemon.go:233-240`), а у `trackedPipelineRun` нет `recover()`; единственные `recover` в непроверочном бэкенде — вокруг вызова `TrackLinker` внутри `digest.Pipeline` (`pipeline.go:386`) и в CLI-горутине sync (`cmd/sync.go:391`), что доказывает: авторы знают о возможности паник, но собственные фазы демона не защищены. Паника в любой из этих горутин обрушит весь процесс (паники горутин в Go неперехватываемы родителем), необратимо остановив цикл sync (`Run`, строки 176/187/190) до ручного рестарта. Верификация опровергла конкретный «уже существующий триггер» (`usage.Model` — оба продакшн-генератора и оба mock всегда возвращают non-nil `*Usage`), поэтому это профилактическое усиление, а не живой краш — отсюда low.

```go
// daemon.go:233-240 — нет recover нигде в daemon.go
go func() { defer phasesWg.Done(); d.phaseTracksAndRollups(ctx) }()
```

- **Рекомендация:** Обернуть каждую фазу пайплайна (включая горутины) в `trackedPipelineRun` с `defer recover()`, логирующим стек и помечающим фазу как failed, чтобы паника одного пайплайна не валила цикл sync целиком.

### Токены дневного rollup нигде не учитываются: аккумулируются после закрытия строки прогона «digests», затем сбрасываются в следующем цикле

- **Где:** `internal/daemon/daemon.go:457`
- **Статус верификации:** ✅ подтверждено
- Демон записывает строку `pipeline_runs` «digests» из `Usage`, возвращённого `RunChannelDigestsOnly` (`phaseChannelDigests`, `daemon.go:378-395`). Позже в том же цикле `RunRollups` выполняет LLM-вызов дневного rollup, который аккумулируется во внутренние атомарные счётчики пайплайна digest (`accumulateUsage` через `runDailyRollupForDate`), но не возвращает usage демону и не атрибутируется ни к одной строке `pipeline_runs`. В следующем цикле `RunChannelDigestsOnly` сбрасывает счётчики (`pipeline.go:336-338`), стирая usage rollup целиком. Пользователь, аудирующий AI-расходы через `pipeline_runs` (ради чего эти строки и существуют — items/input_tokens/output_tokens/cost на прогон), видит потребление токенов дневного rollup как вечный ноль, хотя Sonnet-класс-вызов идёт каждый цикл со свежими дайджестами; учёт токенов систематически занижен.

```go
// daemon.go:456-460 — не обёрнуто в trackedPipelineRun, AccumulatedUsage не читается
if d.digestPipe != nil {
    if err := d.digestPipe.RunRollups(ctx); err != nil { d.logger.Printf("rollup error: %v", err) }
}
// digest/pipeline.go:335-338 — сброс аккумулятора в начале следующего прогона
// Reset accumulated usage from previous run ...
p.totalInputTokens.Store(0)
```

- **Рекомендация:** Обернуть `RunRollups` в `trackedPipelineRun` с собственной строкой `pipeline_runs` (например «daily-rollup») и читать её usage до сброса счётчиков — либо возвращать usage rollup из `RunRollups` и аккумулировать его в строку «digests» до её закрытия.

### Boilerplate учёта usage дублирован 6× с несогласованной семантикой (accumulated vs last-run, atomic vs plain int)

- **Где:** `internal/inbox/pipeline.go:180`
- **Статус верификации:** ✅ подтверждено
- Шесть пайплайнов реализуют собственный `AccumulatedUsage() (int,int,float64,int)` плюс сброс-при-Run и поля прогресса `LastStep*`: digest, tracks, guide используют `atomic.Int64`; inbox использует plain int, мутируемые в `aiPrioritizeNewItems` (безопасно лишь пока однопоточно — при этом его doc-комментарий всё ещё говорит «accumulated across all Generate calls», хотя он сбрасывается на каждый Run); briefing и dayplan молча возвращают usage только ПОСЛЕДНЕГО прогона под тем же именем метода. `float64` в сигнатуре — мёртвый вечно-0 `CostUSD`, копируемый в каждой реализации. Демон потребляет все шесть одинаково через `trackedPipelineRun`. Добавление отчётности по стоимости или cache-токенам (структура `Usage` уже несёт `TotalAPITokens`/`Model`) означает правку шести почти идентичных копий и их точек сброса; частичная правка даст смешанные метрики в `pipeline_runs` — ровно тот класс дрейфа, что уже есть между семантиками «accumulated» и «last-run».

```go
// inbox/pipeline.go:179-182 — контракт "accumulated", plain int
// AccumulatedUsage returns the total token usage accumulated across all Generate calls.
// briefing/pipeline.go:87-91 — то же имя, другой контракт
// AccumulatedUsage returns the token usage from the last Run call.
// digest/pipeline.go:184-186 — atomic-вариант
```

- **Рекомендация:** Вынести аккумуляцию usage в общий тип (usage-recorder) или в `PooledGenerator`, который уже видит каждый вызов и его source-тег, и переиспользовать его во всех пайплайнах — тогда семантика и тип станут едиными, а добавление cost/cache-метрик потребует одной правки.

### Инвариант каскада digest-read→decisions-read энфорсится в call-site в Swift, но инкапсулирован в Go — батч-`markRead` уже без него

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/DigestQueries.swift:88`
- **Статус верификации:** ✅ подтверждено
- Go-функция `MarkDigestRead` (`internal/db/digests.go:232`) внутренне каскадит `markDigestDecisionsRead`, так что ни один Go-вызывающий не может его забыть. Swift же расщепляет инвариант на две функции, которые каждый call-site обязан спаривать вручную — `TrackQueries.swift:113-114`, `CatchUpQueries.swift:80+85` (в комментарии которого признано «Mirrors the other markDigestRead call sites»), `DigestViewModel.swift:296+298` и `341+343`. Батч-`markRead(_:ids:)` на строке 88 уже опускает каскад; сейчас он не вызывается, но первый же будущий вызывающий (например тулбар-действие «mark all read», которое `DigestViewModel` сегодня реализует поштучным циклом) оставит decisions в непрочитанном счётчике Decisions-ленты — ровно тот баг, ради предотвращения которого существует Go-каскад (CATCHUP-01).

```swift
/// Marks multiple digests read in one write. No-op on empty input.
static func markRead(_ db: Database, ids: [Int]) throws {
    ... // UPDATE digests SET read_at = ... — нет каскада markAllDecisionsRead,
        // в отличие от Go MarkDigestRead, вызывающего db.markDigestDecisionsRead(id) внутри
}
```

- **Рекомендация:** Встроить каскад decisions-read внутрь `markRead(_:ids:)` (и любой другой Swift-функции пометки digest прочитанным), чтобы инвариант был инкапсулирован так же, как в Go, а не полагался на дисциплину call-site.

### Бейдж рекомендаций в сайдбаре считается с иными входами, чем экран Channels, на который он ведёт

- **Где:** `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift:140`
- **Статус верификации:** ✅ подтверждено
- `SidebarCountsViewModel` считает бейдж рекомендаций через `computeRecommendations(from: allStats)` с дефолтными `signals: [:]`, тогда как `ChannelStatsViewModel.load` считает список экрана через `computeRecommendations(from: allStats, signals: fetchValueSignals(db))`. Параметр `signals` добавляет рекомендации «high-value channel» (ветка `decisionCount >= 5 || activeTrackCount >= 2` в `ChannelStatsQueries.swift:153`), поэтому — как только починят баг с таблицей `fetchValueSignals` — число на бейдже перестанет совпадать с числом рекомендаций на экране. К тому же он заново прогоняет полную агрегацию `fetchAll` при каждом наблюдаемом изменении 7 таблиц ради вывода одного целого числа для бейджа.

```swift
let allStats = try ChannelStatsQueries.fetchAll(db, currentUserID: uid)
recCount = ChannelStatsQueries.computeRecommendations(from: allStats).count
// vs ChannelStatsViewModel.swift:68-69 — передаёт signals: fetchValueSignals(db)
```

- **Рекомендация:** Считать бейдж тем же вызовом с тем же `signals`, что и экран (вынести расчёт в общий метод/ViewModel), чтобы число бейджа и список экрана не расходились и порог рекомендаций тюнился в одном месте.

### `DatabaseManager` смешивает инфраструктуру с доменной логикой: CRUD starred channels/people продублирован 4× внутри менеджера соединений

- **Где:** `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:168`
- **Статус верификации:** ✅ подтверждено
- `DatabaseManager` (настройка пула, валидация схемы, subprocess CLI-миграций) содержит также четыре почти идентичных доменных метода — `addStarredChannel`/`removeStarredChannel`/`addStarredPerson`/`removeStarredPerson` — каждый вручную повторяет один и тот же round-trip fetch-JSON → decode → mutate → encode → UPDATE `user_profile`, вместо того чтобы жить в `ProfileQueries` рядом с остальным доступом к `user_profile`. `ProfileQueries` уже владеет теми же колонками `starred_channels`/`starred_people` и использует стандарт кодовой базы `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, тогда как `DatabaseManager` использует `ISO8601DateFormatter` — методы и не на месте, и несогласованны с конвенцией слоя. Добавление «starred people» TTL или третьего starred-списка означало бы пятую копию в неправильном слое.

```swift
func addStarredChannel(_ channelID: String, for userID: String) throws {
    try dbPool.write { db in
        let sql = "SELECT starred_channels FROM user_profile WHERE slack_user_id = ?"
        ... channels = (try? JSONDecoder().decode([String].self, from: data)) ?? [] ...
        // тот же блок повторён 4× внутри менеджера соединений
    }
}
```

- **Рекомендация:** Перенести четыре starred-метода в `ProfileQueries`, унифицировать формат `updated_at` на `strftime('%Y-%m-%dT%H:%M:%SZ','now')` и оставить `DatabaseManager` только инфраструктурным (пул, схема, миграции).
