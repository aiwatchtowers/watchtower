# Функциональные нестыковки и противоречия — аудит 2026-07-05

Данный отчёт покрывает измерение «функциональные нестыковки и противоречия»: расхождения поведения между дублирующими путями (Go CLI/daemon vs Swift Desktop), нарушения зафиксированных контрактов из `docs/inventory/`, а также конфигурационные ключи, которые заявлены/документированы, но не потребляются кодом. Метод: несколько поисковых агентов (finders) независимо собирали кандидатов, после чего каждый кандидат прошёл отдельную состязательную верификацию с трассировкой обоих путей по коду; ниже приведены только подтверждённые находки (опровергнутые удалены). Итог: 0 critical, 0 high, 7 medium, 5 low.

## Medium

### Desktop-смена статуса target не пересчитывает progress (ни собственный, ни родительский), в отличие от Go `UpdateTargetStatus`

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:217`
- **Статус верификации:** ✅ подтверждено

Go-функция `UpdateTargetStatus` делает три вещи: пишет статус, пересчитывает собственный `progress` листового target через `statusToProgress` (`done → 1.0` и т.д.) и поднимается вверх по цепочке родителей через `RecomputeParentProgress` (усреднение детей). Swift-версия `TargetQueries.updateStatus` повторяет только запись статуса и каскад INBOX-02 (`target_due` в inbox), но никогда не трогает колонку `progress` ни у самого target, ни у его предков; никакой другой Swift-код прогресс не пересчитывает (в Desktop нет ни запроса `AVG(progress)`, ни аналога `statusToProgress`). Поскольку `RecomputeParentProgress` вызывается только из Go-путей, пользователь, управляющий целями из Desktop (основной UI — переключатель статуса в `TargetDetailView`, контекстное меню в `TargetsListView`), получает вечно устаревшее кольцо прогресса: отметив листовой target как `done`, он оставляет `progress` на старом значении (например, 0%), а прогресс-бар родителя никогда не отражает завершённых через Desktop детей. Та же дыра — у Desktop-snooze (`TargetQueries.snooze`) против CLI-snooze, который идёт через `UpdateTarget` с пересчётом.

```go
// internal/db/targets.go:274-305
progress := statusToProgress(newStatus)
_, _ = db.Exec(`UPDATE targets SET progress = ? WHERE id = ? AND
    NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')`,
    progress, id)
