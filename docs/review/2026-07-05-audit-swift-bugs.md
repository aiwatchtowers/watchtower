# Баги на стороне клиента (Swift) — аудит 2026-07-05

Аудит охватывает клиентский код macOS-приложения `WatchtowerDesktop/` (SwiftUI + GRDB): ViewModels, Queries, Services и утилиты. Метод — многоагентный поиск дефектов (finders `swift-data`, `swift-vm`, `swift-svc`) с последующей независимой состязательной верификацией каждой находки против реальной схемы БД, Go-кода-источника и семантики Swift Concurrency; опровергнутые находки удалены. Ниже 23 подтверждённых дефекта: 5 High, 9 Medium, 9 Low.

## High

### Экран Channels полностью сломан: `fetchValueSignals` обращается к удалённой таблице `tasks`

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift:190`
- **Статус верификации:** ✅ подтверждено

Таблица БД была переименована `tasks` → `targets` (в `schema.sql` и миграциях создаётся только `targets`; в живой БД таблицы/представления `tasks` нет). `fetchValueSignals` ссылается на `FROM tasks t` и в основном SQL (строки 190, 199), и в запасном SQL для случая отсутствия `digest_topics` (строки 237, 246), поэтому любой вызов бросает `no such table: tasks`. `ChannelStatsViewModel.load()` (строки 61–77) вызывает `fetchAll` и `fetchValueSignals` внутри одного `do/catch`, поэтому исключение обнуляет весь результат: `stats=[]`, `recommendations=[]`, выставляется `errorMessage` — при каждом открытии экран Channel Stats показывает ошибку вместо данных. Аналогичный Go-код `GetChannelValueSignals` в `channel_stats.go` уже использует корректное `FROM targets t`, что подтверждает: Swift-зеркало устарело.

```sql
task_via_digest AS (
    SELECT d.channel_id, COUNT(*) AS cnt
    FROM tasks t
    JOIN digests d ON t.source_type = 'digest' ...
)
```

- **Рекомендация:** Заменить `FROM tasks t` на `FROM targets t` во всех четырёх местах (строки 190, 199, 237, 246) и сверить имена колонок с актуальной схемой `targets`. Разумно добавить guard-тест, сверяющий имена таблиц в Swift-запросах со схемой, чтобы будущие переименования ловились на CI.

### Отметка «done/pending» для задачных пунктов Day Plan всегда падает: каскад пишет в удалённую таблицу `tasks`

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/DayPlanQueries.swift:182`
- **Статус верификации:** ✅ подтверждено

`cascadeTaskStatus` выполняет `UPDATE tasks SET status = ...`, но таблица теперь `targets`. `DayPlanViewModel.markDone/markPending` передают `cascadeToTask: item.sourceType == .task`, поэтому для каждого пункта с источником-задачей (самый частый вид — 303 из 718 строк в живой БД) statement бросает `no such table: tasks` внутри `dbPool.write`, откатывая и собственное обновление статуса пункта. Результат: чекбокс Done на задачных пунктах дневного плана не делает ничего, кроме установки `generationError`.

```swift
try db.execute(sql: """
    UPDATE tasks
    SET status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE id = ?
    """, arguments: [taskStatus, taskId])
```

- **Рекомендация:** Заменить `UPDATE tasks` на `UPDATE targets` (сравните с корректным `TargetQueries`, который уже пишет в `targets`). Проверить остальные каскадные запросы в файле на тот же устаревший идентификатор.

### Функция «Wipe LLM data» полностью неработоспособна: `DELETE FROM tasks` откатывает всю транзакцию

- **Где:** `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:116`
- **Статус верификации:** ✅ подтверждено

`wipeLLMData` выполняет все `DELETE` в одной транзакции `dbPool.write` и включает `DELETE FROM tasks`. Поскольку таблицы больше нет, statement бросает исключение, и GRDB откатывает все предыдущие удаления (`digests`, `tracks`, `briefings`, `inbox_items`, …). `AppState.resetLLMData()` (`try db.wipeLLMData()`) затем перебрасывает ошибку — действие пользователя «Reset AI data» останавливает даемоны, ничего не стирает и завершается с ошибкой. Хуже того, `resetLLMData` останавливает даемон/пайплайны до броска и никогда не доходит до перезапуска, оставляя даемон остановленным. `tasks` — единственная несуществующая таблица среди 17 в `wipeLLMData`.

```swift
// Tasks & Inbox
try db.execute(sql: "DELETE FROM tasks")
try db.execute(sql: "DELETE FROM inbox_items")
```

- **Рекомендация:** Заменить `DELETE FROM tasks` на `DELETE FROM targets`. Дополнительно обернуть перезапуск даемона в `defer`/`do-catch`, чтобы сбой любого `DELETE` не оставлял даемон навсегда остановленным.

