# Баги на стороне сервера (Go) — аудит 2026-07-05

Аудит покрывает весь Go-бэкенд Watchtower: sync-оркестратор (Slack/Jira/Calendar), слой БД и миграции, AI-пайплайны (digest, tracks, inbox, briefing, dayplan, people), CLI-команды и интеграцию с провайдерами claude/codex. Метод: несколько независимых агентов-поисковиков (по подсистемам) генерировали кандидатов, после чего каждая находка проходила независимую адверсариальную верификацию с трассировкой пути исполнения по коду; опровергнутые находки удалены из отчёта. Итог: 8 High, 23 Medium, 23 Low, Critical нет.

## High

### Миграция 00002 молча стирает всю таблицу inbox_feedback через каскад DROP TABLE

- **Где:** `internal/db/migrations/00002_target_due_inbox.sql:48`
- **Статус верификации:** ✅ подтверждено

Расширение enum `trigger_type` пересоздаёт `inbox_items` через классический DROP/RENAME-«танец». Но `db.Open` включает `PRAGMA foreign_keys=ON` на единственном pooled-соединении ещё до запуска goose, а `inbox_feedback` объявлена с `inbox_item_id ... REFERENCES inbox_items(id) ON DELETE CASCADE`. В SQLite `DROP TABLE` выполняет неявный `DELETE FROM`, который срабатывает FK-действиями, а `PRAGMA defer_foreign_keys=ON` откладывает только проверки НАРУШЕНИЙ, но не CASCADE-действия. В итоге `DROP TABLE inbox_items` каскадно удаляет все строки `inbox_feedback`. Любой пользователь, обновляющий legacy-базу (до goose) с накопленным 👍/👎-фидбеком, теряет всю историю обучения inbox в момент применения 00002. Воспроизведено эмпирически на драйвере проекта (modernc.org/sqlite): после точной последовательности стейтментов счётчик `inbox_feedback` падает 2 → 0, при этом `inbox_items` выживает. Down-миграция имеет идентичный дефект; тестов на выживание `inbox_feedback` через эту миграцию нет. Комментарий в самой миграции («reference survives the DROP/RENAME dance») ошибочен: выживает только схемная ссылка, строки — удаляются.

```sql
PRAGMA defer_foreign_keys = ON;
...
INSERT INTO inbox_items_new SELECT * FROM inbox_items;
DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;
-- repro: sqlite3 with foreign_keys=ON → 'feedback rows after dance:|0'
```

- **Рекомендация:** Использовать канонический идиом table-recreation из документации SQLite: временно выключать `PRAGMA foreign_keys=OFF` перед транзакцией (а не `defer_foreign_keys`), делать DROP/RENAME, затем `PRAGMA foreign_key_check` и снова `ON`. Исправить и Up, и Down; добавить регрессионный тест, который сеет строки в `inbox_feedback` перед 00002 и проверяет их выживание.

### Watermark search_last_date продвигается до «сегодня» даже при досрочном обрыве пагинации — пропущенные сообщения теряются навсегда

- **Где:** `internal/sync/search_sync.go:181`
- **Статус верификации:** ✅ подтверждено

`syncViaSearch` пагинирует `search.messages` по возрастанию timestamp (страница 1 — самые старые сообщения). При любой non-fatal ошибке посреди пагинации (`RateLimitedError` после 3 ретраев `doRequest`, `missing_scope`, `access_denied` и т.п.) цикл делает `break` и проваливается к безусловному `SetSearchLastDate(today)` — даже если остановился на 1-й странице из 50. Следующий инкрементальный sync запрашивает `after: today-2d`, поэтому все сообщения с незагруженных страниц старше `today-2d` больше никогда не будут получены. Поскольку search-sync — путь ПО УМОЛЧАНИЮ, включая первый запуск, обрыв по rate-limit в начале первичной синхронизации окна в 30–60 дней молча и безвозвратно теряет недели истории. Контраст: путь `conversations.history` намеренно НЕ продвигает `LastSyncedTS`, пока не выкачаны все страницы (message_sync.go:325-330); в search-пути эквивалентного guard'а нет. Отмена контекста корректно возвращается до записи watermark — затронут только non-fatal break.

```go
if isNonFatalError(err) {
    o.logger.Printf("search sync: non-fatal error on page %d, stopping early: %v", page, err)
    break
}
...
// Advance the watermark to today.
today := time.Now().Format("2006-01-02")
if err := o.db.SetSearchLastDate(today); err != nil {
```

- **Рекомендация:** Ввести флаг `completed` и продвигать `search_last_date` только при полном проходе всех страниц; при досрочном break — либо не трогать watermark вообще, либо ставить его на дату последнего фактически обработанного сообщения. Дополнительно пробрасывать факт частичной синхронизации наверх (лог + LastSyncResult), чтобы сбой не выглядел успехом.

### Токен без scope search:read: после первого sync каждый инкрементальный цикл молча синхронизирует ноль сообщений, отчитываясь об успехе

- **Где:** `internal/sync/orchestrator.go:167`
- **Статус верификации:** ✅ подтверждено

Когда `search.messages` возвращает `missing_scope` (non-fatal), `syncViaSearch` делает break на странице 1 и возвращает `nil` — поэтому явная fallback-ветка `if isNonFatalError(err) { ... return o.runFullSync }` (orchestrator.go:156-159) недостижима для ошибок Slack search: `syncViaSearch` их никогда не возвращает. Единственный оставшийся fallback — проверка `DiscoveryChannels==0`, которая переключается на full sync ТОЛЬКО при пустой БД (ноль каналов). Сценарий для токена без `search:read` (например, bot-токен): первый цикл демона → БД пустая → fallback на full sync заполняет каналы; каждый последующий цикл → search падает non-fatally → 0 сообщений → `stats.ChannelCount > 0` → fallback не срабатывает → `finishSync()` вызывает `TouchSyncedAt()`, и Desktop показывает свежий успешный sync. Данные навсегда протухают при нулевой видимости ошибки (daemon-фаза `phaseSlackSync` получает `err=nil`). Тест `TestRunSearchSyncFallsBackOnNonFatalError` покрывает только случай пустой БД и маскирует проблему. Вдобавок watermark всё равно продвигается до «сегодня» каждый цикл (search_sync.go:181).

```go
snap := o.progress.Snapshot()
if snap.DiscoveryChannels == 0 {
    stats, err := o.db.GetStats()
    if err != nil || stats.ChannelCount == 0 {
        o.logger.Println("search found 0 channels, falling back to full sync")
        return o.runFullSync(ctx, opts)
    }
}
```

- **Рекомендация:** `syncViaSearch` должен возвращать типизированную ошибку (или флаг) для Slack-level non-fatal сбоев search, чтобы ветка fallback в `runSearchSync` реально срабатывала и переключала на full sync независимо от наполненности БД. Добавить тест с предзаполненными каналами и `missing_scope`.

### Дедупликация inbox сливает несвязанные items разных trigger-типов, молча «резолвя» pending-упоминания и DM

- **Где:** `internal/db/inbox.go:328`
- **Статус верификации:** ✅ подтверждено

`DeduplicateThreadInboxItems` (Phase 0 каждого inbox `Run` и `RunFastDetection`) группирует pending-items только по `(channel_id, thread_ts)` без учёта `trigger_type`. Все не-тредовые items имеют `thread_ts=''`. Watchtower-item типа `decision_made` хранит реальный Slack `channel_id` дайджеста с `thread_ts=''` (watchtower_detector.go:127), поэтому когда у пользователя есть pending не-тредовый `mention`/`dm` в канале C и позже для того же канала создаётся `decision_made`, следующий цикл дедупликации оставляет только `MAX(id)` (решение) и переводит pending-упоминание в `status='resolved', resolved_reason='Merged duplicate'` — actionable-упоминание исчезает из ленты без какого-либо действия пользователя. Два разных важных решения в одном канале так же сливаются в одно, а пара `calendar_invite` + `calendar_time_change` по одному событию схлопывается. Тестов на `DeduplicateThreadInboxItems` нет.

```sql
UPDATE inbox_items SET status = 'resolved', resolved_reason = 'Merged duplicate'
  WHERE status = 'pending'
  AND id NOT IN (SELECT MAX(id) FROM inbox_items WHERE status = 'pending' GROUP BY channel_id, thread_ts)
  AND EXISTS (SELECT 1 FROM inbox_items i2 WHERE i2.channel_id = inbox_items.channel_id AND i2.thread_ts = inbox_items.thread_ts ...)
```

- **Рекомендация:** Добавить `trigger_type` в GROUP BY/EXISTS (и, вероятно, исключить из дедупликации не-тредовые items с `thread_ts=''` вовсе — дедуплицировать только реальные треды). Покрыть тестом сценарий «mention + decision_made в одном канале».

### Day-plan рендерит календарные события в UTC, а валидация и «now» — локальные: таймблоки AI отбрасываются у всех не-UTC пользователей

- **Где:** `internal/dayplan/prompt.go:213`
- **Статус верификации:** ✅ подтверждено

`shortTime` форматирует начало/конец события через `t.UTC().Format("15:04")`, поэтому для пользователя UTC+3 (пользователь этого проекта) встреча 10:00–11:00 по локальному времени показывается AI как «07:00–08:00». При этом `NowLocal` и рабочие часы в промпте — локальные, а возвращённые AI времена парсятся через `time.ParseInLocation(..., time.Local)` (merge.go:57). AI избегает фантомного слота 07:00–08:00 и свободно ставит блок на 10:00 локального времени — который проверка пересечений в `aiToTimeblock` (merge.go:75, сравнение абсолютных времён с корректно-UTC-распарсенным событием) затем отбрасывает как «timeblock overlaps calendar event». Каждая встреча сдвинута в промпте на величину UTC-смещения, так что планы системно теряют блоки вокруг реальных встреч и ничего не планируют вокруг фантомных. Ср. `formatCalendarEvent` в briefing (briefing/pipeline.go:552), который корректно вызывает `.Local()`.

```go
func shortTime(iso string) string {
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05Z", "2006-01-02T15:04:05"} {
		if t, err := time.Parse(layout, iso); err == nil {
			return t.UTC().Format("15:04")
		}
	}
```

- **Рекомендация:** Заменить `t.UTC()` на `t.Local()` в `shortTime`, чтобы промпт, валидация и «now» жили в одной таймзоне (по образцу briefing). Добавить тест с не-UTC локацией, проверяющий, что блок в момент реальной встречи отбрасывается, а вне её — принимается.