...
if parentID.Valid {
    if rerr := db.RecomputeParentProgress(parentID.Int64); rerr != nil { ... }
}
```

- **Рекомендация:** В `TargetQueries.updateStatus` (и `snooze`) после записи статуса выполнить тот же пересчёт: обновить `progress` листового target по маппингу статуса и подняться по `parent_id`, усредняя `progress` детей — либо вынести логику в общий SQL и вызывать её из обоих путей. Стоит добавить guard-тест в `TargetQueriesStatusCascadeTests`, фиксирующий пересчёт кольца.

### Go-каскад «прочитан трек» помечает связанные digests прочитанными, но оставляет их decisions непрочитанными; Swift-каскад чистит оба

- **Где:** `internal/db/tracks.go:287`
- **Статус верификации:** ✅ подтверждено

Swift `TrackQueries.markRead` каскадит каждый связанный digest ОБОИМИ вызовами `markDigestRead` и `markAllDecisionsRead`, поэтому счётчик ленты Decisions (total − COUNT(decision_reads)) обнуляется. Go `MarkTrackRead` каскадит связанные digests сырым `UPDATE digests SET read_at = ...`, который в обход `MarkDigestRead` пропускает каскад `markDigestDecisionsRead`. Результат: прочтение трека любым Go-путём — CLI `watchtower tracks read <id>`, либо `watchtower catchup ack` / зачистка leftover-noise, когда ref темы указывает на трек с `related_digest_ids` — помечает digests прочитанными (пользователь их больше не откроет), но их decisions навсегда остаются в непрочитанном счётчике Decisions. То же действие в Desktop их чистит. Это ровно тот режим отказа «половина с decisions — та, которую легко забыть», который CATCHUP-01 (`docs/inventory/catchup.md`) фиксирует для digest-refs, просачивающийся через трек-каскад только на Go-стороне.

```go
// internal/db/tracks.go:280-289
q := "UPDATE digests SET read_at = strftime(...) WHERE id IN (...) AND read_at IS NULL"
db.Exec(q, args...) // никакого insert в decision_reads
```
```swift
// TrackQueries.swift:112-115
try DigestQueries.markDigestRead(db, id: digestID)
try DigestQueries.markAllDecisionsRead(db, digestID: digestID)
```

- **Рекомендация:** В `MarkTrackRead` заменить сырой `UPDATE digests` на вызов `MarkDigestRead` для каждого связанного digest (или добавить рядом каскад `markDigestDecisionsRead`), чтобы decisions гасились вместе с digest. Расширить `TestMarkTrackRead_CascadeDigests`, чтобы он проверял появление строк `decision_reads`, а не только `read_at`.

### CLI-счётчики и список inbox включают архивные элементы; Desktop их исключает — поверхности расходятся после авто-архивации устаревших

- **Где:** `internal/db/inbox.go:277`
- **Статус верификации:** ✅ подтверждено

Пайплайн архивирует actionable-элементы, висящие в `pending` дольше 14 дней, выставляя `archived_at` при сохранении `status='pending'` (`archive_reason='stale'`), и ambient-элементы после 7 дней. Swift `fetchCounts` и запросы ленты фильтруют `archived_at IS NULL`, что совпадает с Go feed/pinned-запросами. Но Go `GetInboxCounts` (заголовок `watchtower inbox`) считает каждую строку `status='pending'` без фильтра `archived_at`, и `GetInboxItems` (CLI-список) тоже никогда его не фильтрует. После двух недель обычной работы CLI показывает счётчики pending/unread и перечисляет элементы, которых бейдж и лента Desktop (и сами Go feed/pinned-запросы) уже не показывают — оператор видит два разных inbox в зависимости от поверхности. `GetInboxItemsForBriefing` разделяет тот же пропуск, дополнительно подмешивая архивные stale-элементы в промпт ежедневного брифинга.

```sql
-- Go GetInboxCounts (inbox.go:277-281): нет предиката archived_at
SELECT COALESCE(SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END),0),
       COALESCE(SUM(CASE WHEN status='pending' AND read_at IS NULL THEN 1 ELSE 0 END),0)