### `ConfigService.save()` пишет устаревший YAML-снимок, затирая конфиг от CLI-логинов (секция Jira стирается)

- **Где:** `WatchtowerDesktop/Sources/Services/ConfigService.swift:122`
- **Статус верификации:** ✅ подтверждено

`save()` сериализует `rawYAML`, который обновляется только через `reload()` (при init или по кнопке Reload). Go-CLI тоже пишет `config.yaml`: `watchtower jira login` сохраняет `jira.cloud_id/site_url/user_display_name/enabled` через `writeConfigAtomic` (`cmd/jira.go:296-305`), а `auth` переписывает Slack-токен. В той же панели Settings (`GeneralSettings` держит один `@State private var config = ConfigService()`, а `jiraAuth.connect()` запускает `jira login`) пользователь может: открыть Settings → Connect Jira (CLI пишет `jira.*` в `config.yaml`) → изменить любую настройку → нажать Save. `save()` сериализует до-логиновый `rawYAML`, удаляя всю секцию `jira`, после чего `jira boards`/`jira sync` не находят `cloud_id` и интеграция молча ломается. Путь Slack-reconnect вызывает `config.reload()` после (`SettingsView.swift:732`), но пути Jira и Google — нет, и сам `save()` никогда не перечитывает и не мёрджит файл с диска перед записью.

```swift
func save() throws {
    var yaml = rawYAML
    ...
    try output.write(toFile: configPath, atomically: true, encoding: .utf8)
    ...
    rawYAML = yaml
}
```

- **Рекомендация:** В `save()` перечитывать `config.yaml` с диска непосредственно перед сериализацией (либо мёрджить только изменённые ключи вместо переписывания всего снимка), чтобы записи от CLI-логинов не терялись. Как минимум — вызывать `reload()` после каждого `connect()` (Jira, Google, Slack), а не только для Slack.

### `BackgroundTaskManager`: сбой пайплайна digests навсегда оставляет tracks/people в «Waiting…» и блокирует запуск даемона на всю сессию

- **Где:** `WatchtowerDesktop/Sources/Services/BackgroundTaskManager.swift:207`
- **Статус верификации:** ✅ подтверждено

В `startPipelines()`, если пайплайн digests завершается ненулевым кодом (частая ситуация при онбординге: `claude` CLI не залогинен, ошибка AI), оркестрирующий `Task` рано выходит на `guard tasks[.digests]?.status == .done else { return }`. Последствия: (1) tracks и people навсегда остаются `.pending` — сайдбар показывает «Waiting…» без кнопки Retry (`SidebarProgressView.swift:87` рендерит pending без действия); (2) `pipelineTask` никогда не сбрасывается в `nil` (это происходит только в конце успешного пути, строка 227), поэтому `guard pipelineTask == nil` на строке 189 блокирует любой будущий вызов `startPipelines()` до конца сессии; (3) даже если пользователь нажмёт Retry на digests и тот пройдёт, `retry()` стартует даемон только `if allFinished` — а это false, пока tracks/people в `.pending` — так что фаза 2 не запускается и `sync --daemon --detach` не стартует, то есть фонового синка нет вообще; (4) `pipelinesCompletedKey` не выставляется, поэтому весь (дорогой) набор пайплайнов запускается с нуля при следующем старте. Единственное восстановление — перезапуск приложения, но это неочевидно пользователю.

```swift
await runTask(.digests)
guard !Task.isCancelled else { return }
// Only proceed if digests succeeded.
guard tasks[.digests]?.status == .done else { return }
```

- **Рекомендация:** При сбое digests всё равно сбрасывать `pipelineTask = nil` (через `defer`) и переводить зависимые пайплайны в состояние с кнопкой Retry, а не оставлять `.pending`. Логику старта даемона отвязать от `allFinished` — запускать фоновый синк независимо от исхода необязательных пайплайнов, чтобы онбординговый сбой AI не лишал приложение его основной функции.

## Medium