### All-day события не исключаются из валидации пересечений day-plan — одно событие «на весь день» убивает все таймблоки AI

- **Где:** `internal/dayplan/merge.go:69`
- **Статус верификации:** ✅ подтверждено

Календарный клиент хранит all-day события как StartTime=UTC-полночь дня, EndTime=UTC-полночь следующего дня с `IsAllDay=true` (calendar/client.go:271-286), и `GetCalendarEventsForDate` их возвращает. Ни цикл пересечений в `aiToTimeblock`, ни `DetectConflicts` (conflicts.go:41), ни `syncCalendarItems` (calendar_sync.go:42) не проверяют `ev.IsAllDay`. При любом all-day событии в календаре (день рождения, OOO, праздник — очень частый случай) `timesOverlap(start, end, 00:00Z, 24:00Z)` истинно для каждого таймблока в рабочих часах: `buildItems` отбрасывает ВСЕ AI-таймблоки («overlaps calendar event»), `DetectConflicts` помечает каждый оставшийся блок конфликтным, а `syncCalendarItems` вставляет all-day событие как фиктивный таймблок на 1440 минут. Контраст: `PrepareForNext` в meeting явно пропускает `ev.IsAllDay` (meeting/pipeline.go:115), а briefing помечает их «All day» — dayplan здесь выбивается из общего паттерна.

```go
for _, ev := range events {
	evStart := parseEventTime(ev.StartTime)
	evEnd := parseEventTime(ev.EndTime)
	if evStart.IsZero() || evEnd.IsZero() { continue }
	if timesOverlap(start, end, evStart, evEnd) {
		return nil, fmt.Sprintf("timeblock %q overlaps calendar event %q", ai.Title, ev.Title)
	}
}  // no ev.IsAllDay check
```

- **Рекомендация:** Во всех трёх местах (aiToTimeblock, DetectConflicts, syncCalendarItems) добавить `if ev.IsAllDay { continue }` — по образцу meeting/pipeline.go:115. Тест: один all-day + обычная встреча, проверить что блоки отбрасываются только из-за встречи.

### Инкрементальный Jira-sync сравнивает UTC-watermark с JQL, интерпретируемым в таймзоне пользователя — обновления навсегда пропускаются для профилей западнее UTC

- **Где:** `internal/jira/sync.go:107`
- **Статус верификации:** ✅ подтверждено

`Sync()` хранит watermark в UTC (`time.Now().UTC().Format(RFC3339)`) и строит инкрементальный JQL как `updated >= "2006-01-02 15:04"` без таймзоны. Jira интерпретирует JQL-datetime без таймзоны в профильной таймзоне пользователя Jira, а не в UTC. Для профиля западнее UTC (например, UTC-5) «12:00» означает 17:00 UTC — эффективное окно начинается на часы ПОЗЖЕ реального watermark. Issue, обновлённый в 13:00 UTC, не попадает в текущий цикл, а поскольку watermark затем продвигается до «now», эффективное начало каждого следующего запроса ещё позже — обновление никогда не будет выкачано, пока issue не отредактируют снова. Для таймзон восточнее UTC окно лишь сдвигается раньше (безвредный re-fetch). Итог: молча устаревшие `jira_issues` для любого Jira-профиля западнее UTC; двухминутный overlap многочасовое смещение не покрывает.

```go
t = t.Add(-2 * time.Minute)
jql = fmt.Sprintf("project = %s AND updated >= \"%s\" ORDER BY updated ASC",
    projectKey, t.Format("2006-01-02 15:04"))
```

- **Рекомендация:** Узнать таймзону аккаунта через `/rest/api/3/myself` и конвертировать watermark в неё перед форматированием JQL (либо использовать относительный синтаксис `updated >= -Nm`, не зависящий от таймзоны). Добавить тест, пиняющий формат JQL.

### SyncBoard продвигает watermark проекта, синхронизировав только незакрытые issues — закрытые никогда не бэкфиллятся, вопреки собственной документации

- **Где:** `internal/jira/sync.go:190`
- **Статус верификации:** ✅ подтверждено

`SyncBoard` (вызывается `jira sync --board`, который Desktop запускает при выборе доски — JiraBoardSyncManager.swift:62) синхронизирует по JQL `statusCategory != Done`, после чего вызывает `UpdateJiraSyncState(projectKey, now, n)`. Doc-комментарий утверждает, что «Terminal/closed issues are picked up by the daemon's regular Sync() cycle», но регулярный `Sync()` инкрементален от этого watermark (`updated >= now-2min`), поэтому исторические Done-issues — обновлённые в прошлом — никогда не будут выкачаны. `InitialLoad()`, который сделал бы полный бэклог, не имеет ни одного вызова в репозитории. Каждая доска, подключённая через Desktop (основной путь онбординга), навсегда лишена истории закрытых issues — ломаются прогресс эпиков, release-дашборды и velocity-запросы, считающие done.

```go
jql := fmt.Sprintf("project = %s AND statusCategory != Done ORDER BY updated ASC", board.ProjectKey)
...
now := time.Now().UTC().Format(time.RFC3339)
_ = s.db.UpdateJiraSyncState(board.ProjectKey, now, n)
```

- **Рекомендация:** Либо не записывать watermark из `SyncBoard` (оставив первый полный `Sync()` демону — он при отсутствии state делает полный fetch), либо вызывать `InitialLoad()` при первом подключении доски. Как минимум исправить doc-комментарий и добавить тест «после SyncBoard демон подхватывает исторические Done».

## Medium

### `targets --status done|dismissed` всегда возвращает пустой список: исключение done/dismissed AND-ится с фильтром статуса

- **Где:** `cmd/targets.go:342`
- **Статус верификации:** ✅ подтверждено

Help флага `--status` явно перечисляет `done` и `dismissed` как валидные значения, но `runTargetsList` выставляет `IncludeDone` только из `--all`. В `db.GetTargets` при `IncludeDone=false` запрос получает одновременно `status NOT IN ('done','dismissed')` И `status = ?`, что для `--status done|dismissed` — противоречие: запрос не матчит ничего. Пользователь, запускающий `watchtower targets --status done`, всегда видит «No targets found.» независимо от данных, пока не догадается добавить `--all`. (Верификатор понизил серьёзность до medium: реальный, достижимый баг на задокументированном флаге, но без потери данных и с обходным путём.)

```go
f := db.TargetFilter{
    Status:      targetsFlagStatus,
    ...
    IncludeDone: targetsFlagAll,
}
// db/targets.go: if !f.IncludeDone { conditions = append(conditions, "status NOT IN ('done','dismissed')") }
// if f.Status != "" { conditions = append(conditions, "status = ?") }
```

- **Рекомендация:** В `runTargetsList` ставить `IncludeDone=true`, когда `--status` явно равен `done` или `dismissed` (или в `GetTargets` пропускать exclusion при заданном `f.Status`). Добавить тест на `--status done`.

### UnsnoozeExpiredInboxItems сравнивает date-only строку с полным ISO-datetime из Desktop — короткие snooze длятся до следующего UTC-дня

- **Где:** `internal/db/inbox.go:246`
- **Статус верификации:** ✅ подтверждено

Демонский unsnooze использует `today := time.Now().UTC().Format("2006-01-02")` и `WHERE ... snooze_until <= ?`. Но macOS-приложение пишет `snooze_until` полным ISO-8601 datetime: `.oneHour → iso8601String(now+1h)`, например `"2026-07-05T14:23:11Z"` (InboxFeedView.swift:295 через InboxQueries.snooze). Лексикографически `"2026-07-05T14:23:11Z" > "2026-07-05"` весь день, поэтому item, заснуженный на 1 час в Desktop UI, остаётся скрытым до первого запуска демона на СЛЕДУЮЩИЙ UTC-день. Swift-стороннего unsnooze нет — этот Go-запрос единственный механизм. Соседний `UnsnoozeExpiredTargets` (targets.go:338) корректно использует минутное разрешение `2006-01-02T15:04` — inbox здесь выбивается.