FROM inbox_items;
-- Swift fetchCounts (InboxQueries.swift:60)
SELECT COUNT(*) FROM inbox_items WHERE status='pending' AND archived_at IS NULL;
```

- **Рекомендация:** Добавить `AND archived_at IS NULL` в `GetInboxCounts`, `GetInboxItems` и `GetInboxItemsForBriefing`, приведя CLI и briefing-промпт к тем же критериям, что уже используют Desktop и Go feed/pinned-запросы.

### Ключ `digest.model` пишется онбордингом/настройками Desktop и принимается `config set`, но не читается никаким Go-кодом — выбор модели дайджеста молча игнорируется

- **Где:** `cmd/config.go:190`
- **Статус верификации:** ✅ подтверждено

Desktop-онбординг пишет `digest.model` (маппинг пресета Haiku/Sonnet/Opus, выбранного пользователем), `SettingsView` даёт его редактировать, `ConfigService` его round-trip'ит, а `cmd/config.go` перечисляет его в `knownConfigKeys`, так что `watchtower config set digest.model ...` проходит без предупреждения. Но Go-структура `DigestConfig` не имеет поля `Model`, и ничто ключ не разбирает и не читает: `cliGenerator` жёстко подставляет `digest.ModelSonnet` как фолбэк, а `ModelForSource` маршрутизирует по источникам между захардкоженными константами Haiku/Sonnet. Пользователь, выбравший «Opus — best insights» (или «Haiku — low cost») в онбординге, всё равно получает Sonnet/Haiku-маршрутизацию; его выбор цены/качества нигде не влияет. Асимметрия наглядна: `ai.model` действительно читается (`config.go:22 → newAIClient`), а `digest.model` — нет.

```go
// cmd/config.go: "digest.model": true в knownConfigKeys
// internal/config/config.go:36-44: DigestConfig{Enabled, MinMessages, Language, Workers,
//   TracksInterval, BatchMaxChannels, BatchMaxMessages} — поля Model нет
// cmd/generator.go:27:
return digest.NewClaudeGenerator(digest.ModelSonnet, cfg.ClaudePath)
```

- **Рекомендация:** Либо добавить поле `Model` в `DigestConfig` и прокинуть его в `cliGenerator`/`ModelForSource` (с поддержкой Opus), либо, если по замыслу модель дайджеста управляется маршрутизатором, убрать ключ из онбординга/Settings/`knownConfigKeys`, чтобы UI не обещал несуществующую настройку.

### `FindTracksByFingerprint` не исключает dismissed-треки — новая активность молча вливается в dismissed (невидимый) трек, вопреки TRACKS-07

- **Где:** `internal/db/tracks.go:419`
- **Статус верификации:** ✅ подтверждено

TRACKS-07 (`docs/inventory/tracks.md`) гласит: dismissed-трек «больше не участвует ни в каких cross-channel/dedup-проверках — после dismiss AI может заново открыть ту же ситуацию как свежий трек». Text-similarity dedup это соблюдает (`findSimilarTrack` итерирует `allActiveTracksRef` из `GetAllActiveTracks`, где фильтр `dismissed_at = ''`), но fingerprint-путь — нет: у `FindTracksByFingerprint` нет фильтра `dismissed_at`, поэтому в `storeTrackItems` новая тема, разделяющая fingerprint-сущность (Jira-ключ, CVE, MR id, user id) с dismissed-треком, маршрутизируется в `UpdateTrackFromExtraction` по dismissed-строке. `UpdateTrackFromExtraction` никогда не сбрасывает `dismissed_at`, так что свежий контент пишется в трек, исключённый из всех дефолтных списков и вкладки Desktop. Сценарий: пользователь дисмиссит трек «CEX-1234 incident»; тикет вспыхивает через неделю; пайплайн сворачивает весь новый контент в dismissed-строку, и пользователь его не видит — новый трек не создаётся. Та же дыра у existing_id-пути: `GetTrackAssignee` проверяет только ownership, не dismissal.

```go
// internal/db/tracks.go:419 — нет фильтра dismissed_at
query := `SELECT ` + trackSelectCols + ` FROM tracks
    WHERE (fingerprint LIKE ? OR ...) AND assignee_user_id = ?`
// GetAllActiveTracks (tracks.go:173): ... FROM tracks WHERE dismissed_at = ''
```

- **Рекомендация:** Добавить `AND dismissed_at = ''` в `FindTracksByFingerprint` (и в `GetTrackAssignee`), чтобы fingerprint-dedup, как и text-dedup, обходил dismissed-треки. Добавить guard-тест `TestTracks07_DismissedDoesNotBlockRediscovery`, который `docs/inventory/tracks.md` уже называет отсутствующим.

### Ручные Desktop-правки трека (priority/ownership/sub-items) пропускают snapshot `track_states`, который TRACKS-06 маркирует Enforced для ручных правок

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/TrackQueries.swift:127`
- **Статус верификации:** ✅ подтверждено

TRACKS-06 (`docs/inventory/tracks.md`, Status: Enforced) требует: «Каждое изменение нарративного поля — ... priority, ownership, ... sub_items ... — пишет snapshot прежнего состояния в `track_states` ... И AI-извлечение, и ручные правки (`UpdateTrackPriority`, `UpdateTrackOwnership`, `UpdateTrackSubItems` ...) делают snapshot перед мутацией». Go-сторона это делает (`snapshotTrackState`). Но Desktop выполняет те же ручные правки прямой записью в общий SQLite — `TrackQueries.updatePriority`, `updateOwnership`, `updateSubItems` — обычными `UPDATE tracks` без insert в `track_states` (единственный Swift-доступ к `track_states` — read-only `TrackStateQueries`). Изменение priority/ownership, сделанное во вкладке Tracks в Desktop, не оставляет строки истории, поэтому секция History не может ответить «трек всегда так говорил?» для Desktop-правок; то же действие даёт историю через CLI, но не через Desktop.

```swift
// TrackQueries.swift:127 — без записи в track_states
try db.execute(sql: "UPDATE tracks SET priority = ? WHERE id = ?", ...)
```
```go
// internal/db/tracks.go — BEHAVIOR TRACKS-06: snapshot перед ручной правкой
_ = db.snapshotTrackState(cur, proposed, "manual")
```