### Среднее время цикла Jira всегда 0: `julianday()` не парсит Jira-таймстемпы формата `+HHMM`

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/JiraQueries.swift:472`
- **Статус верификации:** ✅ подтверждено

Go-синк сохраняет `jira_issues.created_at/resolved_at` дословно из Jira API (`CreatedAt: f.Created` в `internal/jira/sync.go:535`), т.е. `'2025-10-14T09:11:12.903+0100'`. SQLite date-функции принимают `+01:00` или `Z`, но НЕ `+0100`, поэтому `julianday()` возвращает NULL для каждой реальной строки. `AVG(julianday(resolved_at) - julianday(created_at))` в `fetchDeliveryStats` всегда NULL → 0.0, а `avg_cycle_time_days` в `fetchTeamWorkload` (строка 587) = 0 для каждого исполнителя. `PersonDetailView` и экран Workload постоянно показывают цикл в 0 дней. Тот же баг есть и в Go (`jira_dashboards.go`).

```sql
SELECT AVG(julianday(resolved_at) - julianday(created_at)) ...
-- julianday('2025-10-14T09:11:12.903+0100') -> NULL
```

- **Рекомендация:** Нормализовать таймстемпы в формат, понятный SQLite. Правильнее всего — исправить источник (Go-синк нормализует `+0100` → `+01:00` при записи в БД), иначе на стороне Swift нормализовать в запросе (вставка двоеточия в offset через `substr`) перед `julianday()`. Чинить симметрично в Go и Swift.

### Кнопка Stop дважды сохраняет сообщение ассистента: `cancelStream()` и эпилог stream-таска оба вставляют частичный ответ

- **Где:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:199`
- **Статус верификации:** ✅ подтверждено

Пользователь отправляет сообщение, текст начинает стримиться, затем нажимает Stop (или переключает провайдера / привязывает другую беседу / удаляет чат посреди стрима — всё вызывает `cancelStream`). `cancelStream()` сохраняет частичный текст ассистента через `persistMessage` (строка 256). Всё ещё работающий `streamTask` затем выходит из `for-await` и безусловно выполняет эпилог (строки 198–204), который находится ВНЕ `do/catch` и не проверяет `Task.isCancelled` — он срабатывает на обоих путях отмены (итератор вернул `nil` или бросил) — и сохраняет тот же накопленный `fullText` второй раз через `persistResponseStatic`. Итог: две одинаковых строки ассистента в `chat_messages`. `ChatMessageQueries.insert` — голый INSERT без dedup/unique-ограничения, а `startMessageObservation` перезагружает дубликат в UI навсегда. Тот же паттерн — в `sendWelcomeMessage` (строки 592–597).

```swift
// cancelStream():
if !partialText.isEmpty, let convID = conversationID {
    persistMessage(conversationID: convID, role: "assistant", text: partialText)
}
// streamTask epilogue (after catch), always runs:
if !fullText.isEmpty, let convID = capturedConvID {
    Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText)
}
```

- **Рекомендация:** В эпилоге сохранять ответ только если `cancelStream` этого ещё не сделал — например, проверять `Task.isCancelled` перед `persistResponseStatic` или ввести флаг «уже сохранено». То же исправление применить к `sendWelcomeMessage`.

### `TargetChatViewModel` парсит action-предложения из отменённого/обрезанного стрима (`streamFailed` не выставляется при отмене) и дважды сохраняет частичный ответ

- **Где:** `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift:253`
- **Статус верификации:** ✅ подтверждено

Собственный комментарий кода гласит: «On a failed/cancelled stream, do NOT parse actions out of partial, possibly-truncated output». Но `streamFailed` выставляется только внутри `catch` (строка 245). Когда пользователь жмёт Stop (`cancelStream → streamTask?.cancel()`), `AsyncThrowingStream` завершает итерацию возвратом `nil` из `next()` — он не бросает — поэтому `for-await` выходит нормально, `streamFailed` остаётся `false`, и `executeStream` доходит до `TargetActionParser.parse(fullText)` на обрезанном выводе (строка 259). Обрезанный блок ` ```watchtower-action ` может всплыть как наполовину сформированная карточка действия, которую пользователь может одобрить, либо породить ложные системные сообщения `⚠️ Invalid action proposal`, которые сохраняются. Дополнительно `cancelStream` (строки 378–384) сохраняет частичный текст ассистента, а эпилог сохраняет `displayText` снова (строки 277–279) — дубликаты строк в беседе таргета.

```swift
} catch {
    streamFailed = true
    ...
}
// On a failed/cancelled stream, do NOT parse actions out of partial output ...
if streamFailed { finishStream(); return }
let parsed = TargetActionParser.parse(fullText)  // reached on cancellation
```

- **Рекомендация:** Проверять `Task.isCancelled` (или устанавливать `streamFailed = true` при отмене) перед guard'ом на строке 253, чтобы парсинг действий не выполнялся на обрезанном выводе. Заодно устранить двойное сохранение, как в `ChatViewModel`.

### Сбои синка Jira-борда полностью беззвучны: exit code 0 при ошибке, JSON ошибки и свойство `error` нигде не показываются

- **Где:** `WatchtowerDesktop/Sources/Services/JiraBoardSyncManager.swift:92`
- **Статус верификации:** ✅ подтверждено

`runSyncProcess()` определяет сбой только по `proc.terminationStatus != 0`. Но Go в режиме `--progress-json` для одного борда эмитит `{"pipeline":"jira-sync","finished":true,"error":...}` и затем `return nil` (`cmd/jira.go:712-716`), то есть выходит со статусом 0 при ошибке синка. Swift-колбэк прогресса делает только `self?.progress = json` и никогда не смотрит на `json.error`; после цикла `startSync()` выставляет `progress = nil`, а `error` остаётся `nil`. Вдобавок единственная потребляющая вью (`JiraBoardsSettingsView.swift`) вообще не рендерит `syncManager.error`. Итог: при сбое синка борда (истёкший токен Jira, ошибка API) спиннер просто исчезает, и пользователь не получает никакого сигнала — борд выглядит синхронизированным, но данных нет/они устарели.

```swift
if proc.terminationStatus != 0 {
    ...
    return stderr.isEmpty ? "Sync failed" : String(stderr.prefix(200))
}
return nil
// Go cmd/jira.go:713: json.Marshal(jiraSyncProgressJSON{... Error: err.Error()}); return nil  // exit 0
```

- **Рекомендация:** В колбэке прогресса проверять `json.error` и выставлять `self.error`, а `JiraBoardsSettingsView` должна рендерить `syncManager.error`. Либо изменить Go так, чтобы single-board режим возвращал ненулевой exit code при ошибке.

### Детекция «застрявших» задач в Blocker Map никогда не вернёт строк (пустая колонка-источник + формат, непарсимый `julianday`)

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/JiraQueries.swift:692`
- **Статус верификации:** ✅ подтверждено

