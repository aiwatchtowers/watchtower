# Баги UI (состояние не отражается в интерфейсе) — аудит 2026-07-05

Аудит охватывает Desktop-слой Watchtower (SwiftUI + GRDB) и границу «UI ↔ Go CLI/daemon» на предмет ситуаций, когда фактическое состояние данных не отражается в интерфейсе: устаревшие списки, невидимые cross-process записи, ложные индикаторы и элементы управления без эффекта. Метод — несколько поисковых агентов (finders) с последующей независимой состязательной верификацией каждого кандидата: прослеживание полного пути от действия пользователя до источника данных и подтверждение сценария сбоя по коду. Ниже — только находки, прошедшие верификацию (опровергнутые удалены).

Доминирующий системный паттерн: большинство находок — следствия одного архитектурного ограничения. GRDB `ValueObservation` не видит записи, сделанные внешними процессами (Go daemon, `watchtower` CLI как subprocess), что сам проект документирует в `InboxViewModel.swift:48-51` и `CatchUpViewModel.swift:25-28` и в части мест компенсирует поллингом или ручным `load()`. Во многих других местах компенсация отсутствует, а комментарии в коде ошибочно утверждают, что observation «подхватит» изменения.

## High

### Результаты сканирования во вкладке Watch не появляются в ленте активности

- **Где:** `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift:96`
- **Статус верификации:** ✅ подтверждено
- Пользователь нажимает действие сканирования во вкладке Watch у цели. `scanWatch()` запускает `watchtower tracks scan <id>` как подпроцесс; CLI вставляет новые строки `track_events` в СВОЁМ отдельном SQLite-соединении. Лента `events` у VM наполняется исключительно GRDB `ValueObservation` по таблице `track_events` (`start()`, строки 57-68), а `ValueObservation` не видит записи, сделанные внешними процессами — это ограничение сам проект документирует в `InboxViewModel` (строки 48-51) и компенсирует в `TargetsViewModel.promoteSubItem` (строки 485-488) ручным `load()`. `scanWatch()` после возврата CLI не делает никакого reload и выбрасывает возвращённые события `created`, оставляя только их счётчик в заметке. В итоге заметка сообщает «N new update(s)», а лента активности ниже остаётся пустой/устаревшей, пока пользователь не выполнит какую-то несвязанную in-process запись в `track_events` или не переоткроет вью.

```swift
let created = try await scanService.run(trackID: watch.id, since: iso)
note = created.isEmpty ? ... : "\(watch.text): \(created.count) new update(s)."
// self.events не перезагружается; лента питается только ValueObservation,
// которая не видит запись CLI
```

- **Рекомендация:** После `scanService.run` слить возвращённый массив `created` в `self.events` (или сделать явный in-process fetch последних `track_events` для этого трека), как это уже делает `TargetsViewModel.promoteSubItem` через ручной `load()`. Это устранит расхождение между заметкой-счётчиком и пустой лентой.

### Таймлайн кастомного трека не показывает события, найденные ручным сканированием (комментарий про ValueObservation неверен)

- **Где:** `WatchtowerDesktop/Sources/ViewModels/CustomTrackTimelineViewModel.swift:101`
- **Статус верификации:** ✅ подтверждено
- Та же первопричина, но на стороне Tracks: `scanSinceLast()`/`scanHistory()` запускают CLI-подпроцесс, который вставляет `track_events` cross-process. Комментарий в коде утверждает «The CLI wrote any new rows; the ValueObservation stream pushes them» — но `ValueObservation` (`start()`, строки 76-88) уведомляет только о записях через `DatabasePool` самого приложения, не о внешних соединениях. После многоминутного бэкфилла истории баннер сообщает «History scan found N updates», а список таймлайна под ним не меняется, пока пользователь не закроет и снова не откроет детали трека (что пересоздаёт VM и делает свежий initial fetch). Возвращённый массив `created` используется только ради счётчика.

```swift
// The CLI wrote any new rows; the ValueObservation stream pushes
// them. The returned slice is exactly what was created this run.
let created = try await scanService.run(trackID: track.id)
refreshLastRunAt()  // перечитывается только watermark; self.events не обновляется
```

- **Рекомендация:** Заменить неверный комментарий и после `scanService.run` объединить `created` с `self.events` (либо выполнить in-process re-fetch событий трека). Логику маппинга/сортировки лучше вынести в общий метод, чтобы её переиспользовали и `ValueObservation`, и путь после сканирования.