- **Рекомендация:** Продублировать snapshot в Swift: перед каждым `UPDATE tracks` в `updatePriority`/`updateOwnership`/`updateSubItems` вставлять строку `track_states` с прежним состоянием и `source='manual'`, зеркалируя `snapshotTrackState`. Обернуть чтение+snapshot+update в одну транзакцию `dbPool.write`.

### Daemon подключает inbox/briefing/day-plan/custom-track пайплайны только внутри `if cfg.Digest.Enabled` — отключение дайджестов молча выключает четыре независимо конфигурируемых фичи

- **Где:** `cmd/sync.go:274`
- **Статус верификации:** ✅ подтверждено

В режиме daemon (и в one-shot `runPostSyncPipelines`) все AI-пайплайны конструируются внутри блока `if cfg.Digest.Enabled { ... }`: `SetInboxPipeline` вызывается только при digest.enabled И inbox.enabled, аналогично briefings, day plans, next-step и custom-track scans. Конфиг документирует их как независимые тумблеры (inbox.enabled по умолчанию true, briefing.enabled true, day_plan.enabled true). Пользователь, поставивший `digest.enabled: false` (например, чтобы срезать AI-стоимость, оставив алгоритмическое DM/mention-детектирование inbox), молча теряет inbox-детекцию, ежедневные брифинги, day plans и custom-track scan без предупреждения. Самое материальное — inbox: `daemon.go` пропускает `RunFastDetection`, когда `d.inboxPipe == nil`, а `inboxPipe` ставится только внутри digest-блока, так что чисто SQL-детекция DM/mention (Phase 0.7) умирает, хотя ей вообще не нужен AI-генератор. Desktop-тумблер «digest enabled» тем самым работает как недокументированный мастер-килл-свитч для четырёх других вкладок.

```go
// cmd/sync.go:274
if cfg.Digest.Enabled {
    ...
    if cfg.Briefing.Enabled { d.SetBriefingPipeline(...) }
    if cfg.Inbox.Enabled    { d.SetInboxPipeline(...)   }
    d.SetNextStepPipeline(...)
    d.SetCustomTracksPipeline(...)
    if cfg.DayPlan.Enabled  { d.SetDayPlanPipeline(...)  }
}
```

- **Рекомендация:** Вынести конструирование independently-конфигурируемых пайплайнов из-под `if cfg.Digest.Enabled` (AI-генератор при этом создавать лениво/один раз при первом потребителе). Как минимум — вынести SQL-based inbox fast-detection наружу, так как ей AI не нужен, и добавить warning-лог, когда включённая фича не запускается из-за выключенных дайджестов.

## Low