`fetchStaleIssues` фильтрует по `status_category_changed_at != '' AND julianday('now') - julianday(status_category_changed_at) > ?`. Go-синк жёстко проставляет эту колонку в `''` для каждой задачи (`internal/jira/sync.go:503`: `statusCatChanged := ""` с комментарием «Jira API doesn't expose this directly»; в живой БД 0 из 1165 задач непустые), поэтому первое условие исключает всё; и даже будь колонка заполнена в нативном Jira-формате `+HHMM`, `julianday()` вернул бы NULL. `BlockerMapViewModel` (строка 78) поэтому всегда рендерит пустую секцию «stale issues» — фича молча мертва (при этом секция blocked issues работает).

```sql
WHERE status_category = 'in_progress'
  AND status_category_changed_at != ''
  AND julianday('now') - julianday(status_category_changed_at) > ?
-- SELECT COUNT(*), SUM(status_category_changed_at != '') FROM jira_issues -> 1165|0
```

- **Рекомендация:** Исправить источник — заполнять `status_category_changed_at` из Jira changelog (или другого доступного поля) в Go-синке и нормализовать таймстемп для `julianday`. Пока источник пуст, стоит хотя бы убрать/пометить неработающую секцию в UI, чтобы она не создавала ложное впечатление «застрявших задач нет».

### `generateBriefing` вызывает `waitUntilExit` до вычитывания stderr-пайпа — дедлок и вечное `isGenerating`, если CLI пишет >64KB в stderr

- **Где:** `WatchtowerDesktop/Sources/ViewModels/BriefingViewModel.swift:131`
- **Статус верификации:** ✅ подтверждено

Тело `Task.detached` выполняет `try process.run(); process.waitUntilExit()` и только потом читает stderr до EOF (строка 133). `watchtower briefing generate` прогоняет полный AI-пайплайн брифинга, и Go-логи идут в stderr; если ребёнок пишет больше ~64KB (размер буфера пайпа), он блокируется в `write(2)`, никогда не завершается, и `waitUntilExit` виснет навсегда. `MainActor.run`, сбрасывающий `isGenerating`, не выполняется, поэтому спиннер UI застревает навсегда (до перезапуска), и пользователь не может запустить новую генерацию. `CatchUpViewModel.runCLIBlocking` в этом же коде документирует ровно этот hazard и дренирует оба пайпа конкурентно до `waitUntilExit` — этот call-site пропустил тот фикс.

```swift
try process.run()
process.waitUntilExit()
let errData = stderr.fileHandleForReading.readDataToEndOfFile()  // read AFTER waitUntilExit
```

- **Рекомендация:** Дренировать stderr (и stdout) в отдельной задаче/потоке ДО `waitUntilExit`, как это уже сделано в `CatchUpViewModel.runCLIBlocking`. Вынести логику в общий хелпер, чтобы устранить дублирование антипаттерна.

### Системная утечка ValueObservation-тасков: ViewModel-и, создаваемые при каждом заходе на вкладку, стартуют observation-таски, которые никогда не отменяются

- **Где:** `WatchtowerDesktop/Sources/ViewModels/TracksViewModel.swift:76`
- **Статус верификации:** ✅ подтверждено

`TracksViewModel`, `TargetsViewModel` (`startObserving`, строка 39), `DigestViewModel` (строка 77), `BriefingViewModel` (строка 32), `PeopleViewModel` (строка 32), `DashboardViewModel` (строка 27), `BlockerMapViewModel` (строка 57) и `TargetChatViewModel` (observationTask в init, строка 102) не предоставляют никакого API отмены и не имеют `deinit`; их вью держат их в `@State` и пересоздают при каждом заходе на вкладку. Каждый заход поэтому утекает один вечно живущий `for-await`-таск ValueObservation (последовательность никогда не завершается, а таск никто не отменяет), который перезапускает свой запрос при каждом коммите в наблюдаемую таблицу с `nil weak self`. `UserStatsViewModel/ChannelStatsViewModel/WorkloadViewModel/EpicProgressViewModel` определяют `stopObserving()`, но её вызывают только `ProjectMapView` и `ReleaseDashboardView` — остальные утекают так же. Проект знает правильный паттерн — `CustomTrackTimelineViewModel.stop()` документирует «Call from the view's onDisappear … since a @MainActor deinit cannot touch the task».

```swift
observationTask = Task { [weak self] in
    let observation = ValueObservation.tracking { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
    }
    ...
}  // TracksViewModel has no stop()/deinit
```

- **Рекомендация:** Добавить каждому таб-уровневому VM метод `stopObserving()`, отменяющий `observationTask`, и вызывать его из `.onDisappear` соответствующей вью (по образцу `CustomTrackTimelineViewModel.stop()` / `TrackDetailView`). Долгосрочно — вынести обёртку наблюдения в базовый класс/хелпер с гарантированной отменой.

### `ProcessCLIRunner` читает stdout до EOF раньше stderr и блокирует поток кооперативного пула на всё время подпроцесса (дедлок, если ребёнок заполнит stderr)

- **Где:** `WatchtowerDesktop/Sources/Services/CLIRunner.swift:67`
- **Статус верификации:** ✅ подтверждено

`run(args:)` — `async`-метод без точек приостановки: `readDataToEndOfFile()` на stdout, затем на stderr, затем `waitUntilExit()` — всё синхронно на потоке кооперативного пула Swift Concurrency. Две проблемы: (1) пайпы дренируются последовательно — если ребёнок пишет ≥64KB в stderr, пока stdout ещё открыт (например, многословные предупреждения/дампы от долгой AI-команды), ребёнок блокируется на полном stderr-пайпе, не закрывает stdout, и `readDataToEndOfFile(stdout)` не возвращается: вечный дедлок и навсегда потерянный поток пула (комментарий кода утверждает, что дедлок исправлен, но исправлена лишь половина read-before-wait); (2) даже на happy path многоминутные подпроцессы (`TrackScanService` — «a scan runs for minutes», `targets extract`/meeting recap — многосекундные AI-вызовы) пиннят по одному потоку пула (ширина пула == число ядер) на всё время, так что горстка параллельных CLI-операций может застопорить всю async-работу. `GoogleAuthService.runProcess` (139–141) и `JiraAuthService.runProcess` (159–163) — тот же последовательно-дренирующий паттерн.

```swift
// Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds 64 KB.
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()   // all blocking, inside `func run(args:) async`
```

- **Рекомендация:** Дренировать stdout и stderr конкурентно (два `Task.detached`/`DispatchQueue`), а всю блокирующую работу вынести из кооперативного пула через `Task.detached` (как в `WatchtowerAIService`). Применить тот же фикс к `GoogleAuthService.runProcess` и `JiraAuthService.runProcess`.

### Счётчики бейджа overdue/dueToday для Targets считаются локальным настенным временем против UTC-дат; date-only цели «на сегодня» считаются просроченными

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:129`
- **Статус верификации:** ✅ подтверждено

`fetchCounts` сравнивает `due_date` с `nowDatetimeString()`/`todayDateString()`, которые используют `DateFormatter` с ЛОКАЛЬНЫМ часовым поясом, тогда как due-даты хранятся в UTC (Go: `internal/db/targets.go:338` `time.Now().UTC().Format("2006-01-02T15:04")`; `Target.swift` явно предупреждает «never parse/format it in the local zone»). Два конкретных сбоя: (1) для любого не-UTC пользователя цель со сроком, скажем, 21:00Z сегодня считается просроченной на часы раньше/позже локального смещения, расходясь с `Target.isOverdue`, который используют строки списка; (2) для ВСЕХ пользователей date-only due-дата, равная сегодня (в живой БД есть `'2026-07-04'`, `'2026-07-06'`), удовлетворяет `due_date < '<today>T14:30'` лексикографически, поэтому цель просто «на сегодня» дважды считается и overdue, и dueToday — бейдж сайдбара (`SidebarCountsViewModel.overdueTaskCount`) краснеет с N overdue, тогда как список Targets показывает ноль просроченных.

```swift
let now = nowDatetimeString()
... AND due_date != '' AND due_date < ?
// nowDatetimeString() = DateFormatter("yyyy-MM-dd'T'HH:mm"), no timeZone set (local)
// vs Go writing/comparing time.Now().UTC(); Target.isOverdue uses todayUTCDayString()
```

- **Рекомендация:** Задавать `timeZone = TimeZone(identifier: "UTC")` в форматтерах `nowDatetimeString()`/`todayDateString()` (или использовать те же UTC-хелперы, что и `Target.isOverdue`). Отдельно обработать date-only due-даты, чтобы «сегодня» не попадало в overdue — сравнивать по дню, а не лексикографическим префиксом datetime.

## Low

### `InboxViewModel` утекает вечный 30-секундный poll-цикл и ValueObservation-таск при каждом заходе на вкладку Inbox — пути остановки нет

- **Где:** `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift:110`
- **Статус верификации:** ✅ подтверждено

`InboxFeedView` держит VM в `@State` и создаёт свежий `InboxViewModel` + `startObserving()` при каждом появлении вкладки Inbox (`InboxFeedView.swift:121-126`); `switch` в `Navigation.swift` уничтожает вью (и освобождает VM) при смене вкладки. Но `pollTask` (цикл `while !Task.isCancelled { Task.sleep(30s); self?.load() }`) и `observationTask` (`for-await` над бесконечным ValueObservation `COUNT(*) FROM inbox_items`) никогда не отменяются: нет `stopObserving()`, нет `deinit`, нет вызова остановки со стороны вью. Неструктурированный `Task` не отменяется при сбросе последней ссылки, поэтому каждый заход утекает один вечный 30-секундный таймер и одно наблюдение, выполняющее COUNT-запрос при каждом коммите в `inbox_items` до конца жизни приложения. За день переключений вкладок накапливаются десятки зомби-наблюдений и таймеров, работающих с `nil weak self`.

```swift
pollTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { break }
        self?.load()
    }
}  // no cancel() call anywhere
```

- **Рекомендация:** Добавить `stopObserving()`, отменяющий `pollTask` и `observationTask`, и вызывать его из `.onDisappear` `InboxFeedView` (см. паттерн `CustomTrackTimelineViewModel.stop()`). Часть той же системной проблемы, что и находка о ValueObservation-утечках.

### `PeopleViewModel.load()` всегда сбрасывает данные на новейшее окно, но оставляет `selectedWindow`/label на выборе пользователя — устаревшее рассогласованное состояние после любой записи в `people_cards`

- **Где:** `WatchtowerDesktop/Sources/ViewModels/PeopleViewModel.swift:67`
- **Статус верификации:** ✅ подтверждено

`loadWindow(at:)` даёт пользователю листать историческое окно (ставит `selectedWindow` и грузит карточки этого окна). Но `load()` — переинициируемый observation'ом `people_cards` COUNT всякий раз, когда даемонский people-пайплайн пишет карточку — безусловно берёт `windows.first` (новейшее окно) для карточек, summary и interactions, не сбрасывая `selectedWindow` в 0. Сценарий: пользователь выбрал окно с индексом 2 в пикере; даемон завершает people-прогон; observation срабатывает `load()`; список показывает карточки НОВЕЙШЕГО окна, тогда как пикер по-прежнему показывает старое, а `currentWindowLabel` (вычисляемый из `availableWindows[selectedWindow]`) рендерит старый диапазон дат — UI молча показывает данные под неправильной меткой.

```swift
if let window = windows.first {
    cards = try PeopleCardQueries.fetchForWindow(db, from: window.from, to: window.to)
    ...
}
// selectedWindow never reset in load(); currentWindowLabel still reads availableWindows[selectedWindow]
```

- **Рекомендация:** В `load()` либо сбрасывать `selectedWindow = 0` (если задумано всегда показывать новейшее окно), либо, наоборот, уважать текущий `selectedWindow` и грузить именно его окно, чтобы данные и метка не расходились.

### `DaemonManager.stopDaemon()` молча ничего не делает при неразрешённом пути — шаг «Stop daemon» в `UpdateService.install` фактически не останавливает даемон

- **Где:** `WatchtowerDesktop/Sources/Services/DaemonManager.swift:65`
- **Статус верификации:** ✅ подтверждено

`startDaemon()` сначала вызывает `resolvePathIfNeeded()`, а `stopDaemon()` — нет: он просто `guard let path = watchtowerPath else { return }` и молча выходит, если путь не был разрешён. `UpdateService.install(daemonManager:)` (`UpdateService.swift:136`) получает свежий `@State private var daemonManager = DaemonManager()` из `GeneralSettings` (`SettingsView.swift:41`); ничто в `GeneralSettings` не вызывает на нём `resolvePathIfNeeded/startPolling/startDaemon`, поэтому `watchtowerPath` = nil и `await daemonManager.stopDaemon()` — гарантированный no-op. Обновление затем делает `rm -rf` и заменяет `.app`, пока старый даемон (запущенный из удаляемого бандла) продолжает работать и писать в БД — явный шаг install «1. Stop daemon» не происходит. Чистится это лишь позже, когда `ensureDaemonRunning()` при следующем запуске сделает stop/start. БД в WAL-режиме и вне бандла, так что порчи данных нет.

```swift
func stopDaemon() async {
    guard let path = watchtowerPath else { return }   // no resolvePathIfNeeded(), unlike startDaemon()
// UpdateService.swift:136  await daemonManager.stopDaemon()  // fresh DaemonManager -> watchtowerPath == nil -> no-op
```

- **Рекомендация:** Добавить `await resolvePathIfNeeded()` в начало `stopDaemon()` (симметрично `startDaemon()`), чтобы шаг остановки перед заменой бандла действительно срабатывал. Однострочный фикс.

### Тумблер «Daily summary notifications» мёртв — уведомления брифинга приходят независимо от `notifyDailySummary`

- **Где:** `WatchtowerDesktop/Sources/Services/DigestWatcher.swift:102`
- **Статус верификации:** ✅ подтверждено

`NotificationSettings` даёт ровно два тумблера типов: «Decision notifications» (`notifyDecisions`) и «Daily summary notifications» (`notifyDailySummary`, по умолчанию true). `DigestWatcher.poll()` гейтит блок решений на `notifyDecisions` (строки 60–63), но блок уведомлений брифинга (строки 98–113) вызывает `sendBriefingNotification` для каждого нового брифинга вообще без проверки настройки — `notifyDailySummary` не читается нигде в коде (grep подтверждает: только объявление `@AppStorage` и `Toggle` в `NotificationSettings.swift`). Пользователь, выключивший «Daily summary notifications», всё равно каждый день получает «Morning Briefing Ready»; тумблер ни на что не влияет.

```swift
for briefing in newBriefings {
    notificationService.sendBriefingNotification(
        attentionCount: briefing.parsedAttention.count
    )   // no notifyDailySummary / preference check
}
```

- **Рекомендация:** Обернуть цикл уведомлений брифинга в проверку `@AppStorage("notifyDailySummary")`, симметрично гейту `notifyDecisions` для блока решений.

### `SearchViewModel`: отменённый search-таск может перезаписать более новые результаты и убрать спиннер посреди поиска (нет проверки отмены после debounce/read)

- **Где:** `WatchtowerDesktop/Sources/ViewModels/SearchViewModel.swift:43`
- **Статус верификации:** ✅ подтверждено

`search()` отменяет предыдущий таск, но старый таск замечает отмену только через бросающий `Task.sleep`. Если старый таск уже прошёл sleep и находится внутри `dbPool.read`, когда пользователь снова печатает, перед `self.results = ...` и `self.isSearching = false` нет проверки `isCancelled`. Если read более старого (обычно более дорогого) запроса завершится после присваивания более нового — реалистично, когда прошлый запрос совпадает со многими FTS-строками, а новый дешёв — UI покажет результаты для устаревшего текста запроса. Старый таск также безусловно ставит `isSearching = false` в конце, скрывая индикатор прогресса, пока новый поиск ещё идёт.

```swift
self.results = try await dbManager.dbPool.read { db in try SearchQueries.search(db, query: trimmed) }
...
self.isSearching = false  // no Task.isCancelled guard around either assignment
```

- **Рекомендация:** После `dbPool.read` и перед присваиванием `results`/`isSearching` добавить `guard !Task.isCancelled else { return }` (либо сверять, что `trimmed` всё ещё соответствует текущему тексту запроса).

### `PipelineHistoryViewModel.loadRuns`: неупорядоченные `Task.detached`-загрузки позволяют результатам устаревшего дня прийти после более нового при быстрой навигации

- **Где:** `WatchtowerDesktop/Sources/ViewModels/PipelineHistoryViewModel.swift:47`
- **Статус верификации:** ✅ подтверждено

`goToPreviousDay/goToNextDay` вызывают `loadRuns()`, который захватывает дату и спавнит независимый `Task.detached`; нет отмены предыдущей загрузки и нет проверки `date == selectedDate` перед присваиванием. Быстрые клики prev/next (каждый — отдельный fetch) могут привести к тому, что более медленный запрос раннего дня разрешится последним, и `runs` покажет прогоны дня N-2, пока `selectedDate`/заголовок показывают день N-1. `isLoading` также сбрасывается тем таском, что завершился первым, пока другой ещё в полёте.

```swift
let date = selectedDate
Task.detached {
    let result = try? await dbPool.read { db in try PipelineRunQueries.fetchByDate(db, on: date) }
    await MainActor.run {
        self.runs = result ?? []  // no guard that `date` still equals self.selectedDate
```

- **Рекомендация:** Перед присваиванием `runs` проверять `guard date == self.selectedDate else { return }`, а также отменять предыдущий load при новой навигации.

### Каталоги версий Node сортируются лексикографически — старые версии nvm/fnm (v9.x) выигрывают у новых (v18+/v22)

- **Где:** `WatchtowerDesktop/Sources/Utilities/Constants.swift:88`
- **Статус верификации:** ✅ подтверждено

`searchNodeVersions` (используется `findInPath` для поиска бинарей claude/codex) и встроенная копия в `resolvedEnvironment` (строка 137) выбирают «последнюю» версию node через `versions.sorted().reversed()`, что является строковой сортировкой: `"v9.11.2" > "v22.1.0" > "v18.20.0"` лексикографически. Пользователь со старым nvm (эпохи v9/v8) рядом с текущим node получит путь бинаря claude из — и PATH с префиксом — древней версии node; если claude (тоже) установлен под той версией, он запустится против неподдерживаемого runtime и упадёт. Требуется установка claude/codex под ОБЕИМИ версиями (древней <v10 и современной), что делает сценарий узким.

```swift
for ver in versions.sorted().reversed() {   // lexicographic: "v9..." sorts after "v22..."
    for sub in ["bin", "installation/bin"] {
        let path = "\(dir)/\(ver)/\(sub)/\(binary)"
```

- **Рекомендация:** Сортировать версии семантически (парсить major/minor/patch как числа, например через `compare(options: .numeric)` или разбор компонентов), а не строковым `sorted()`. Исправить в обоих call-site (строки 88 и 137).

### `Constants.resolvedEnvironment()` синхронно запускает login-shell при первом вызове — до 5 сек фриза главного потока у `@MainActor`-вызывающих

- **Где:** `WatchtowerDesktop/Sources/Utilities/Constants.swift:121`
- **Статус верификации:** ✅ подтверждено

Кешированное окружение вычисляется лениво при первом обращении спавном `$SHELL -lc "echo $PATH"` и синхронным `pathProc.waitUntilExit()` с 5-секундным kill-таймером. Некоторые первые вызывающие — на главном акторе: `GoogleAuthService.connect()` (строка 31) и `JiraAuthService.connect()` (строка 33) ставят `process.environment = Constants.resolvedEnvironment()` внутри `@MainActor`-методов до `detach`. При медленном `~/.zshrc`/nvm-init (частый случай 1–3 сек, до 5 сек таймаута для сломанных конфигов) первый клик по «Connect» подвесит UI на это время. На практике фриз обычно предотвращается: `AppState` при старте вызывает `runCLIMigrations()` в `Task.detached`, который прогревает кеш вне главного потока.

```swift
pathProc.arguments = ["-lc", "echo $PATH"]
...
pathProc.waitUntilExit()   // synchronous; first call may be on MainActor (GoogleAuthService.connect line 31)
```

- **Рекомендация:** Сделать `resolvedEnvironment()` `async` или гарантированно прогревать кеш в фоне до появления UI, а `@MainActor`-вызывающим (`connect()`) получать окружение через `await` вне главного потока.

### `DigestWatcher.poll()` делает синхронные GRDB-чтения на главном акторе каждые 60 секунд

- **Где:** `WatchtowerDesktop/Sources/Services/DigestWatcher.swift:69`
- **Статус верификации:** ✅ подтверждено

`DigestWatcher` — `@MainActor`, и `poll()` выполняется на главном акторе через watch-`Task`; он вызывает синхронный `dbPool.read { ... }` (fetch digests, fetch briefings плюс per-digest lookups канала/пользователя в `resolveChannelName`) напрямую. Каждый 60-секундный тик блокирует главный поток на время SQLite-чтений; на большой БД или пока Go-даемон держит writer во время тяжёлого синка это даёт периодические подтормаживания UI. Остальное приложение использует `ValueObservation` или async-чтения для той же БД. На практике стойл обычно субмиллисекундный (индексированный `id>N` запрос, в устойчивом состоянии 0 строк).

```swift
private func poll() {
    ...
    let newDigests = try dbPool.read { db in      // sync read on MainActor
        try DigestQueries.fetchNewSince(db, afterID: lastCheckedDigestID)
    }
```

- **Рекомендация:** Заменить синхронный `dbPool.read` на `await dbPool.read` (async-вариант) внутри `poll()`, либо перевести polling на `ValueObservation`, как в остальном приложении, чтобы не трогать SQLite на главном потоке.