### Переключатель провайдера в чате фактически не меняет AI-провайдера (модель другого провайдера уходит в сконфигурированный)

- **Где:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:109`
- **Статус верификации:** ✅ подтверждено
- Picker провайдера в тулбаре `ChatView` вызывает `switchProvider()`, который лишь меняет локальное состояние UI и вызывает `createService(for:)` — но `createService` игнорирует аргумент `provider` и всегда возвращает `WatchtowerAIService`, запускающий `watchtower ai query` без флага провайдера. Go-сторона (`cmd/ai.go` `runAIQuery` → `newAIClient` в `cmd/generator.go`) выбирает провайдера исключительно по конфигу `ai.provider`. Поэтому при `provider=claude` (дефолт) выбор «Codex» в тулбаре чата меняет список моделей на `gpt-5.4` и передаёт `--model gpt-5.4` в Claude CLI: запрос падает (или идёт не на том провайдере), тогда как UI утверждает, что пользователь общается с Codex. Picker выглядит как рабочий переключатель, но эффекта на бэкенд не имеет.

```swift
static func createService(for provider: AIProvider) -> any AIServiceProtocol {
    _ = provider // provider selection handled by WatchtowerAIService via config
    return WatchtowerAIService()
}
// cmd/generator.go: if cfg.AI.Provider == "codex" {...} return ai.NewClient(cfg.AI.Model, ...)
```

- **Рекомендация:** Пробрасывать выбранного провайдера в CLI: добавить `--provider` (и корректную модель) в аргументы `WatchtowerAIService.run`, где Go уже поддерживает глобальный флаг `--provider`. Либо синхронизировать выбор в тулбаре с `ConfigService` (перезаписывать `ai.provider`), чтобы picker и реальный бэкенд не расходились.

## Medium

### Только что добавленный watch не появляется во вкладке Watch у цели

- **Где:** `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift:22`
- **Статус верификации:** ✅ подтверждено
- Кнопка «Watch +» показывает `CustomTrackManagementSheet`, чей `generate()` создаёт трек через CLI-подпроцесс (`watchtower tracks create --target <id>`). Список вкладки Watch управляется исключительно `ValueObservation` у `TargetWatchesViewModel` по `TrackQueries.fetchByLinkedTarget` (строки 46-56), которая не видит записи внешнего CLI-процесса. У sheet нет хука `onCreated`/`onDismiss` для перезагрузки, и ничто иное не пишет таблицу `tracks` in-process. Худший и одновременно самый частый случай — добавление ПЕРВОГО watch для цели: вкладка продолжает показывать «No watches yet — add a watch to track activity for this goal» уже после того, как sheet подтвердил «Custom track created», пока приложение не перезапустят или не произойдёт несвязанная in-process запись в `tracks`.

```swift
.sheet(isPresented: $showAddWatch) {
    CustomTrackManagementSheet(linkedTargetID: viewModel.target.id)
}  // CLI пишет трек cross-process; список watches питается только ValueObservation
```

- **Рекомендация:** Передать `CustomTrackManagementSheet` completion-хук `onCreated` и в нём вызывать явный in-process refresh вкладки (`TargetWatchesViewModel` fetch по `fetchByLinkedTarget`), либо перезапускать наблюдение на `onDismiss`.

### Кастомный трек, созданный кнопкой «+» в списке Tracks, не появляется в секции Custom

- **Где:** `WatchtowerDesktop/Sources/Views/Tracks/TracksListView.swift:29`
- **Статус верификации:** ✅ подтверждено
- «+» в тулбаре Tracks открывает `CustomTrackManagementSheet` без колбэка; комментарий в коде утверждает «The tracks-table ValueObservation refreshes the Custom section on insert», но вставка происходит в CLI-подпроцессе (`watchtower tracks create`), а `ValueObservation` у `TracksViewModel` (`SELECT COUNT(*) FROM tracks`, строки 76-87) не видит cross-process записи. После того как sheet показал «Custom track created» и пользователь нажал Done, список не меняется; трек появляется только после in-process записи в `tracks` (отметка read/dismiss другого трека) или выхода-возврата на вкладку Tracks (пересоздание VM).

```swift
.sheet(isPresented: $showCreateSheet) {
    // Standalone custom track (no linked target). The tracks-table
    // ValueObservation refreshes the Custom section on insert.
    CustomTrackManagementSheet()
}
```

- **Рекомендация:** Убрать неверный комментарий и добавить `onCreated`-хук, делающий явный in-process refresh `TracksViewModel` после возврата CLI. Единый механизм refresh стоит переиспользовать во всех точках, открывающих `CustomTrackManagementSheet`.

### «All history» сканирование watch на деле сканирует только с последнего watermark

- **Где:** `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift:77`
- **Статус верификации:** ✅ подтверждено
- Пункт меню «All history» вызывает `viewModel.scanWatch(watch, since: nil, ...)`. `scanWatch` маппит `nil` в отсутствие флага `--since` (`let iso = since.map {...}`), а Go CLI без `--since` запускает `RunForTrack` — инкрементальное сканирование от watermark трека (`cmd/tracks.go:802-805`; `internal/customtracks/pipeline.go`: «RunForTrack force-runs one custom track over activity since its watermark»). Таким образом «All history» побайтово идентичен «Since last check» и возвращает «no new activity» для любого уже отсканированного watch, молча пропуская всю историю, которую запросил пользователь. Тот же баг в `scanAll()` (`TargetWatchesViewModel.swift:108-112`, метка «all history»). Правильный паттерн есть в `CustomTrackTimelineViewModel.scanHistory` (строка 124), где `nil` маппится в `Date(timeIntervalSince1970: 0)` до вызова сервиса.

```swift
Button("All history") { Task { await viewModel.scanWatch(watch, since: nil, label: "all history") } }
// TrackScanService.run: if let since, !since.isEmpty { args += ["--since", since] }  → nil = скан только с watermark
```

- **Рекомендация:** В `scanWatch`/`scanAll` для режима «all history» маппить `nil` в эпоху (`Date(timeIntervalSince1970: 0)`) перед вызовом сервиса, как в `CustomTrackTimelineViewModel.scanHistory`. Это заставит CLI передать `--since` с ранней датой и реально пройти всю историю.

### Бейджи в сайдбаре никогда не обновляются от данных daemon (наблюдение слепо к cross-process записям, поллинга нет)

- **Где:** `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift:52`
- **Статус верификации:** ✅ подтверждено
- Все счётчики бейджей сайдбара (inbox unread, updated tracks, unread digests/briefings, targets, сумма Catch-Up) обновляются лишь через один GRDB `ValueObservation` по `COUNT(*)` таблиц плюс единственный `loadInitial()` на старте (`AppState.initSidebarCounts`). Каждая из этих таблиц наполняется Go daemon / CLI-пайплайнами как отдельными процессами, чьи записи `ValueObservation` не видит — именно поэтому `InboxViewModel` добавил 30-секундный поллинг (строки 48-51). У `SidebarCountsViewModel` такого поллинга нет, и ничто иное не перезапускает `fetch()`. Сценарий: приложение открыто, daemon детектит новые mentions/DM или создаёт tracks/digests — всегда видимые бейджи сайдбара остаются со старыми значениями (включая 0), пока пользователь не сделает какую-то in-app запись, что обессмысливает бейджи как сигнал о новых элементах.

```swift
let observation = ValueObservation.tracking { db -> [Int] in
    let tables = ["tracks", "briefings", "targets", "inbox_items", "digests", ...]
    return tables.map { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")) ?? 0 }
}  // поллинга нет; записи daemon cross-process и никогда не триггерят это
```

- **Рекомендация:** Добавить в `SidebarCountsViewModel` периодический поллинг `fetch()` (по образцу `InboxViewModel` / `CatchUpViewModel`), либо триггерить refresh по нотификациям `DigestWatcher`/scenePhase. Идеально — общий cross-process сигнал (файловый watcher на БД), чтобы не плодить независимые таймеры.

### «Generate Briefing» не показывает сгенерированный briefing

- **Где:** `WatchtowerDesktop/Sources/ViewModels/BriefingViewModel.swift:137`
- **Статус верификации:** ✅ подтверждено
- `generateBriefing()` запускает `watchtower briefing generate` как подпроцесс и при успехе лишь ставит `isGenerating=false` — `load()` не вызывается. Единственный путь refresh — `ValueObservation` по `SELECT COUNT(*) FROM briefings` (строки 33-41), но `ValueObservation` не видит записи внешнего процесса (проект документирует это в `CatchUpViewModel.swift:25-28`). Сценарий: пользователь на пустой вкладке Briefings жмёт «Generate Briefing» (`BriefingsListView.emptyList`), CLI успешно отрабатывает, спиннер гаснет — а вью по-прежнему пишет «No briefings yet», пока пользователь не выйдет и не вернётся на вкладку. Та же устарелость касается briefing-ов, записанных daemon, пока вкладка открыта.

```swift
await MainActor.run { [weak self] in
    self?.isGenerating = false
    if process.terminationStatus != 0 {
        self?.generateError = ...
    }
}
// на успехе нет self?.load(); наблюдение по COUNT(*) не видит записи CLI-процесса
```

- **Рекомендация:** После успешного завершения подпроцесса вызывать авторитетный `load()` (как делает `CatchUpViewModel`), а не полагаться на `ValueObservation`. Дополнительно рассмотреть поллинг на время открытой вкладки, чтобы ловить briefing-и от daemon.

### Остановка стриминга в чате сохраняет частичный ответ дважды — дубликаты сообщений ассистента

- **Где:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:248`
- **Статус верификации:** ✅ подтверждено
- `cancelStream()` (кнопка Stop через `ChatView` onStop, а также `bind()`/`newChat()`/`deleteCurrentChat`) сохраняет непустой частичный текст ассистента через `persistMessage()`. Но отменённый `streamTask` продолжает выполнение за пределами `for-await` (итерация `AsyncThrowingStream` просто завершается по отмене, а брошенный `CancellationError` проглатывается guard-ом `if !Task.isCancelled`) и затем безусловно выполняет хвостовой блок «Always persist the response», записывая тот же частичный `fullText` второй раз через `persistResponseStatic()`. Итог — две идентичные строки ассистента в `chat_messages`. Наблюдение сообщений (`records.count != messages.count`) перезагружает данные, и дубликат-бабл появляется в UI немедленно и снова при каждом переоткрытии диалога.

```swift
func cancelStream() {
    streamTask?.cancel() ...
    if !partialText.isEmpty, let convID = conversationID {
        persistMessage(conversationID: convID, role: "assistant", text: partialText)
    }
}
// хвост streamTask (строки 198-201, без guard isCancelled):
if !fullText.isEmpty, let convID = capturedConvID {
    Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText)
}
```

- **Рекомендация:** Оставить ровно один путь сохранения: либо guard-ить хвостовой блок через `if !Task.isCancelled`, либо не сохранять частичный текст в `cancelStream()`, полагаясь на хвост. Добавить unit-тест, реально стартующий `streamTask` с ненулевым `conversationID`, чтобы зафиксировать отсутствие дубликата.

### Catch-up «Regenerate» не обновляет тему в UI (комментарий про наблюдение неверен, запись CLI cross-process)

- **Где:** `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift:215`
- **Статус верификации:** ✅ подтверждено
- `regenerate()` запускает `watchtower catchup regen <id>`, и его doc-комментарий говорит, что перезаписанная строка «picked up by the observation». Но собственный комментарий этого же файла (строки 25-28) утверждает, что `ValueObservation` не видит записи отдельного CLI-процесса — из-за чего `startSession()` добавляет 1-секундный поллинг. `regenerate()` ни поллинг не запускает, ни `reload()` после выхода CLI не вызывает. Сценарий: пользователь жмёт Regenerate на упавшей теме (`failedNotice` прямо советует «Use Regenerate to retry») — CLI перезаписывает строку, но review-панель бесконечно показывает устаревшую/упавшую тему, без индикатора прогресса, пока несвязанная in-process запись (acknowledge/snooze) или перезапуск сессии не триггернёт refresh. У `submitFeedback()` тот же пробел.

```swift
/// Regenerates a single theme ... the row is overwritten in place and picked up by the observation.
func regenerate(_ theme: CatchUpTheme, comment: String) {
    ...
    Task.detached {
        let result = await Self.runCLI(path: cliPath, arguments: args)
        if result.exitCode != 0 { ... error ... }
        // на успехе нет reload()/поллинга
    }
}
// тот же файл, строка 26: "GRDB ValueObservation cannot see writes from the separate CLI process"
```

- **Рекомендация:** После успешного `regen` вызывать `reload()` (или временный поллинг до появления обновлённой темы), как это уже сделано в `startSession()`. Заодно исправить вводящий в заблуждение doc-комментарий.

### Связи, применённые через Suggest Links, не появляются во вкладке Links у цели

- **Где:** `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift:183`
- **Статус верификации:** ✅ подтверждено
- Вкладка Links рендерит `@State`-массив `links`, загружаемый `loadLinks()` только в `.onAppear` (строка 146) и `.onChange(of: target.id)` (строка 153). `SuggestLinksSheet.apply()` (`SuggestLinksSheet.swift:120-147`) вставляет строки в `target_links` (и опционально обновляет `parent_id`), затем закрывается — но у `TargetDetailView` нет refresh-хука на `$showSuggestLinksSheet` (ср. `TrackDetailView`, где есть `.onChange(of: showCreateTarget)` с перезагрузкой). Наблюдения по `target_links` тоже нет (`TargetsViewModel` наблюдает только `COUNT(*) FROM targets`). Сценарий: пользователь открывает Links («No links yet.»), запускает «Suggest links», выбирает предложения, жмёт Apply — sheet закрывается, а вкладка Links всё ещё показывает «No links yet.», пока пользователь не переключится на другую цель и не вернётся. Breadcrumb `parentTarget` (загружается `loadHierarchy` с тем же жизненным циклом) так же устаревает, когда применён родитель.

```swift
.sheet(isPresented: $showSuggestLinksSheet) {
    if let suggestedLinks {
        SuggestLinksSheet(targetID: target.id, suggestions: suggestedLinks)
    }
}  // нет onDismiss/onChange reload; links загружается только на appear / смене target.id
```

- **Рекомендация:** Добавить completion-хук sheet (или `.onChange(of: showSuggestLinksSheet)`), вызывающий `loadLinks()` и `loadHierarchy()` после применения. По образцу sheet «Add sub-target», который уже передаёт `{ _ in loadHierarchy() }`.

### Пагинация «Load more» в Inbox затирается 30-секундным поллингом и любым действием над элементом

- **Где:** `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift:139`
- **Статус верификации:** ✅ подтверждено
- `loadMore()` добавляет страницы за пределами первых 50 элементов ленты (`feedOffset` растёт). Но `load()` всегда перезапрашивает только ПЕРВУЮ страницу (`fetchFeed(limit: feedPageSize, offset: 0)`) и заменяет `feedItems` ею, сбрасывая `feedOffset`. `load()` вызывается безусловным 30-секундным поллингом (`startPolling`, строки 107-117) и каждым действием пользователя (`markSeen` при разворачивании, `markRead`, `dismiss`, `snooze`, feedback). Сценарий: пользователь с >50 элементами ленты пару раз жмёт «Load more» и скроллит, читая; в течение ≤30с срабатывает поллинг (или он разворачивает элемент → `markSeen`→`load`) и `feedItems` схлопывается обратно к первым 50 — элементы под курсором исчезают, а позиция скролла прыгает.

```swift
let feed = try InboxQueries.fetchFeed(db, limit: self.feedPageSize, offset: 0, ...)
...
feedItems = result.5
feedOffset = result.5.count  // poll: while !Task.isCancelled { try? await Task.sleep(for: interval); self?.load() }
```

- **Рекомендация:** В `load()` перезапрашивать до текущего смещения (`limit: max(feedPageSize, feedOffset)`), а не жёстко одну страницу, чтобы поллинг и действия сохраняли уже подгруженные страницы и позицию скролла.

### Meeting prep в календаре показывает prep предыдущего события, когда генерация для нового падает (общий VM + result проверяется раньше error)

- **Где:** `WatchtowerDesktop/Sources/Views/Calendar/MeetingPrepView.swift:16`
- **Статус верификации:** ✅ подтверждено
- `CalendarEventsView` переиспользует один `MeetingPrepViewModel` для всех событий (строка 5: `@State private var meetingPrepVM = MeetingPrepViewModel()`, generate на строке 187), а `MeetingPrepViewModel.generate()` никогда не очищает `result` — только `error`. `MeetingPrepDetailView` рендерит `result` раньше `error`. Сценарий: пользователь жмёт Prepare на событии A (успех), затем Prepare на событии B и CLI падает (exit != 0): `error` установлен, но `result` всё ещё держит prep события A, поэтому панель для B молча показывает talking points/people notes события A без вывода ошибки. `DayPlanView` явно обходит ровно этот класс бага («Fresh VM per meeting avoids showing cached prep from a previous event», `DayPlanView.swift:78`), но `CalendarEventsView` не поправили.

```swift
if viewModel.isLoading {
    loadingView
} else if let result = viewModel.result {
    prepContent(result)   // устаревший result прошлого события выигрывает
} else if let error = viewModel.error {
    errorView(error)      // недостижимо, пока есть устаревший result
}
```

- **Рекомендация:** Очищать `result` в начале `generate()` (или использовать свежий VM на каждое событие, как в `DayPlanView`). Как минимум — рендерить `error` раньше `result`, чтобы ошибка не пряталась за устаревшими данными.

### Сохранение General settings показывает «Saved», но запущенный daemon держит старый конфиг, без подсказки о рестарте

- **Где:** `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift:527`
- **Статус верификации:** ✅ подтверждено
- Кнопка Save пишет `config.yaml` и мигает «Saved». Но daemon загружает конфиг один раз при старте процесса и держит его в памяти (`internal/daemon/daemon.go:49` `config *config.Config`, читается как `d.config.Sync.PollInterval`, `d.config.Briefing.Hour`, `d.config.DayPlan` и т.д. каждый цикл; пути reload в `internal/daemon/` нет). Поэтому правки sync interval, workers, digest enabled/model/language, briefing hour, day-plan не имеют эффекта, пока daemon вручную не перезапустят из отдельной вкладки Daemon — и ничто в UI на это не указывает. Сценарий: пользователь меняет Briefing Hour с 8 на 10, сохраняет, видит «Saved» — а briefing-и продолжают генерироваться в 8 бесконечно.

```swift
Button("Save") {
    try config.save()
    withAnimation { showSaved = true }  // нет рестарта daemon, нет уведомления "restart required"
}
// internal/daemon/daemon.go:160: pollInterval := d.config.Sync.PollInterval (конфиг захвачен в New(), не перечитывается)
```

- **Рекомендация:** Показывать после сохранения баннер «требуется перезапуск daemon» (или предлагать авто-рестарт через вкладку Daemon) для настроек, влияющих на daemon. Долгосрочно — добавить в daemon reload конфига по SIGHUP/файловому watcher.

### Поллинг фазы сборки Catch-up каждую секунду уводит выбор пользователя с любой просмотренной темы

- **Где:** `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift:130`
- **Статус верификации:** ✅ подтверждено
- `apply()` выполняется на каждое событие наблюдения и на каждый тик 1с-поллинга в `startSession()` и безусловно перенацеливает выбор на первую pending-тему, если текущий выбор не pending: `if selected == nil || !(selected?.isPending ?? false) { selected = themes.first { $0.isPending } }`. Список тем (`CatchUpView.themeList`) позволяет выбрать любую тему, включая уже просмотренные. Сценарий: пока сессия собирается (поллинг активен) или сразу после acknowledge/snooze, пользователь кликает просмотренную тему, чтобы перечитать её — в течение секунды (или на следующем событии наблюдения) выбор прыгает обратно на первую pending-тему, делая просмотренные темы невозможными для инспекции во время прохода.

```swift
if let current = selected, let fresh = themes.first(where: { $0.id == current.id }) { selected = fresh }
if selected == nil || !(selected?.isPending ?? false) {
    selected = themes.first { $0.isPending }
}
```

- **Рекомендация:** Авто-перенацеливать выбор только когда выбора нет (`selected == nil`) или тема исчезла из списка — не отбирать явно сделанный пользователем выбор просмотренной темы. Ввести флаг «пользователь выбрал вручную», сбрасываемый только при acknowledge текущей темы.

## Low

### Индикатор «CLI найден» и Test Connection в Settings игнорируют настроенный override claude_path/codex_path

- **Где:** `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift:310`
- **Статус верификации:** ✅ подтверждено
- Зелёная/красная иконка статуса рядом с полями «Claude CLI Path» / «Codex CLI Path» и `testConnection()` оба используют `Constants.findInPath("claude"/"codex")`, который сканирует лишь известные директории и PATH и никогда не сверяется с override, введённым пользователем в соседнее поле (`config.claudePath/codexPath`). Сценарий: пользователь ставит claude в нестандартную локацию и задаёт override пути: индикатор показывает красный X «Claude CLI not found», а Test Connection отказывает «Claude CLI not found» — хотя daemon и CLI уважают override и работают. Settings-UI сообщает о поломке, которой нет (и заодно тестирует не тот бинарь, что реально настроен).

```swift
if let path = Constants.findInPath("claude") { Image(systemName: "checkmark.circle.fill") ... }
else { Image(systemName: "xmark.circle.fill").help("Claude CLI not found") }
// testConnection():
let cliPath: String? = isCodex ? Constants.findInPath("codex") : Constants.findInPath("claude")
guard let path = cliPath else { connectionTestResult = "\(providerName) CLI not found"; ... }
```

- **Рекомендация:** Резолвить бинарь через `Constants.findClaudePath()`/`findCodexPath()` (config-override-first), а не через `findInPath`, чтобы индикатор и Test Connection проверяли реально настроенный путь.

### Решения без канала (кросс-канальные rollup-решения) невозможно оценить — кнопки feedback скрыты guard-ом по channelID

- **Где:** `WatchtowerDesktop/Sources/Views/Digests/DecisionDetailView.swift:139`
- **Статус верификации:** ✅ подтверждено
- `channelActionsSection` оборачивает и Slack-кнопку «Mark read», И `FeedbackButtons` в `if !entry.channelID.isEmpty`. Решения из daily/weekly rollup-дайджестов, где AI не проставил per-decision `channel_id`, резолвятся в пустой `channelID` (`DigestViewModel.buildDecisionEntries` откатывается к `digest.channelID`, пустому для daily/weekly). Для таких решений — показываемых в заголовке детали как «Cross-channel» — кнопки thumbs up/down никогда не рендерятся, так что цикл обратной связи AI недоступен именно на rollup-уровне. Канал нужен только Slack-действию; feedback ключуется по `digestID:decisionIdx` и в канале не нуждается.

```swift
@ViewBuilder
private var channelActionsSection: some View {
    if !entry.channelID.isEmpty {   // прячет и FeedbackButtons
        HStack { ... FeedbackButtons(entityType: "decision", entityID: "\(entry.digestID):\(entry.decisionIdx)", ...) }
    }
}
```

- **Рекомендация:** Вынести `FeedbackButtons` из-под guard `channelID`, оставив под ним только Slack-специфичную «Mark read». Feedback должен рендериться независимо от наличия канала.

### Секция Dependencies не обновляется после промоута sub-item в дочернюю цель

- **Где:** `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift:196`
- **Статус верификации:** ✅ подтверждено
- Поток «Convert to sub-target» показывает `PromoteSubItemSheet` (`.sheet(item: $promotingSubItem)`), создающий дочернюю цель через CLI (`TargetsViewModel.promoteSubItem` → `TargetPromoteSubItemService`). `promoteSubItem()` вызывает `viewModel.load()`, поэтому СПИСОК обновляется, но `@State childTargets` у `TargetDetailView` (секция «Dependencies») загружается `loadHierarchy()` только на appear / смене `target.id`; в отличие от sheet «Add sub-target» (строка 172, передающего `{ _ in loadHierarchy() }`), у promote-sheet нет completion-хука. Сценарий: пользователь конвертирует checklist-элемент в sub-target; запись checklist исчезает (родитель обновляется через VM списка), но секция Dependencies всё ещё пишет «No sub-targets yet» / не содержит нового ребёнка, пока пользователь не переключится на другую цель и не вернётся. Та же устарелость у детей, созданных через target Assistant (`TargetsViewModel.createChild`).

```swift
.sheet(item: $promotingSubItem) { ctx in
    ...
    PromoteSubItemSheet(parent: target, subItem: ctx.item, subItemIndex: ctx.index, viewModel: viewModel, ...)
}  // нет loadHierarchy() на dismiss; childTargets грузится только в onAppear/onChange(of: target.id)
```

- **Рекомендация:** Передать promote-sheet completion-хук, вызывающий `loadHierarchy()` (по образцу sheet «Add sub-target»); аналогично закрыть пробел в `createChild`.

### Переход к briefing старше первой страницы молча ничего не делает

- **Где:** `WatchtowerDesktop/Sources/Views/Briefings/BriefingsListView.swift:11`
- **Статус верификации:** ✅ подтверждено
- Деталь показывается только когда выбранный id найден в `vm.briefings`, который `load()` ограничивает `pageSize=30`: `if let selID = selectedBriefingID, let briefing = vm.briefings.first(where: { $0.id == selID })` — иначе молчаливый откат к `listView`. `appState.navigateToBriefing()` (из кнопки «Briefing» в Day Plan, source-refs Catch-up, нотификаций) ставит `pendingBriefingID`; если этот briefing не среди 30 самых свежих (например, ref из catch-up или старый day plan после месяца briefing-ов), клик не даёт видимого эффекта: показан список, ошибки нет, а `markAsRead` всё равно вызывается для невидимого briefing через `onChange(of: selectedBriefingID)`.

```swift
if let selID = selectedBriefingID,
   let briefing = vm.briefings.first(where: { $0.id == selID }) {
    detailView(briefing)
} else {
    listView(vm)   // молчаливый откат; selectedBriefingID остаётся установленным
}
```

- **Рекомендация:** Когда id не найден на загруженной странице, резолвить briefing через существующий `fetchByID`-путь VM (и/или подгружать страницы до нужного), вместо молчаливого отката к списку.

### Отметка дайджеста прочитанным пере-триггерит наблюдение счётчика и сбрасывает пагинацию дайджестов к первым 50

- **Где:** `WatchtowerDesktop/Sources/ViewModels/DigestViewModel.swift:293`
- **Статус верификации:** ✅ подтверждено
- `markDigestRead()`/`markDigestsRead()` пишут в таблицу `digests` через пул самого приложения. `ValueObservation` из `startObserving()` следит за `SELECT COUNT(*) FROM digests` без `removeDuplicates`, а GRDB уведомляет о каждой транзакции, затрагивающей отслеживаемый регион (таблицу `digests`), даже если полученный count не изменился — так что каждая mark-read запускает полный `load()`, заменяющий `digests` первой страницей (`fetchAll` default limit 50) и сбрасывающий `digestsOffset`/`hasMoreDigests`. Сценарий: пользователь проскроллил 150 загруженных дайджестов (3 страницы), кликает один для чтения → массив схлопывается к 50 строкам, позиция скролла прыгает, а подгруженные страницы исчезают до повторного скролла. Аккуратно поддерживаемые локальные апдейты внутри `markDigestRead` показывают, что reload не задумывался.

```swift
let observation = ValueObservation.tracking { db in
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0
}
for try await _ in observation.values(in: dbPool).dropFirst() { self?.load() }
// load(): digests = applySort(result.digests); digestsOffset = result.digests.count  // только страница 1
```

- **Рекомендация:** Добавить `.removeDuplicates()` к наблюдению счётчика и/или в `load()` перезапрашивать до текущего `digestsOffset`, чтобы отметка read не усекала проскролленный список. Полагаться на уже поддерживаемые локальные апдейты вместо полного reload.

### Thumbs up/down: быстрое повторное голосование может восстановить неверное состояние после переоткрытия

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/FeedbackQueries.swift:36`
- **Статус верификации:** ✅ подтверждено
- `FeedbackButtons.submitFeedback` делает INSERT новой строки feedback на каждый клик (без upsert), а `loadExistingFeedback` восстанавливает текущий рейтинг через `ORDER BY created_at DESC LIMIT 1`. `created_at` — дефолт с секундной гранулярностью (`strftime('%Y-%m-%dT%H:%M:%SZ','now')`), tiebreak по `id DESC` отсутствует. Сценарий: пользователь кликает 👍, затем исправляет на 👎 в ту же секунду (обычное исправление промаха); обе строки делят `created_at`, поэтому при следующей загрузке вью (возврат на вкладку, перезапуск) `getFeedback` может вернуть устаревшую строку 👍, и кнопка подсветит рейтинг, от которого пользователь явно ушёл. Дублирующие строки также раздувают счётчики `getStats` в Training settings.

```sql
INSERT INTO feedback (entity_type, entity_id, rating, comment) VALUES (?, ?, ?, ?)
...
SELECT * FROM feedback WHERE entity_type = ? AND entity_id = ?
ORDER BY created_at DESC LIMIT 1   -- нет tiebreak по id
```

- **Рекомендация:** Добавить `, id DESC` в `ORDER BY` для детерминированного восстановления последнего рейтинга; в идеале — заменить append-only INSERT на upsert по `(entity_type, entity_id)`, что заодно исправит раздувание `getStats`.