### Upsert learned-rule `never_show` расходится: Go сбрасывает `evidence_count` в 1, Swift инкрементирует

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/InboxFeedbackQueries.swift:69`
- **Статус верификации:** ✅ подтверждено

Оба пути «never show» (escape-hatch из INBOX-04) upsert'ят `source_mute` user_rule, но при конфликте Go `UpsertLearnedRule` ставит `evidence_count = excluded.evidence_count`, а `SubmitFeedback` всегда передаёт `EvidenceCount:1` — то есть каждый Go-side never_show сбрасывает счётчик в 1 — тогда как Swift `upsertRule` ставит `evidence_count = evidence_count + 1`, накапливая. `evidence_count` виден пользователю в Learned-табе (INBOX-05: «learned from N dismissals»), так что одна и та же последовательность действий даёт разную отображаемую модель пользователя в зависимости от поверхности, а один CLI-side never_show стирает счётчик, накопленный Desktop. Go ON CONFLICT также перезаписывает `pipeline`, тогда как Swift его сохраняет — тот же дрейф. Замечание: сегодня ни один потребитель не читает `evidence_count` для этих user_rule-mute (Learned-view показывает только scopeKey/weight/source, AI-промпт использует scope/weight/source), поэтому вред пока латентен.

```go
// inbox_learned_rules.go:38-44 — ON CONFLICT ... evidence_count = excluded.evidence_count
// feedback.go:30-36 — EvidenceCount: 1
```
```swift
// InboxFeedbackQueries.swift:66-70 — ON CONFLICT ... evidence_count = evidence_count + 1
```

- **Рекомендация:** Выбрать единую семантику `evidence_count` для `source_mute` user_rule (вероятно, накопление) и привести оба upsert'а к ней; заодно согласовать поведение `pipeline` в ON CONFLICT. До появления потребителя это уборка консистентности, но её лучше сделать до того, как Learned-таб начнёт показывать счётчик.

### Swift catch-up acknowledge решает идемпотентность `reviewed_count` по устаревшему снимку от вызывающего и прерывает весь ack на ошибке mark-read, в отличие от Go

- **Где:** `WatchtowerDesktop/Sources/Database/Queries/CatchUpQueries.swift:97`
- **Статус верификации:** ✅ подтверждено

Два дрейфа от Go `Pipeline.Acknowledge`. (1) Источник идемпотентности: Go перечитывает тему из БД в момент ack (`alreadyReviewed := theme.ReviewState == "reviewed"`), поэтому повторный ack всегда видит сохранённое `reviewed`. Swift читает `theme.isReviewed` из значения `CatchUpTheme`, переданного view — снимок, снятый до записи. Двойной клик на «Done» (или ack, гонящийся с CLI-side `catchup ack`) запускает два сериализованных блока `dbPool.write`, оба видят устаревший `isReviewed == false` и оба выполняют `reviewed_count = reviewed_count + 1`, проталкивая счётчик за `total_themes` — ровно тот over-count, что запрещает idempotency-клауза CATCHUP-01 (guard-тест проходит, потому что перечитывает тему между ack'ами). (2) Семантика ошибок: Go-каскад явно best-effort — ошибка каждого `markAreaRead` логируется и цикл продолжается, тема всё равно помечается reviewed. Swift `try`'ит каждый mark-read внутри write-транзакции, поэтому первый упавший ref выбрасывает из `acknowledge`, откатывает транзакцию, и тема не подтверждается вовсе — один плохой ref блокирует ack в Desktop, но не в CLI.

```swift
// CatchUpQueries.swift:97 — устаревший параметр
let wasReviewed = theme.isReviewed
```
```go
// pipeline.go:444-459 — перечитывание из БД + best-effort каскад
theme, err := p.db.GetCatchupTheme(themeID)
alreadyReviewed := theme.ReviewState == "reviewed"
if err := p.markAreaRead(r.Area, r.ID); err != nil { p.logf(...) } // continue
```

- **Рекомендация:** В Swift `acknowledge` перечитывать тему из БД внутри транзакции для проверки `isReviewed` (вместо параметра-снимка) и изолировать ошибки каждого mark-read (логировать и продолжать, всё равно флипая тему в reviewed), приведя поведение к Go best-effort/идемпотентному контракту CATCHUP-01.

### `inbox.max_items_per_run` определён, дефолтится и документирован, но не потребляется кодом — заявленный per-run cap не применяется

- **Где:** `internal/config/config.go:55`
- **Статус верификации:** ✅ подтверждено

`InboxConfig.MaxItemsPerRun` существует с viper-дефолтом 100 и документирован в CLAUDE.md как «inbox.max_items_per_run (100)», но repo-wide grep показывает, что единственные ссылки — тег структуры и строка `SetDefault`; `internal/inbox/pipeline.go` его никогда не читает. Пользователь, задавший `inbox.max_items_per_run: 10`, чтобы ограничить объём детекции / стоимость AI-prioritize, не получает изменения поведения; объём детекции ограничен только lookback-watermark'ом. Единственный cap в пакете — захардкоженная `MaxItemsPerAIBatch=50` (размер AI-батча, не per-run cap), и никакого `LIMIT` в inbox-пакете нет.

```go
// internal/config/config.go:55
MaxItemsPerRun int `mapstructure:"max_items_per_run"` // (default: 100)
// grep 'MaxItemsPerRun|max_items_per_run' → только config.go:55 и :204
```

- **Рекомендация:** Либо применить cap в `internal/inbox/pipeline.go` (например, `LIMIT`/усечение множества кандидатов до `MaxItemsPerRun`), либо удалить ключ из конфига и CLAUDE.md, чтобы не заявлять несуществующую настройку.

### Дефолт `calendar.sync_days_ahead` расходится между слоями: Go-эффективный дефолт 7, комментарий Go-структуры и Desktop-фолбэк — 2, и Desktop-save молча пишет 2

- **Где:** `internal/config/defaults.go:39`
- **Статус верификации:** ✅ подтверждено

`DefaultCalendarSyncDaysAhead = 7` (используется viper-дефолтом, фолбэком `internal/calendar/sync.go:47` и `cmd/calendar.go:109`), но комментарий структуры (`config.go:82`) говорит «default: 2», CLAUDE.md говорит 2, и Desktop `ConfigService.swift` фолбэчит на 2 при отсутствии ключа. Поскольку `ConfigService.save()` безусловно пишет `calendarDict["sync_days_ahead"] = calendarSyncDaysAhead`, пользователь, в чьём конфиге ключа не было, видит «2» в Settings и, сохранив любую несвязанную настройку, молча сжимает реальное окно синхронизации daemon с 7 до 2 дней — контекст upcoming-events и meeting prep теряют дни 3–7 без единого действия пользователя с календарём.

```
Go:    DefaultCalendarSyncDaysAhead = 7
Go:    SyncDaysAhead ... // days ahead to fetch (default: 2)   ← комментарий врёт
Swift: calendarSyncDaysAhead = (calendar["sync_days_ahead"] as? Int) ?? 2
Swift: save(): calendarDict["sync_days_ahead"] = calendarSyncDaysAhead
```

- **Рекомендация:** Свести все слои к одному дефолту (скорее всего 7): исправить комментарий `config.go:82` и CLAUDE.md, и заменить Desktop-фолбэк на 7. Ещё лучше — не писать ключ в `save()`, если пользователь его не менял, чтобы не подменять серверный дефолт.

### CLI `watchtower feedback` отвергает entity-типы (target, briefing, inbox, catchup_theme), которые разрешает DB CHECK и активно пишет Desktop

- **Где:** `cmd/feedback.go:58`
- **Статус верификации:** ✅ подтверждено

CHECK таблицы `feedback` (миграция 00003) разрешает `entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme')`, и Desktop пишет `entityType "target"` (`TargetsViewModel.swift:440`, `TargetDetailView.swift:784`) и `"track"`/`"digest"`. Map `validTypes` в CLI принимает лишь digest/track/decision/user_analysis, поэтому `watchtower feedback bad target 12` падает с «invalid type», хотя тот же рейтинг записывается из Desktop и схема его поддерживает — одно и то же действие проходит в одном клиенте и отвергается в другом.