```go
today := time.Now().UTC().Format("2006-01-02")
... WHERE status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?`, today)
// Desktop writes: until = iso8601String(cal.date(byAdding: .hour, value: 1, to: now) ?? now)
```

- **Рекомендация:** Сравнивать с полным timestamp (`time.Now().UTC().Format(time.RFC3339)` или хотя бы минутным `2006-01-02T15:04`, как в targets) — date-only значения `<=`-сравнение с полным timestamp по-прежнему проходят корректно.

### Прогон tracks со 100% упавших AI-батчей всё равно отчитывается успехом, продвигая инкрементальный watermark и навсегда пропуская те дайджесты

- **Где:** `internal/tracks/pipeline.go:314`
- **Статус верификации:** ✅ подтверждено

`runTrackBatches` только логирует пер-батчевые AI-ошибки (line 576), а `RunForWindow` всегда возвращает nil error. Если упали ВСЕ батчи (например, временный сбой claude CLI / rate limit после того, как digest-фаза съела квоту), `tracks.Run` возвращает `(0, 0, nil)`, демон записывает прогон со status='done' (daemon.go:287), а `GetLatestPipelineRunStartedAt/PeriodTo` (фильтруют по status='done') продвигают watermark tracks. Следующий инкрементальный прогон берёт только дайджесты, созданные после started_at провального прогона, — все digest-topics из провального окна никогда не сканируются на треки: тихий, постоянный пробел экстракции. Контраст: digest-пайплайн намеренно возвращает ошибку при `gen==0 && errs>0` (digest/pipeline.go:781-783) ровно чтобы этого избежать.

```go
return totalStored, nil //nolint:nilerr // partial results returned; per-batch errors logged above
// runTrackBatches: p.logger.Printf("tracks: error in batch %d/%d: %v", …) — error never propagated
```

- **Рекомендация:** Повторить guard digest-пайплайна: если сохранено 0 треков и были ошибки батчей — возвращать ошибку из `RunForWindow`, чтобы daemon записал прогон failed и watermark не продвинулся.

### Codex-генератор читает source пайплайна из чужого context-ключа — маршрутизация ModelForSource мертва

- **Где:** `internal/codex/generator.go:38`
- **Статус верификации:** ✅ подтверждено

Все пайплайны помечают AI-вызовы через `digest.WithSource(ctx, source)`, который кладёт метку под неэкспортируемым типом `digest.sessionSourceKey{}` (digest/pooled.go:69-74). `CodexGenerator.Generate` объявляет СВОЙ `type sessionSourceKey struct{}` в пакете codex и делает `ctx.Value(sessionSourceKey{})` с ним. Context-ключи сравниваются по идентичности динамического типа; `codex.sessionSourceKey` и `digest.sessionSourceKey` — разные типы, поэтому lookup ВСЕГДА возвращает nil. Следствие: для каждого пользователя codex-провайдера `ModelForSource` никогда не вызывается — лёгкие sources (`digest.SourceLight`, "inbox.prioritize", "digest.channel_batch", "people.batch" и т.д.) не маршрутизируются на gpt-5.4-mini, все пайплайновые вызовы идут на модель по умолчанию, вопреки контракту в pooled.go и документации проекта. models_test.go тестирует `ModelForSource` только как чистую функцию, так что сломанная обвязка не покрыта.

```go
// codex/generator.go:20,38
type sessionSourceKey struct{}
...
if s, ok := ctx.Value(sessionSourceKey{}).(string); ok && s != "" {
    model = ModelForSource(s)
}
// digest/pooled.go:69-73 (the actual key used by all callers)
type sessionSourceKey struct{}
func WithSource(ctx context.Context, source string) context.Context {
    return context.WithValue(ctx, sessionSourceKey{}, source)
}
```

- **Рекомендация:** Экспортировать из пакета digest функцию `SourceFromContext(ctx) (string, bool)` и использовать её в codex-генераторе (удалив локальный тип-двойник). Добавить интеграционный тест: `digest.WithSource` → `CodexGenerator` выбирает mini-модель.

### Store.Seed молча перезаписывает кастомизированные пользователем промпты при повышении версии встроенного дефолта

- **Где:** `internal/prompts/store.go:90`
- **Статус верификации:** ✅ подтверждено

Ветка авто-апгрейда в комментарии обещает обновлять только «if ... the user hasn't customized the template», но код не проверяет ничего, кроме `existing.Version < defaultVer` — сравнения шаблонов нет. `db.UpdatePrompt` инкрементирует версию на +1 от текущей. Сценарий: промпт засеян с DefaultVersions=3; пользователь кастомизирует его через `prompts tune`/Update → v4; релиз повышает DefaultVersions до 5 (реальные значения в defaults.go доходят до 5, напр. BriefingDaily); при следующем Seed (каждый старт) 4 < 5 — тюненный шаблон молча заменяется встроенным дефолтом. Guard-тест `TestSeedIdempotentWithExisting` покрывает только случай, когда кастомная версия уже выше дефолтной, так что деструктивный путь не протестирован. Старый текст выживает только в `prompt_history` (восстановим через Rollback), но потеря происходит молча.

```go
// Auto-upgrade: if the default version is higher and the user hasn't
// customized the template (i.e., it still matches a previous default),
// update it to the new default.
if existing.Version < defaultVer {
    if err := s.db.UpsertPrompt(db.Prompt{
        ID:       id,
        Template: tmpl,
        Version:  defaultVer,
    }); err != nil { ...
```

- **Рекомендация:** Реализовать то, что обещает комментарий: апгрейдить только если текущий шаблон в БД совпадает с каким-либо прошлым дефолтом (хранить/сравнивать хэши дефолтов) либо ввести флаг `customized`, выставляемый в UpdatePrompt/Tune. Добавить тест «tuned prompt + bumped default → не перезаписан».

### Архивированные stale-items inbox остаются status='pending' и протекают в GetInboxItems, GetInboxCounts и daily briefing

- **Где:** `internal/db/inbox.go:700`
- **Статус верификации:** ✅ подтверждено

`ArchiveStaleActionable` выставляет `archived_at/archive_reason='stale'`, намеренно оставляя `status='pending'`. Однако `GetInboxItems` (CLI-список `watchtower inbox`), `GetInboxCounts` (pending/unread счётчики) и `GetInboxItemsForBriefing` (`WHERE status = 'pending' ... LIMIT 20`, инжектится в промпт daily briefing) фильтруют только по status и никогда не исключают `archived_at IS NOT NULL`. В итоге items, заархивированные пайплайном как stale, продолжают показываться в CLI, вечно раздувают pending-счётчик и бессрочно занимают 20-элементный бюджет inbox в briefing — вопреки жизненному циклу архива (actionable stale после 14 дней должен исчезать). Новые feed-запросы (`ListActionableOpen`, `ListInboxFeed`, `ListInboxPinned`, `GetUnreadInboxItems`) все корректно добавляют `archived_at IS NULL` — эти три запроса пропустили паттерн.

```sql
-- ArchiveStaleActionable:
UPDATE inbox_items SET archived_at=?, archive_reason='stale' ... WHERE ... status='pending' ...
-- vs GetInboxItemsForBriefing:
FROM inbox_items WHERE status = 'pending' ORDER BY ... LIMIT 20  -- no archived_at filter
```

- **Рекомендация:** Добавить `AND archived_at IS NULL` в три отстающих запроса (GetInboxItems, GetInboxCounts, GetInboxItemsForBriefing) и покрыть тестом «archived-stale не попадает в briefing/counts».

### Дедупликация топиков уровня 2 (слой TRACKS-01) структурно мертва: пайплайн хранит source_refs как {ts,...}, а дедуп ждёт {digest_id, topic_id}

- **Где:** `internal/tracks/pipeline.go:475`
- **Статус верификации:** ✅ подтверждено

`buildRelevanceSignals` парсит source_refs трека, ожидая `{"digest_id":N,"topic_id":N}`, и помечает топик обработанным только при обоих > 0. Но extract-промпт велит AI выдавать source_refs как `{ts, channel_id, thread_ts, author, text}` (prompts/defaults.go:826,856), а `filterValidSourceRefs` (line 1703) ре-маршалит через структуру только с этими полями, отбрасывая любые digest_id/topic_id. Значит у каждого трека, созданного этим пайплайном, refs имеют ts-форму, `processedTopics` всегда пуст, ветка «tracks: deduped %d topics already linked» никогда не срабатывает, а задокументированный в docs/inventory/tracks.md слой TRACKS-01 («topics already linked to a track are stripped from the prompt») не включается никогда. В overlap-режиме уже привязанные топики повторно скармливаются AI каждый прогон — трата токенов и опора только на fingerprint/Jaccard-дедуп, чьи merge флипают has_updates и всплывают уже прочитанные треки. Guard-тест `TestTopicDedupBySourceRefs` проходит лишь потому, что вручную сеет legacy-форму `{digest_id,topic_id}` (pipeline_test.go:1025), которую продакшен никогда не пишет.

```go
var refs []struct {
	DigestID int `json:"digest_id"`
	TopicID  int `json:"topic_id"`
}
…
if ref.DigestID > 0 && ref.TopicID > 0 {  // never true: filterValidSourceRefs only preserves {ts, channel_id, thread_ts, author, text}
```

- **Рекомендация:** Согласовать форму source_refs между слоями: либо дописывать digest_id/topic_id в refs при сохранении трека (расширив filterValidSourceRefs), либо переписать дедуп уровня 2 на (channel_id, ts)-ключи, реально присутствующие в данных. Пересобрать guard-тест на данные, которые генерит сам пайплайн.

### Пер-канальные сбои digest и «deferred»-каналы из budget-cap навсегда теряют своё окно сообщений из-за глобального watermark

- **Где:** `internal/digest/pipeline.go:1575`
- **Статус верификации:** ✅ подтверждено

`lastDigestTime()` берёт `period_to` единственного самого свежего channel-дайджеста по ВСЕМ каналам как глобальный `sinceUnix` следующего прогона. Когда AI-вызов одного канала падает (dispatchChannelBatches терпит частичные сбои, lines 779-784) или батч канала выброшен бюджетным капом maxBatches (line 715 логирует «channels deferred», намекая на позднейшую обработку), успешные каналы всё равно сохраняют дайджесты с `period_to ≈ now`, так что окно следующего прогона стартует ПОСЛЕ непереваренных сообщений упавшего/отложенного канала. Эти сообщения никогда не переизбираются (`GetMessagesByTimeRange` использует новый глобальный since) — постоянные пер-канальные пробелы дайджестов; слово «deferred» в логе фактически ложно: никто их не ре-квьюит.

```go
digests, err := p.db.GetDigests(db.DigestFilter{Type: "channel", Limit: 1})
if err == nil && len(digests) > 0 { … return digests[0].PeriodTo }
// global watermark; cf. line 715: "budget cap: keeping %d of %d batches (%d channels deferred)"
```

- **Рекомендация:** Перейти на пер-канальный watermark (`period_to` последнего дайджеста ИМЕННО этого канала) при выборе окна сообщений — глобальный оставить только как нижнюю границу для discovery. Тогда упавшие/отложенные каналы автоматически догоняют на следующем прогоне.

### Channel-дайджесты, пересекающие полночь UTC, исключаются из всех daily rollups

- **Где:** `internal/digest/pipeline.go:980`
- **Статус верификации:** ✅ подтверждено

`runDailyRollupForDate` выбирает channel-дайджесты фильтром `{FromUnix: dayStart, ToUnix: dayEnd}`, который `GetDigests` транслирует в `period_from >= dayStart AND period_to <= dayEnd` (db/digests.go:104,108) — то есть только дайджесты, ПОЛНОСТЬЮ лежащие внутри дня. Дайджест, чьё окно пересекает полночь UTC (нормальный случай после ночного сна ноутбука: последний дайджест вчера 23:00 UTC, следующий цикл демона утром создаёт один дайджест «вчера-вечер → сегодня-утро»), не проходит `period_from >= dayStart` сегодняшнего rollup, а вчерашний rollup был сгенерирован до появления дайджеста (и всё равно не прошёл бы `period_to <= dayEnd`). Этот контент не попадает ни в один daily rollup — а значит и в weekly/briefing-агрегацию.

```go
channelDigests, err := p.db.GetDigests(db.DigestFilter{Type: "channel", FromUnix: fromUnix, ToUnix: toUnix})
// GetDigests: "period_from >= ?" AND "period_to <= ?"
```

- **Рекомендация:** Использовать критерий пересечения окон вместо строгого вложения: `period_to > dayStart AND period_from < dayEnd` (с защитой от двойного учёта, например, приписывая дайджест дню, в который попадает `period_to`). Либо резать окна channel-дайджестов по полуночи при генерации.

### Сигнал @mention в scoreChannel никогда не матчит key_messages (там только «голые» timestamps) — каналы «только с упоминаниями» пропускаются

- **Где:** `internal/tracks/pipeline.go:1438`
- **Статус верификации:** ✅ подтверждено

`scoreChannel` проверяет `strings.Contains(t.KeyMessages, "<@"+userID+">")`. Но digest-`storeDigest` сохраняет `digest_topics.key_messages` через `filterValidTimestamps` (digest/pipeline.go:1336,1893), оставляющий только строки вида `^\d{10}\.\d{6}$` — key_messages физически не может содержать `<@U…>`. Situations — проза с plain user_id («U123456»), не `<@…>`-синтаксис. Задокументированный сигнал релевантности «+2: user @mentioned in key_messages or situations» (docs/inventory/tracks.md, TRACKS-02) фактически мёртв. Канал, где пользователя прямо @упомянули, но без существующих треков, звезды, репортов/пиров и action_items, набирает 0 и пропускается до всякого AI-вызова — треки для прямых упоминаний молча не создаются. Тест TestScoreChannel проходит только потому, что вручную скармливает нефильтрованный KeyMessages, который продакшен хранить не может.

```go
mentionTag := "<@" + userID + ">"
for _, t := range topics {
	if strings.Contains(t.KeyMessages, mentionTag) || strings.Contains(t.Situations, mentionTag) {
		// KeyMessages == JSON array of "1234567890.123456" only
```

- **Рекомендация:** Считать сигнал упоминания из реальных данных: искать `"user_id":"<userID>"` в Situations (JSON участников) либо джойнить сообщения по key_messages-timestamps и искать `<@userID>` в их тексте. Обновить guard-тест на production-форму данных.

### Детекция calendar_time_change — мёртвый код: synced_at обновляется каждым sync, поэтому updatedAt > syncedAt никогда не истинно

- **Где:** `internal/inbox/calendar_detector.go:95`
- **Статус верификации:** ✅ подтверждено

Ветка `calendar_time_change` детектора срабатывает при `e.updatedAt > e.syncedAt` («Event was modified after it was first synced»). Но `UpsertCalendarEvent(s)` использует `INSERT OR REPLACE` и выставляет `synced_at = strftime('now')` при КАЖДОМ sync (db/calendar.go:85-90,109-113): synced_at — всегда время последнего sync, которое всегда не раньше гуглового updated_at, записанного тем же sync'ом. Сравнение практически никогда не истинно (кроме clock skew), поэтому перенесённые встречи, которые пользователь уже принял, никогда не порождают inbox-item `calendar_time_change` — trigger-тип существует в схеме, классификаторе ('actionable') и auto-resolve, но недостижим в продакшене. Единственный тест этой ветки сеет строки raw-INSERT'ом в обход upsert, создавая состояние, невозможное в продакшене.

```go
case e.updatedAt > e.syncedAt:
	// Event was modified after it was first synced — treat as a time/detail change.
	trig = "calendar_time_change"
// but upsert: INSERT OR REPLACE ... VALUES (..., strftime('%Y-%m-%dT%H:%M:%SZ','now'), ?) — synced_at reset every sync
```

- **Рекомендация:** Хранить в таблице предыдущий updated_at (например, `first_synced_at` или `prev_updated_at`, сохраняемый в ON CONFLICT-апдейте) и детектировать изменение сравнением нового updated_at с сохранённым, а не с моментом sync. Переписать тест через реальный upsert-путь.

### Новое Slack-сообщение может перезаписать несвязанный pending-item другого trigger-типа через FindPendingInboxByThread

- **Где:** `internal/inbox/pipeline.go:508`
- **Статус верификации:** ✅ подтверждено

`detectSlackTriggers` ищет существующий pending-item только по `(channel_id, thread_ts)` — `FindPendingInboxByThread` (db/inbox.go:81) не фильтрует по trigger_type или Slack-происхождению. Pending `decision_made` разделяет `(channel_id=C, thread_ts='')` с любым не-тредовым Slack-кандидатом в канале C. Когда в C приходит новое top-level упоминание/DM, код идёт по update-пути: `UpdateInboxItemSnippet` заменяет у decision-item message_ts, sender_user_id, snippet, raw_text и permalink контентом упоминания, при этом строка сохраняет trigger_type='decision_made' и item_class='ambient'. Actionable-упоминание никогда не получает собственный item (created не инкрементируется, а NOT EXISTS-дедуп теперь матчит перезаписанный message_ts) — @mention молча деградирует в неверно помеченную ambient decision-карточку.

```go
existingID, _ := p.db.FindPendingInboxByThread(c.ChannelID, c.ThreadTS)
if existingID > 0 {
	if err := p.db.UpdateInboxItemSnippet(existingID, c.MessageTS, c.SenderUserID, snippet, itemCtx, c.Text, c.Permalink); ...
// query: WHERE channel_id = ? AND thread_ts = ? AND status = 'pending' — no trigger_type filter
```

- **Рекомендация:** Добавить фильтр по trigger_type (или хотя бы по Slack-типам mention/dm/thread_reply) в `FindPendingInboxByThread`, и не применять этот lookup к не-тредовым кандидатам (`thread_ts=''`). Та же корневая причина, что и в баге дедупликации выше, — исправлять согласованно.

### DetectJira лексикографически сравнивает сырые Jira-timestamps (offset-формат) с UTC-'Z' watermark — items могут теряться навсегда

- **Где:** `internal/inbox/jira_detector.go:44`
- **Статус верификации:** ✅ подтверждено

`jira_issues.updated_at` хранит `f.Updated` дословно из Jira API (jira/sync.go:536) — ISO8601 с миллисекундами и числовым офсетом, например `2026-07-05T16:00:00.000-0400` (layout `-0700` в briefing/jira.go подтверждает формат). Детектор фильтрует строковым сравнением `updated_at > ?` против sinceISO в формате RFC3339 UTC (`2026-07-05T19:00:00Z`). Лексикографическое сравнение offset-строк с UTC-строками не хронологично: для Jira-инстанса с отрицательным офсетом issue, обновлённый в 20:00Z, хранится как `...T16:00:00.000-0400` и сортируется НИЖЕ watermark `...T19:00:00Z` — свежепорученный issue пропускается, и поскольку inbox-watermark только растёт, он не будет подхвачен никогда. `autoResolveJira` имеет то же смешанно-форматное сравнение (pipeline.go:895-897): auto-resolve срабатывает рано или никогда в зависимости от знака офсета.

```go
sinceISO := sinceTS.UTC().Format(time.RFC3339)
rows, err := database.Query(`SELECT key, summary, updated_at FROM jira_issues
    WHERE assignee_account_id = ? AND updated_at > ? AND is_deleted = 0`, currentUserID, sinceISO)
// sync stores: UpdatedAt: f.Updated (raw Jira '...+0300'/'-0400' format)
```

- **Рекомендация:** Нормализовать `updated_at` в UTC RFC3339 при записи в jira/sync.go (распарсив layout `2006-01-02T15:04:05.000-0700`), либо парсить и сравнивать по времени на стороне Go вместо строкового SQL-сравнения. Проверить все места, сравнивающие jira-таймстампы со строками 'Z'-формата.

### Реакции на сообщения старше watermark никогда не детектируются — reaction-триггер работает только ~30 минут

- **Где:** `internal/db/inbox.go:525`
- **Статус верификации:** ✅ подтверждено

`FindReactionRequests` фильтрует по `m.ts_unix > sinceTS` — по времени СООБЩЕНИЯ, а не по времени добавления реакции (в таблице reactions нет timestamp-колонки: только `PRIMARY KEY(channel_id, message_ts, user_id, emoji)`). В steady state inbox-watermark стоит на ~now-30min, поэтому как только сообщению ~30+ минут, любая последующая ❓/👀/‼️-реакция на него уже не может породить inbox-item. Поскольку люди обычно реагируют через минуты-часы после публикации, детекция «reaction request» фактически мертва вне узкого окна сразу после отправки — `:question:` на вчерашнее сообщение не всплывает никогда. Существующие тесты гоняют только `sinceTS=0`.

```sql
FROM messages m
JOIN reactions r ON r.channel_id = m.channel_id AND r.message_ts = m.ts
WHERE m.user_id = ? AND r.user_id != ? AND r.emoji IN (...) AND m.ts_unix > ?
-- reactions schema: PRIMARY KEY (channel_id, message_ts, user_id, emoji) — no reaction timestamp
```

- **Рекомендация:** Добавить в таблицу reactions колонку `synced_at`/`first_seen_at` (миграция) и фильтровать по ней; в качестве промежуточной меры — расширить окно по сообщению до нескольких дней, полагаясь на существующий NOT EXISTS-дедуп против дублей.

### «Сегодняшние события» briefing/day-plan используют UTC-окно дня для локальной даты — ранние утренние события пропадают

- **Где:** `internal/db/calendar.go:159`
- **Статус верификации:** ✅ подтверждено

`GetCalendarEventsForDate` строит окно как `date+'T00:00:00Z' .. date+'T23:59:59Z'` (UTC), тогда как все вызывающие передают ЛОКАЛЬНУЮ дату: briefing `gatherCalendar` — `time.Now().Local().Format("2006-01-02")` (briefing/pipeline.go:535), dayplan `Run/gatherCalendarEvents/DetectConflicts` — `time.Now().Format`-даты. Времена событий хранятся нормализованными в UTC. Для пользователя проекта (UTC+3) встреча сегодня 01:00–02:00 локально хранится с окончанием 23:00Z ПРЕДЫДУЩЕГО UTC-дня, так что `end_time >= 'todayT00:00:00Z'` не проходит — событие отсутствует в календарной секции briefing и в day plan (ни таймблока, ни конфликт-детекции); наоборот, события 00:00–03:00 локального завтра протекают в сегодняшний план.

```go
func (db *DB) GetCalendarEventsForDate(date string) ([]CalendarEvent, error) {
	from := date + "T00:00:00Z"
	to := date + "T23:59:59Z"
	return db.GetCalendarEvents(CalendarEventFilter{FromTime: from, ToTime: to})
} // callers pass local dates: today := time.Now().Local().Format("2006-01-02")
```

- **Рекомендация:** Строить границы окна из локальной даты: `time.ParseInLocation("2006-01-02", date, time.Local)`, затем конвертировать начало/конец локального дня в UTC RFC3339 для сравнения. Добавить тест с не-UTC зоной и событием в 01:00 локального времени.

### limitedWriter в ai.Client нарушает контракт io.Writer — >64KB stderr от claude превращает успешный запрос в ошибку

- **Где:** `internal/ai/client.go:327`
- **Статус верификации:** ✅ подтверждено

Когда одиночный Write пересекает 64KB-кап, `limitedWriter` обрезает `p` и возвращает `n < len(p)` при `err == nil`. `os/exec` копирует не-`*os.File` Stderr через `io.Copy` в горутине; `io.Copy` превращает short write с nil-ошибкой в `io.ErrShortWrite`, и `cmd.Wait()`/`cmd.Output()` возвращают эту copy-ошибку даже при exit 0 и валидном stdout. Воспроизведено standalone-программой с точной копией limitedWriter: ребёнок пишет 100KB в stderr двумя всплесками и «OK» в stdout → `out="OK" err=short write`. Следствие: любой вызов claude, эмитящий >64KB stderr (многословный MCP/npx-логгинг) в не выровненных по 32K чанках, заставляет `QuerySync` выбросить валидный ответ с ошибкой «claude CLI error: short write», а `Query` — рапортовать ошибку после завершённого стриминга (REPL печатает ошибку вместо ответа). limitedWriter в пакете codex (codex/generator.go:150-165) уже исправлен ровно для этого — возвращает полную исходную длину; копия в ai — устаревший баговый вариант.

```go
func (lw *limitedWriter) Write(p []byte) (int, error) {
    remaining := lw.limit - lw.written
    if remaining <= 0 {
        return len(p), nil // silently discard
    }
    if len(p) > remaining {
        p = p[:remaining]
    }
    n, err := lw.w.Write(p)
    lw.written += n
    return n, err   // n < len(p) with nil err -> io.ErrShortWrite from exec's io.Copy
}
```

- **Рекомендация:** Портировать исправленный вариант из codex: после усечённой записи возвращать полную исходную длину `len(p)` (при nil-ошибке нижележащего Write). В идеале — вынести limitedWriter в общий пакет, чтобы копии не расходились.

### ai.Client.Query может навсегда зависнуть в cmd.Wait() после ошибки сканера — ребёнок заблокирован записью в недочитанный stdout-pipe

- **Где:** `internal/ai/client.go:228`
- **Статус верификации:** ✅ подтверждено

Сканер ограничивает строки 1MB (line 194). stream-json от claude с `--verbose` эмитит каждое событие одной JSON-строкой, включая tool results — MCP `read_query`, вываливающий большую таблицу, легко превышает 1MB, после чего `scanner.Scan()` останавливается с `bufio.ErrTooLong`. Код затем вызывает `_ = cmd.Wait()` без дочитывания stdout. Wait блокируется до выхода ребёнка, но ребёнок заблокирован записью остатка сверхдлинной строки (и последующих событий) в заполненный ~64KB OS-буфер пайпа и не завершается никогда. `cmd.WaitDelay` не спасает: он ограничивает ожидание только после отмены Context или вызова Cancel — ни то, ни другое не произошло. Итог: producer-горутина висит вечно, textCh/errCh/sidCh не закрываются, REPL (`runAIQuery` ranged по textCh) висит до Ctrl+C, всё это время живёт зомби-процесс claude. Паттерн исправления (дочитывание/закрытие пайпа до Wait) отсутствует.

```go
if err := scanner.Err(); err != nil {
    _ = cmd.Wait()   // child may still be writing >64KB into the pipe; Wait blocks forever
    errCh <- fmt.Errorf("reading claude output: %w", err)
    return
}
```

- **Рекомендация:** Перед `cmd.Wait()` на всех ранних выходах дренировать пайп (`go io.Copy(io.Discard, stdout)`) либо убивать процесс (`cmd.Process.Kill()` / отмена per-command контекста) — тогда Wait гарантированно вернётся. Заодно поднять лимит сканера или перейти на `bufio.Reader.ReadBytes`.

### codex.Client.Query имеет тот же deadlock недочитанного stdout на путях error-event и scanner-error

- **Где:** `internal/codex/client.go:132`
- **Статус верификации:** ✅ подтверждено

На JSONL-событии `error` (line 131-135) и на ошибке сканера (line 149-153, например одна agent_message-строка >1MB) горутина вызывает `_ = cmd.Wait()` при недочитанном stdout. Если процессу codex осталось записать больше буфера пайпа (~64KB) — хвостовые события после ошибки или остаток сверхдлинной строки — он блокируется на write и не завершается, Wait висит вечно (WaitDelay применим только после отмены ctx). textCh/errCh/sidCh не закрываются, вызывающий на `for range textCh` (cmd/ai.go:102) висит перманентно (спасает только Ctrl+C); остаётся зомби-процесс codex. Кроме того, на этих ранних выходах отложенный `os.RemoveAll(tmpDir)` для MCP-конфига (line 77) не выполняется, пока висит горутина, — утечка temp-директории на всё время зависания.

```go
if event.Error != nil {
    _ = cmd.Wait()   // stdout undrained; child blocked writing -> Wait never returns
    errCh <- fmt.Errorf("codex error: %s", event.Error.Message)
    return
}
```

- **Рекомендация:** То же исправление, что для ai.Client: дренировать stdout (`io.Copy(io.Discard, ...)`) или убивать процесс перед Wait на всех ранних выходах. Исправлять оба клиента одним PR — дефект зеркальный.

### `watchtower jira boards` обнуляет issue_count у всех досок и пишет литеральную строку "now" в synced_at

- **Где:** `cmd/jira.go:448`
- **Статус верификации:** ✅ подтверждено

`runJiraBoards` собирает `db.JiraBoard` с `IssueCount`, оставленным нулём, и `SyncedAt`, равным литеральной строке "now" (не timestamp), после чего ON CONFLICT-ветка `UpsertJiraBoard` перезаписывает `issue_count=excluded.issue_count` и `synced_at=excluded.synced_at`. Каждый запуск `jira boards` (используется и Desktop-пикерами досок: «Refresh Boards» запускает эту команду) сбрасывает issue_count всех досок в 0 — таблица, печатаемая той же командой сразу после, показывает Issues=0 для досок с тысячами синхронизированных issues — и портит synced_at не-таймстампом до следующего sync, вызывающего `UpdateJiraBoardIssueCount`.

```go
dbBoard := db.JiraBoard{
    ID:         b.ID,
    Name:       b.Name,
    ProjectKey: b.Location.ProjectKey,
    BoardType:  b.Type,
    SyncedAt:   "now",
}
_ = database.UpsertJiraBoard(dbBoard)
// db: ON CONFLICT ... SET issue_count=excluded.issue_count, synced_at=excluded.synced_at
```

- **Рекомендация:** Исключить `issue_count` и `synced_at` из SET-списка ON CONFLICT в `UpsertJiraBoard` (метаданные доски — да, счётчики sync — нет), а `SyncedAt` заполнять `time.Now().UTC().Format(time.RFC3339)`. Тест: upsert существующей доски не сбрасывает issue_count.

### `targets update --status done|dismissed` обходит INBOX-02-каскад target_due — reminder-item остаётся pending

- **Где:** `cmd/targets.go:799`
- **Статус верификации:** ✅ подтверждено

docs/inventory/inbox-pulse.md (INBOX-02, расширен 2026-05-01) фиксирует контракт: закрытие таргета (status → done/dismissed) авто-резолвит его inbox-item `target_due`. Каскад живёт только в `db.UpdateTargetStatus` (targets.go:286-294). `runTargetsUpdate` меняет статус через `db.UpdateTarget` — обычный UPDATE без inbox-каскада. Пользователь, закрывающий reminder-таргет через `watchtower targets update N --status done`, оставляет pending `target_due`-item и вынужден закрывать одно и то же дважды — ровно то, что запрещает залоченный контракт. (Верификатор уточнил: Swift-путь `TargetQueries.updateStatus` каскад делает, дефект ограничен Go CLI update-путём.)

```go
if cmd.Flags().Changed("status") {
    target.Status = targetsFlagStatus
}
...
if err := database.UpdateTarget(*target); err != nil { ... }
// db.UpdateTarget has no `UPDATE inbox_items ... trigger_type = 'target_due'` cascade; only UpdateTargetStatus does
```

- **Рекомендация:** В `runTargetsUpdate` при изменённом `--status` вызывать `UpdateTargetStatus` (или вынести каскад в общий хелпер, вызываемый обоими путями). Расширить guard-тест INBOX-02 на update-путь.

### Extract-пайплайн не валидирует возвращённые AI level/priority против CHECK-enum'ов БД — одно плохое значение откатывает весь подтверждённый батч

- **Где:** `internal/targets/extractor.go:199`
- **Статус верификации:** ✅ подтверждено

`parseExtractResponse` аккуратно валидирует relations, префиксы external_ref, parent-ID и лимиты, но копирует `item.Level` и `item.Priority` без валидации. Таблица targets имеет `CHECK(level IN ('quarter','month','week','day','custom'))` и `CHECK(priority IN ('high','medium','low'))`. Если AI вернул, например, level="sprint" или priority="urgent" для одного из десяти извлечённых items, `Store.CreateBatch` выполняет все вставки одной транзакцией и на CHECK-нарушении откатывает всё — пользователь интерактивно подтверждает 10 таргетов и получает ноль созданных с сырой SQLite constraint-ошибкой. Пустые значения дефолтятся в `insertTargetTx`, но непустые невалидные нигде не санитайзятся.

```go
pt := ProposedTarget{
    Text:        item.Text,
    Intent:      item.Intent,
    Level:       item.Level,      // unvalidated
    ...
    Priority:    item.Priority,   // unvalidated
// store.go: level defaults only when ""; INSERT hits CHECK(level IN (...)) inside one tx for the whole batch
```

- **Рекомендация:** В `parseExtractResponse` нормализовать значения: невалидный level → "custom" (или ""), невалидный priority → "medium", с логом — по аналогии с уже имеющейся защитной санацией других полей. Тест: батч с одним невалидным значением создаёт остальные targets.

### Таргет можно сделать родителем самого себя — нет self/cycle-проверки в `targets link --parent` и в валидации AI suggest-links

- **Где:** `cmd/targets.go:607`
- **Статус верификации:** ✅ подтверждено

`runTargetsLink` выставляет `target.ParentID` из `--parent` без проверки на совпадение с собственным ID (и на циклы): `watchtower targets link 5 --parent 5` успешно проходит — FK `REFERENCES targets(id)` удовлетворён самой строкой. AI-путь имеет ту же дыру: `parseLinkResponse` (targets/linker.go:83) валидирует parent_id против snapshot-множества, но snapshot из `GetTargets` включает сам линкуемый таргет (`buildLinkPrompt` лишь прячет его из текста промпта), так что AI-parent_id, равный собственному ID, проходит валидацию и применяется. Self-parented строка ломает обход иерархии: в Desktop `rootEntries` такой таргет не является ни корнем, ни чьим-то ребёнком — молча исчезает из списка, а `RecomputeParentProgress` учитывает таргет в его же среднем.

```go
if targetsFlagLinkParent > 0 {
    target, err := database.GetTargetByID(id)
    ...
    target.ParentID = sql.NullInt64{Int64: int64(targetsFlagLinkParent), Valid: true}
    if err := database.UpdateTarget(*target); err != nil { ... }
// linker.go: if resp.ParentID != nil && snapshotIDs[*resp.ParentID] { ... }  — snapshot includes the target itself
```

- **Рекомендация:** В обоих путях отклонять `parentID == id` и делать простой walk по цепочке предков для отсечения циклов (глубина иерархии мала). В linker — исключать собственный ID из snapshot-множества, а не только из текста промпта.

### Автозакрытие браузера после OAuth-логина гонится с завершением процесса, а когда всё-таки срабатывает — вызывает macOS TCC Automation prompt

- **Где:** `internal/auth/oauth.go:284`
- **Статус верификации:** ✅ подтверждено

После успешного callback `Login` запускает `go func() { time.Sleep(2 * time.Second); getCloseBrowserFunc()() }()` и возвращается. CLI-команда сохраняет конфиг и завершается обычно быстрее 2 секунд (отложенный server.Close спит лишь 500ms), так что горутина убивается вместе с процессом — фича «auto-close browser window» молча не выполняется. В случаях же, когда процесс живёт ≥2s, `closeBrowserWindow` запускает `osascript` с `tell application "System Events"`, что требует TCC-разрешения Apple Events / Automation и показывает macOS-диалог согласия, атрибутированный ответственному процессу. Критично: Desktop-приложение само спавнит `watchtower auth login` (OnboardingView.swift:1244, SettingsView.swift:695), поэтому по цепочке ответственности prompt атрибутируется Watchtower.app — по правилу проекта («no TCC prompts from Watchtower» = P0) это недопустимо. Путь дефектен в обоих исходах: мёртв в типовом случае, генерирует prompt в остальных.

```go
go func() {
    time.Sleep(2 * time.Second)
    getCloseBrowserFunc()()
}()
... script := ` tell application "System Events" ... ` ; cmd := exec.Command("osascript", "-e", script)
```

- **Рекомендация:** Удалить osascript-автозакрытие целиком: заменить страницу callback на самодостаточный HTML с `window.close()`/сообщением «можно закрыть вкладку» — это не требует TCC и не зависит от времени жизни процесса. Ни в коем случае не «чинить» через ожидание горутины — это лишь сделает TCC-prompt детерминированным.

## Low

### Закрытый wake-канал гонится с ctx.Done() при shutdown — ложные sync'и перезаписывают last_sync.json ошибкой «context canceled»

- **Где:** `internal/daemon/daemon.go:188`
- **Статус верификации:** ✅ подтверждено

Горутина `WatchWake` делает `defer close(ch)` (wake.go:14) при отмене ctx. В select-цикле `Daemon.Run` закрытый канал перманентно готов, поэтому при shutdown select случайно выбирает между `<-ctx.Done()` и `<-d.wakeChannel()`. С вероятностью ~50% на итерацию демон логирует «wake event detected, syncing» и вызывает runSync с уже отменённым контекстом: orchestrator.Run падает с context.Canceled, а phaseSlackSync безусловно пишет last_sync.json с Error: "context canceled" (daemon.go:297-301). Примерно после каждого второго graceful shutdown `watchtower status` и Desktop показывают последний sync как проваленный, хотя ничего не сломалось. Самовосстанавливается следующим sync'ом.

```go
case <-d.wakeChannel():
    d.logger.Println("wake event detected, syncing")
    d.runSync(ctx)
// wake.go:
go func() {
    defer close(ch)
```

- **Рекомендация:** В wake-case использовать двухзначный приём `w, ok := <-...` и выходить из цикла при `ok == false`; дополнительно проверять `ctx.Err() != nil` перед runSync в начале каждой ветки.

### UNIQUE-констрейнт target_links не дедуплицирует external-ref связи (NULL target_target_id) — дубликаты накапливаются

- **Где:** `internal/db/target_links.go:26`
- **Статус верификации:** ✅ подтверждено

`UNIQUE(source_target_id, target_target_id, external_ref, relation)` — единственная защита от дублей, но external-only связи вставляются с `target_target_id = NULL`, а SQLite считает NULL'ы различными в UNIQUE-индексах. `CreateTargetLink` делает голый INSERT без conflict-обработки, так что каждый повторный прогон AI link-suggester'а (или повторное действие пользователя), предлагающий тот же external ref (jira:ABC-1, relation=related), вставляет ещё одну идентичную строку — UI показывает продублированные связи. Комментарий миграции 00007 даже документирует, что такие дубли уже встречались «в дикой природе»; та зачистка была одноразовым ремонтом данных, путь вставки по-прежнему дыряв.

```go
res, err := db.Exec(`INSERT INTO target_links (source_target_id, target_target_id, external_ref, relation, confidence, created_by) VALUES (?, ?, ?, ?, ?, ?)`, ...)
// schema: UNIQUE(source_target_id, target_target_id, external_ref, relation) with target_target_id NULL → never conflicts
```

- **Рекомендация:** Добавить частичный уникальный индекс `CREATE UNIQUE INDEX ... ON target_links(source_target_id, external_ref, relation) WHERE target_target_id IS NULL` (миграция) и/или проверку существования перед INSERT в `CreateTargetLink`.

### Weekly trends digest никогда не генерируется: у RunWeeklyTrends нет production-вызова

- **Где:** `internal/digest/pipeline.go:1053`
- **Статус верификации:** ✅ подтверждено

`RunWeeklyTrends` вызывается только из тестов. Комментарий daemon-фазы `phaseTracksAndRollups` говорит «runs daily/weekly rollups», но `RunRollups` вызывает лишь `RunDailyRollup` (pipeline.go:423); в cmd/ вызовов тоже нет. Дайджесты типа 'weekly' никогда не существуют; `watchtower trends` всегда идёт по деградированному fallback-пути, а задокументированный трёхуровневый digest-пайплайн (channel/daily/weekly) молча потерял weekly-уровень.

```go
func (p *Pipeline) RunWeeklyTrends(ctx context.Context) error {
// grep: only callers are pipeline_test.go; daemon RunRollups calls only RunDailyRollup
```

- **Рекомендация:** Вызывать `RunWeeklyTrends` из `RunRollups` (например, раз в неделю по последнему weekly-дайджесту, аналогично daily-логике) либо осознанно удалить weekly-уровень и обновить документацию/CLI.

### autoResolveSlack матчит trigger_type 'reaction_request', а детектор/схема используют 'reaction' — reaction-items никогда не авто-резолвятся

- **Где:** `internal/inbox/pipeline.go:837`
- **Статус верификации:** ✅ подтверждено

`FindReactionRequests` выставляет `c.TriggerType = "reaction"` (db/inbox.go:545), и CHECK-констрейнт схемы допускает только 'reaction'. Switch в autoResolveSlack whitelist'ит "reaction_request" — значение, которое не может существовать в БД (единственное вхождение строки в кодовой базе). Итог: когда кто-то реагирует ❓ на сообщение пользователя и пользователь затем отвечает в треде, item не авто-резолвится rule-проходом — вопреки INBOX-02; item висит до 7-дневного ambient-архива.

```go
switch item.TriggerType {
case "mention", "dm", "thread_reply", "reaction_request":
default:
	continue
}
// but detector: c.TriggerType = "reaction"; schema CHECK: ('mention','dm','thread_reply','reaction', ...)
```

- **Рекомендация:** Заменить "reaction_request" на "reaction" в switch; завести константы trigger-типов в одном месте вместо строковых литералов, чтобы такие расхождения ловились компилятором.

### SessionPool.Acquire возвращает (nil, nil) ожидающим, когда пул закрывают под ними

- **Где:** `internal/sessions/pool.go:45`
- **Статус верификации:** ✅ подтверждено

Acquire проверяет `p.closed`, разлочивается и блокируется на `w := <-p.workers`. Если `Close()` выполняется, пока горутины заблокированы там (все слоты заняты), `close(p.workers)` будит каждого получателя нулевым значением: Acquire возвращает w=nil, err=nil, нарушая собственный контракт («Returns error if pool is closed»). `PooledGenerator.Generate` проверяет только err, так что все ранее заблокированные вызывающие одновременно уходят в inner.Generate с nil Worker. С текущими вызывающими Close всегда происходит после завершения пайплайна, поэтому сценарий латентный, — но это однострочная бомба на будущее.

```go
select {
case w := <-p.workers:   // closed channel yields nil Worker, no error
    return w, nil
case <-ctx.Done():
    return nil, fmt.Errorf("acquire timeout: %w", ctx.Err())
}
```

- **Рекомендация:** Использовать двухзначную форму `w, ok := <-p.workers` и при `!ok` возвращать ошибку «pool closed». Добавить тест blocked-then-closed.

### Стриминговый Query и QuerySync/Generate в codex делают противоречащие предположения о событиях agent_message — одно из двух портит вывод

- **Где:** `internal/codex/client.go:138`
- **Статус верификации:** ⚠️ не удалось однозначно верифицировать (verdict 'uncertain')

Query стримит текст КАЖДОГО item.*-lifecycle-события с agent_message (без фильтра по event.Type), и его тест кодирует delta-семантику: item.started "Hello " + item.updated "world" + item.completed "!" конкатенируются в "Hello world!". Но `parseJSONLOutput`, используемый QuerySync и CodexGenerator.Generate, оставляет ТОЛЬКО последний item.completed с replace-семантикой. Оба потребляют один и тот же поток `codex exec --json`, значит правы оба быть не могут. Верификатор отметил: Swift-дизайн и design-doc проекта трактуют item.completed как ПОЛНЫЙ текст хода (replace), что делает completed-only парсер корректным; реалистичный дефект — стриминговый Query может дублировать вывод, если codex эмитит pre-completion события, но подтвердить, что codex реально их эмитит в exec --json, не удалось.

```go
// client.go Query — no event.Type filter:
if event.Item != nil && event.Item.Type == "agent_message" && event.Item.MessageText() != "" {
    textCh <- event.Item.MessageText()
// generator.go parseJSONLOutput — completed-only, last-wins:
if event.Type == "item.completed" && event.Item != nil && event.Item.Type == "agent_message" {
    lastContent = event.Item.MessageText()
```

- **Рекомендация:** Привести стриминговый путь к семантике completed-only (фильтровать `event.Type == "item.completed"`), согласовав с parseJSONLOutput и Swift-дизайном; исправить тест exec_test.go, кодирующий delta-модель.

### REPL никогда не восстанавливается после мёртвой Claude-сессии — протухший sessionID валит каждый последующий запрос

- **Где:** `internal/repl/repl.go:204`
- **Статус верификации:** ✅ подтверждено

`runAIQuery` запоминает `r.sessionID` после первого успешного ответа и далее всегда резюмирует его, а раз sessionID непуст — пропускает и пересборку system prompt (line 158-165). Если claude CLI больше не может резюмировать сессию (файлы сессии зачищены/протухли, кэш очищен, CLI обновлён), сабпроцесс выходит ненулевым, ошибка печатается — а r.sessionID не трогается, так что следующий вопрос резюмирует ту же мёртвую сессию с пустым system prompt и падает так же. Пути/слэш-команды для очистки sessionID нет — REPL перманентно сломан для AI-запросов до рестарта процесса. Важно: guard-тест repl_test.go:1099 намеренно фиксирует, что transient-ошибки sessionID не сбрасывают — корректный фикс должен различать resume-failure и transient error.

```go
if err := <-errCh; err != nil {
    fmt.Println(errorStyle.Render("Error: " + err.Error()))
    return    // r.sessionID (and the empty systemPrompt choice) unchanged -> every retry fails
}
```

- **Рекомендация:** Детектировать именно ошибку резюмирования (по exit-коду/тексту stderr claude при `--resume`) и в этом случае сбрасывать sessionID с автоматическим ретраем «с чистого листа»; transient-ошибки оставлять как есть (guard-тест сохранить). Дополнительно — добавить слэш-команду `/reset` как ручной выход.

### Ошибки Jira-sync никогда не персистятся: LastError/LastErrorAt выставляются на структуре, но UpdateJiraSyncState пишет только last_synced_at и issues_synced

- **Где:** `internal/jira/sync.go:124`
- **Статус верификации:** ✅ подтверждено

При падении sync проекта Sync() выставляет syncState.LastError и syncState.LastErrorAt, затем вызывает `db.UpdateJiraSyncState(projectKey, lastSyncedAt, issuesSynced)` — функция трогает только project_key, last_synced_at и issues_synced. Ни один код-путь в репозитории не пишет колонки last_error/last_error_at, хотя GetJiraSyncState(s) их читают (и Swift-модель JiraSyncState тоже). Любая поверхность статуса, полагающаяся на эти колонки, показывает вечно пустое состояние ошибки; повторные сбои sync невидимы вне лога демона.

```go
syncState.LastError = err.Error()
syncState.LastErrorAt = time.Now().UTC().Format(time.RFC3339)
_ = s.db.UpdateJiraSyncState(syncState.ProjectKey, syncState.LastSyncedAt, syncState.IssuesSynced)
// db: INSERT INTO jira_sync_state (project_key, last_synced_at, issues_synced) ... — error fields dropped
```

- **Рекомендация:** Расширить сигнатуру `UpdateJiraSyncState` (или добавить `UpdateJiraSyncError`) для записи last_error/last_error_at; очищать их при успешном sync.

### `targets snooze` принимает любую невалидированную строку как дату — искажённое значение оставляет таргет заснуженным навсегда

- **Где:** `cmd/targets.go:763`
- **Статус верификации:** ✅ подтверждено

`runTargetsSnooze` кладёт args[1] дословно в snooze_until без валидации формата. `UnsnoozeExpiredTargets` будит таргеты лексикографическим сравнением `snooze_until <= '2006-01-02T15:04'`. Пользователь, набравший `watchtower targets snooze 5 tomorrow`, получает success-сообщение («snoozed until tomorrow»), но "tomorrow" > "2026-..." лексикографически — демон никогда не разбудит таргет, и он молча исчезает из всех активных списков навсегда. Форматы вроде "07/10/2026" наоборот сравниваются НИЗКО и просыпаются на следующем же цикле. Соседний inbox snooze валидирует через parseDuration — несогласованность.

```go
snoozeDate := args[1]
...
target.Status = "snoozed"
target.SnoozeUntil = snoozeDate
// db: WHERE status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?  (string compare vs "2006-01-02T15:04")
```

- **Рекомендация:** Валидировать/парсить ввод (`time.Parse("2006-01-02", ...)` плюс поддержка длительностей как в inbox) и падать с понятной ошибкой при невалидном формате, нормализуя хранимое значение в канонический вид.

### События деселектнутого календаря никогда не зачищаются и продолжают всплывать в CLI/briefings/AI-контексте

- **Где:** `internal/calendar/sync.go:142`
- **Статус верификации:** ✅ подтверждено

Зачистка stale-событий в Sync проходит только по текущим ВЫБРАННЫМ calendarIDs. После деселекта календаря (`calendar select <id>`) он больше не фетчится И не чистится — все ранее синхронизированные события остаются в calendar_events бессрочно со старым synced_at. `GetCalendarEvents` не джойнит is_selected, поэтому `watchtower calendar`, briefing gatherCalendar и AI context builder продолжают показывать события выключенного календаря (пока каждое не выйдет из запрашиваемого временного окна — практически самолечится за ~2 дня, но строки в БД остаются навсегда).

```go
for _, calID := range calendarIDs {
    if n, err := s.db.DeleteStaleCalendarEvents(calID, syncedAt); err != nil {
// calendarIDs = selected calendars only; deselected calendar's rows never touched
```

- **Рекомендация:** При деселекте календаря сразу удалять его события (в `calendar select`), либо в Sync дополнительно чистить события всех is_selected=0 календарей.

### Пагинация syncChannel не защищена от HasMore=true с пустым NextCursor — бесконечный цикл на одной странице

- **Где:** `internal/sync/message_sync.go:346`
- **Статус верификации:** ✅ подтверждено

Цикл `conversations.history` завершается только через `done := !resp.HasMore` или пустой ответ. Если Slack вернёт has_more=true с пустым response_metadata.next_cursor (исторически наблюдалось на границах с удалёнными сообщениями), `cursor = resp.NextCursor` сбрасывает cursor в "" и цикл вечно повторяет идентичный запрос (блокируя воркера, сжигая ~40 req/min глобального rate-бюджета, апсертя ту же страницу) до отмены контекста демона. Сам код защищается от этого в replies-пути — `GetConversationReplies` брейкает на `!hasMore || nextCursor == ""` (client.go:288), а history-вызывающий — нет.

```go
done := !resp.HasMore
...
if done {
    o.logger.Printf("channel %s: done (%d messages)", ...)
    break
}
cursor = resp.NextCursor
// vs client.go:288 (replies): if !hasMore || nextCursor == "" { break }
```

- **Рекомендация:** Добавить тот же guard, что в replies: `if !resp.HasMore || resp.NextCursor == "" { break }` (плюс, опционально, верхний предел итераций как страховку).

### SearchUsersByName игнорирует is_bot_override — несогласованно с GetUsers

- **Где:** `internal/db/users.go:82`
- **Статус верификации:** ✅ подтверждено

`GetUsers(ExcludeBots)` фильтрует через `COALESCE(is_bot_override, is_bot) = 0`, уважая колонку ручного оверрайда (оператор может пометить Slack-«бота» человеком через SetBotOverride). `SearchUsersByName` фильтрует по голому `is_bot = 0`, поэтому пользователь с is_bot_override=0, is_bot=1 никогда не появляется в поиске по имени (MCP people lookup), хотя виден в обычном списке людей.

```sql
WHERE is_bot = 0 AND is_deleted = 0  -- SearchUsersByName
-- vs "COALESCE(is_bot_override, is_bot) = 0" -- GetUsers
```

- **Рекомендация:** Заменить условие на `COALESCE(is_bot_override, is_bot) = 0`, как в GetUsers и channel_stats.

### FindPendingInboxByThread глотает все ошибки запроса, порождая дубли inbox-items при транзиентных сбоях

- **Где:** `internal/db/inbox.go:88`
- **Статус верификации:** ✅ подтверждено

Любая ошибка QueryRow (не только ErrNoRows) конвертируется в (0, nil) — «не найдено». При транзиентной ошибке (SQLITE_BUSY несмотря на busy_timeout, I/O-ошибка) inbox-пайплайн решает, что pending-item для треда нет, и создаёт новый — дубликаты на один тред, которые потом чинит repair-проход DeduplicateThreadInboxItems (сам по себе баговый, см. High). Настоящие ошибки надо отличать от sql.ErrNoRows.

```go
err := db.QueryRow(`SELECT id FROM inbox_items WHERE channel_id = ? AND thread_ts = ? AND status = 'pending' ...`).Scan(&id)
if err != nil {
    return 0, nil //nolint:nilerr // not found is not an error
}
```

- **Рекомендация:** `if errors.Is(err, sql.ErrNoRows) { return 0, nil }; return 0, err` — и обрабатывать ошибку у вызывающего (пропускать кандидата в этом цикле вместо создания дубля).

### storeDigest пишет строку "null" вместо "[]" для пустых topics/decisions/action_items/situations, ломая downstream-проверки != "[]"

- **Где:** `internal/digest/pipeline.go:1290`
- **Статус верификации:** ✅ подтверждено

Когда result.Topics пуст (AI вернул `"topics": []` — реалистично для тихих каналов/дней), allTopicTitles/allDecisions/allActionItems/allSituations остаются nil-слайсами, а `json.Marshal(nil-slice)` даёт "null". Строка digests хранит topics="null", decisions="null" и т.д. Downstream-guard'ы проверяют `d.Decisions != "" && d.Decisions != "[]"` (lines 1009, 1083), поэтому литеральный текст «Decisions: null» инжектится в промпты daily-rollup и weekly-trends, а любой потребитель, различающий пусто/содержимое по "[]", неверно классифицирует такие строки.

```go
topics, _ := json.Marshal(allTopicTitles)      // nil []string → "null"
decisions, _ := json.Marshal(allDecisions)     // nil []Decision → "null"
// later: if d.Decisions != "" && d.Decisions != "[]" { fmt.Fprintf(&sb, "Decisions: %s\n", …) }
```

- **Рекомендация:** Инициализировать слайсы как `make([]T, 0)` перед агрегацией (или добавить "null" в downstream-guard'ы). Первый вариант чище — тогда в БД всегда "[]".

### prompt_version дайджеста протаскивается через пайплайн, но никогда не персистится — в таблице digests всегда 0

- **Где:** `internal/digest/pipeline.go:1315`
- **Статус верификации:** ✅ подтверждено

storeDigest заполняет db.Digest.PromptVersion версией из prompt store, но INSERT/UPDATE-список колонок `UpsertDigest` (db/digests.go:16-31) не содержит prompt_version, а GetDigests его не селектит. Колонка схемы `prompt_version INTEGER NOT NULL DEFAULT 0` остаётся 0 для каждого дайджеста — провенанс версий промптов для digests молча сломан (tracks/people cards свои персистят).

```go
PromptVersion:  promptVersion,
// db.UpsertDigest: INSERT INTO digests (channel_id, type, period_from, period_to, summary, topics,
//   decisions, action_items, people_signals, situations, running_summary, message_count, model,
//   input_tokens, output_tokens, cost_usd) — no prompt_version
```

- **Рекомендация:** Добавить prompt_version в column-list INSERT/UPDATE в UpsertDigest и в SELECT GetDigests; поправить тест, отмечающий «prompt_version may not be scanned».

### Пер-шаговая статистика токенов tracks всегда 0: LastStepInputTokens/LastStepOutputTokens обнуляются и никогда не обновляются из usage

- **Где:** `internal/tracks/pipeline.go:569`
- **Статус верификации:** ✅ подтверждено

runTrackBatches зануляет LastStepInputTokens/LastStepOutputTokens перед каждым батчем, но generateBatchTracks добавляет usage только в атомарные тоталы (lines 933-937) — LastStep*-поля никто не пишет. cmd/tracks.go:647-648 читает их внутри OnProgress для записи пер-шаговой статистики, так что каждый tracks-шаг записывается с 0 токенов, хотя usage доступен. Соседние пайплайны (digest, inbox, guide) поля заполняют — tracks выбивается.

```go
p.LastStepInputTokens = 0
p.LastStepOutputTokens = 0
… stepStart := time.Now()
n, err := p.generateBatchTracks(…)  // usage goes only to p.totalInputTokens.Add(…); LastStep tokens never set
```

- **Рекомендация:** В generateBatchTracks (или сразу после его возврата в runTrackBatches) присваивать LastStep*-поля из usage данного вызова — по образцу digest/pipeline.go:840-841.

### Байтовое усечение UTF-8 текста при сборке промптов режет мультибайтовые руны (кириллицу), давая невалидный UTF-8

- **Где:** `internal/tracks/pipeline.go:1103`
- **Статус верификации:** ✅ подтверждено

formatExistingTracks усекает контекст через `c[:120]` (байтовый индекс), хотя собственный хелпер пакета `truncate()` корректно режет по рунам. Тот же паттерн: digest formatMessages (digest/pipeline.go:1602-1604), tracks enrichKeyMessages (line 1161, `text[:200]`), guide formatRawMessages (guide/pipeline.go:847). Воркспейс русскоязычный (2-байтовые руны), усечение регулярно попадает в середину руны, встраивая невалидный UTF-8 байт в промпт (json.Marshal в enrichKeyMessages подставляет U+FFFD). Косметическая порча контента промпта на каждой границе усечения.

```go
c := sanitize(track.Context)
if len(c) > 120 {
	c = c[:120] + "..."
}  // vs func truncate(s string, maxLen int) { runes := []rune(s); … } three screens below
```

- **Рекомендация:** Во всех четырёх местах заменить байтовые срезы на рунобезопасный truncate (он уже есть в tracks — вынести в общий util или продублировать).

### Briefing-пайплайн разыменовывает usage.Model после nil-guard'а на usage

- **Где:** `internal/briefing/pipeline.go:245`
- **Статус верификации:** ✅ подтверждено

RunForDate защищается `if usage != nil` при чтении токен-каунтов (lines 225-229), признавая, что интерфейс digest.Generator может вернуть nil *Usage при nil error, — но затем безусловно читает usage.Model при сборке db.Briefing. Любая реализация Generator, возвращающая `(response, nil, "", nil)` — что разрешено интерфейсом и делается тест-моками, — уронит briefing-фазу демона nil-pointer'ом. In-repo генераторы сейчас всегда возвращают non-nil usage при успехе, так что дефект латентный; остальные пайплайны (inbox, dayplan) nil обрабатывают.

```go
var inTok, outTok, totalAPI int
if usage != nil { inTok = usage.InputTokens; ... }
...
briefing := db.Briefing{ ... Model: usage.Model,  // no nil guard
```

- **Рекомендация:** Вынести `model := ""` под тот же `if usage != nil` блок и использовать переменную в структуре.

### «Never show me this» молча превращается в no-op при сбое upsert'а правила

- **Где:** `internal/inbox/feedback.go:30`
- **Статус верификации:** ✅ подтверждено

Ветка never_show в SubmitFeedback использует `if err := database.UpsertLearnedRule(...); err == nil && len(logger) > 0 ...` — результат ошибки решает только, ЛОГИРОВАТЬ ли успех, и иначе отбрасывается; функция возвращает nil в любом случае. Если upsert падает (SQLITE_BUSY от параллельно пишущего демона, CHECK-нарушение), явный one-click hard mute пользователя (escape hatch INBOX-04) молча теряется: строка фидбека есть, а mute-правило не материализовалось — отправитель продолжает пиниться/приоритизироваться, и сбой нигде не всплывает.

```go
if err := database.UpsertLearnedRule(db.InboxLearnedRule{RuleType: "source_mute",
    ScopeKey: "sender:" + item.SenderUserID, Weight: -1.0, Source: "user_rule",
    EvidenceCount: 1}); err == nil && len(logger) > 0 && logger[0] != nil {
	logger[0].Printf(...)
}
// err != nil path: swallowed, SubmitFeedback returns nil
```

- **Рекомендация:** Пробрасывать ошибку UpsertLearnedRule из SubmitFeedback (как делают более ранние записи в той же функции), чтобы вызывающий мог показать сбой и пользователь — повторить действие.

### Ctrl+C на простаивающем REPL отменяет контекст, но цикл остаётся заблокированным в scanner.Scan до нажатия Enter

- **Где:** `internal/repl/repl.go:104`
- **Статус верификации:** ✅ подтверждено

Idle-ветка signal-горутины вызывает cancel() и возвращается, но главный цикл заблокирован внутри scanner.Scan() на stdin (repl.go:127). Go-рантайм перезапускает read после EINTR, а проверка ctx.Done() выполняется только в начале следующей итерации — для чего read должен сперва завершиться. Нажатие Ctrl+C в простое (задокументированный способ выхода: «Ctrl+C to quit») печатает перевод строки и внешне ничего не делает; процесс выходит только после дополнительного Enter (или Ctrl+D). Причём после возврата горутины дальнейшие Ctrl+C глотаются signal.Notify с непрочитанным каналом ёмкости 1 — принудительно выйти вторым Ctrl+C нельзя.

```go
} else {
    fmt.Println()
    cancel() // cancel the REPL context so defers run properly
    return   // loop is still blocked in scanner.Scan(os.Stdin); exits only after next Enter/EOF
}
```

- **Рекомендация:** В idle-ветке после cancel() вызывать `signal.Stop(sigCh)` и завершать процесс явно (`os.Exit(0)` после аккуратных defers) либо читать stdin в отдельной горутине с каналом строк, чтобы select мог реагировать на ctx.Done().

### Сбои батч-upsert'а при Jira-sync только логируются, но watermark всё равно продвигается — упавшие страницы молча теряются

- **Где:** `internal/jira/sync.go:330`
- **Статус верификации:** ✅ подтверждено

В writer-цикле syncWithJQL ошибка UpsertJiraIssueBatch (например SQLITE_BUSY, пока Desktop держит общую БД) логируется, цикл продолжается; `written` всё равно засчитывает упавшие issues, syncWithJQL не возвращает ошибку. Sync() затем продвигает last_synced_at до now, так что issues из упавшего батча (транзакция всё-или-ничего откатывает всю страницу) не будут перевыкачаны, пока их снова не обновят в Jira — тихий невосстановимый пробел в локальном зеркале.

```go
if err := s.db.UpsertJiraIssueBatch(dbIssues, dbLinks); err != nil {
    s.logger.Printf("batch upsert error: %v", err)
}
written += len(dbIssues)
// caller: total += n; _ = s.db.UpdateJiraSyncState(projectKey, now, issuesSynced)
```

- **Рекомендация:** Пробрасывать ошибку батча наверх (или собирать в multierror) и при её наличии не продвигать watermark для проекта — по аналогии с исправлением search-sync watermark.

### jira login записывает имя сайта в jira.user_display_name — status показывает сайт вместо пользователя

- **Где:** `cmd/jira.go:302`
- **Статус верификации:** ✅ подтверждено

runJiraLogin персистит `v.Set("jira.user_display_name", site.Name)`, где site — выбранный CloudResource (Jira-сайт, например "mycompany"), а не аутентифицированный пользователь. runJiraStatus печатает `User: %s` из cfg.Jira.UserDisplayName, так что `watchtower jira status` (и Desktop Settings, читающий тот же ключ) показывает имя сайта как display name пользователя.

```go
v.Set("jira.site_url", site.URL)
v.Set("jira.user_display_name", site.Name)
// runJiraStatus: fmt.Fprintf(out, "User: %s\n", cfg.Jira.UserDisplayName)
```

- **Рекомендация:** После логина запрашивать `/rest/api/3/myself` и сохранять реальное displayName пользователя; имя сайта хранить отдельным ключом (например jira.site_name), если оно нужно.

### truncate() в cmd/jira.go режет по байтам — невалидный UTF-8 для мультибайтовых имён

- **Где:** `cmd/jira.go:1438`
- **Статус верификации:** ✅ подтверждено

truncate() срезает по байтовым смещениям (`s[:maxLen-3]`). Jira display names и имена досок на кириллице (данные этого воркспейса частично русско/украиноязычные) — 2+ байта на руну, поэтому таблицы `jira users` и `jira boards` могут резать середину руны и печатать replacement/мусорный символ в точке усечения. Ср. internal/targets/resolver.go, где для той же цели корректно реализован truncateRunes.

```go
func truncate(s string, maxLen int) string {
    if len(s) <= maxLen {
        return s
    }
    ...
    return s[:maxLen-3] + "..."
}
```

- **Рекомендация:** Заменить на рунобезопасную версию (`[]rune`-срез, как truncateRunes в targets/resolver.go), в идеале — общий хелпер.