```go
// cmd/feedback.go:58
validTypes := map[string]bool{"digest": true, "track": true, "decision": true, "user_analysis": true}
// vs CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme'))
```

- **Рекомендация:** Расширить `validTypes` в `cmd/feedback.go` до полного набора, разрешённого CHECK-ом (`briefing`, `target`, `inbox`, `catchup_theme`), приведя CLI к паритету с DB-схемой и Desktop.

### Ключ `digest.action_items_interval` / `digest.tracks_interval` разбирается, дефолтится, алиасится и allow-листится, но не потребляется

- **Где:** `internal/config/config.go:41`
- **Статус верификации:** ✅ подтверждено

`DigestConfig.TracksInterval` анмаршалится из `digest.action_items_interval`, получает дефолт 1h, алиасится (`digest.tracks_interval`), и обе записи есть в `cmd/config.go` `knownConfigKeys`, так что `config set` принимает их как распознанные. Repo-wide, никакой код вне `internal/config` не читает `TracksInterval` — tracks-пайплайн запускается каждый цикл daemon независимо (gate идёт через `lastTracksStartedAt()`, не через этот конфиг). Установка интервала в любое значение ничего не меняет; ключ мёртв, но подаётся пользователям как распознаваемая настройка.

```go
// internal/config/config.go:41
TracksInterval time.Duration `mapstructure:"action_items_interval"`
// grep 'TracksInterval' → только internal/config/{config.go,defaults.go}
```

- **Рекомендация:** Либо реально применять интервал в gate-логике tracks-пайплайна, либо удалить поле, дефолт, алиас и обе записи `knownConfigKeys`, чтобы `config set` не выдавал мёртвый ключ за рабочий.
