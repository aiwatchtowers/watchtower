# Gmail как источник данных — дизайн

**Дата:** 2026-07-09
**Ветка (предполагаемая):** feature/gmail-source
**Статус:** дизайн одобрен, готов к планированию

## Мотивация

Watchtower агрегирует рабочие сигналы из нескольких источников (Slack, Jira, Google
Calendar, внутренние события) в единый inbox и кластеризует их в «ситуации».
Электронная почта — крупный источник рабочих сигналов, которого сейчас нет. Цель:
подключить Gmail как ещё один источник по образцу существующих внешних источников,
чтобы письма попадали в inbox/ситуации и обрабатывались тем же pipeline без его
переработки.

## Ключевые решения (подтверждены с владельцем)

1. **Провайдер:** Gmail через Google API (переиспользуем OAuth-механику Calendar).
2. **Что считается триггером:** всё во входящих (Gmail Inbox). Фильтрацию важности
   выполняет существующий triage (AI), а не детектор.
3. **Права:** scope `gmail.modify` (чтение + возможность write-back статусов). Scope
   запрашиваем сразу, чтобы будущий write-back-слой не требовал переавторизации.
4. **Модель подключения:** **отдельное** подключение Gmail (свой token store
   `gmail_token.json`, своя кнопка Connect Gmail), независимое от Calendar. Существующие
   Calendar-пользователи не затрагиваются; источники включаются независимо.

## Границы и декомпозиция

Владелец выбрал охват **C** (см. раздел «Охват: как глубоко email входит в пайплайны»):
письма попадают и в inbox, и — через собственные email-дайджесты — в треки и daily
briefing. Реализуется поэтапно, **тремя планами**:

- **План 1 — read-path в inbox (эта спека, реализуется первым):** OAuth Gmail,
  sync-слой, таблица-источник `gmail_messages`, детектор, интеграция в inbox pipeline,
  CLI, Desktop Connect. Письма попадают в inbox и ситуации. Discuss-chat может сочинить
  черновик ответа (как для Slack), отправка — вручную в Gmail. Самодостаточен.
- **План 2 — email-дайджесты (надстройка над Планом 1, охват C):** генерация дайджестов
  из `gmail_messages` (запись в таблицу `digests`), чтобы треки и daily briefing
  подхватывали почту. См. набросок в разделе «План 2 (набросок): email-дайджесты» —
  детальный дизайн будет отдельной спекой.
- **План 3 — write-back (независим, позже):** обратная синхронизация статуса
  «прочитано/архив» из Watchtower в Gmail (`users.messages.modify`, снятие ярлыков
  `UNREAD`/`INBOX`). Scope `gmail.modify` уже покрывает его.

Планы 2 и 3 независимы между собой; оба строятся поверх Плана 1. Обоснование разбивки:
read-path приносит ценность сам по себе; email-дайджесты и write-back добавляют
отдельные оси сложности (интеграцию в digest/tracks и двустороннюю синхронизацию
статусов соответственно), которые лучше проектировать по отдельности.

## Охват: как глубоко email входит в пайплайны (обоснование выбора C)

В коде **нет абстракции «источник данных»** — всё сырьё это Slack-таблица `messages`,
жёстко смоделированная под Slack. Разведка связанности пайплайнов показала:

- **Дайджесты** читают `messages` напрямую, организованы вокруг «каналов».
- **Треки** читают НЕ `messages`, а `digests` (потребитель второго порядка).
- **People-карточки** — гибрид: часть из `digests`, часть — прямые `JOIN` на
  `messages`/`users`/`channels` (жёсткая привязка к Slack).

Ключевой вывод: **точка интеграции для треков и (частично) people — это `digests`,
а не `messages`.** Поэтому:

- Вариант «влить email в `messages`» (first-class) — самый дорогой и рискованный:
  расширение CHECK `channels.type`, синтетические `users`/`channels`, синтез `ts`,
  ревизия Slack-форматных допущений (`^\d{10}\.\d{6}$`, `<@id>`-упоминания,
  `thread_ts`). Отвергнут — непропорционально риску, кривит семантику «почта = каналы».
- Выбранный вариант **C** генерирует из писем собственные **дайджесты**, обходя
  болезненные инварианты `messages`. Треки подхватывают email почти даром; briefing
  включает почту. Ограничение: треки потеряют точные `source_refs` на письма
  (Slack-форматный регэксп) — деградация ссылок, не поломка; people-статистика по
  внешним контактам не появляется (она из прямых `JOIN` на `messages`) — это
  сознательно вне охвата.

## Архитектура

Повторяет подтверждённый паттерн «внешнего источника» (образцы — Calendar и Jira):

```
OAuth Gmail (gmail_token.json)
  → internal/gmail: Syncer.Sync() тянет письма из Gmail Inbox
     → пишет в таблицу gmail_messages (SQLite)
        → internal/inbox/gmail_detector.go: DetectGmail() читает gmail_messages
           → создаёт inbox_items (trigger_type email_received / email_cc)
              → существующий pipeline: triage → compose → situations (без изменений)
```

Детектор НЕ ходит в Gmail API — он читает уже засинканную таблицу, как это делают
Jira- и Calendar-детекторы.

## Компоненты

### 1. Пакет `internal/gmail/`

По образцу `internal/calendar/` — **самодостаточный пакет** (в репо это установленный
паттерн: у Jira и Calendar собственный OAuth-код, а не общий слой; повторяем его,
чтобы не трогать работающую Calendar-интеграцию и её ldflags):

- **`auth.go`** — OAuth по образцу `calendar/auth.go`: token endpoint, `access_type=offline`,
  `prompt=consent`, loopback `Login`, `Prepare`/`Complete`. Отличия от Calendar:
  - scope: `https://www.googleapis.com/auth/gmail.modify`;
  - собственный `TokenStore` → `gmail_token.json` (независим от `google_token.json`);
  - собственный тип `GoogleOAuthConfig`. Google client_id/secret — те же, что у Calendar
    (один Google Cloud проект); связываются на уровне `cmd` (`resolveGoogleOAuthConfig`
    конвертируется в `gmail.GoogleOAuthConfig`), поэтому новые ldflags-переменные и
    правки Makefile НЕ нужны, а пакет `gmail` не импортирует `calendar`.
- **`client.go`** — Gmail REST-клиент (raw net/http, base
  `https://www.googleapis.com/gmail/v1`): `users.messages.list` (`q=in:inbox`,
  пагинация), `users.messages.get` (формат metadata+body). Авторетрай на 401 с
  рефрешем токена (как `calendar/client.go`). При `invalid_grant` → `ErrAuthRevoked`.
- **`sync.go`** — `Syncer{client, db, cfg, logger}`, `NewSyncer`, `Sync(ctx) (int, error)`:
  - **initial sync:** запрос `in:inbox newer_than:{InitialHistoryDays}d`;
  - **incremental sync:** watermark по последнему обработанному `internalDate`.
    В отличие от Calendar (скользящее окно + инвалидация по `synced_at`), почта
    накапливается — нужен настоящий watermark, чтобы не тянуть весь Inbox каждый цикл.
    Watermark хранится в таблице `workspace` (новое поле `gmail_last_internal_date`),
    консистентно с существующими watermark'ами `inbox_last_processed_ts` и
    `search_last_date`;
  - **шумовой фильтр до AI:** письма с ярлыками `CATEGORY_PROMOTIONS` и
    `CATEGORY_SOCIAL` пропускаются (аналог hard-mute), не доходят до triage;
  - upsert каждого письма в `gmail_messages`;
  - лимит `MaxMessagesPerSync` на цикл;
  - запись телеметрии авторизации в `gmail_auth_state` (`ok`/`error`/`revoked`).
- **`models.go`** — доменные типы письма.

*(historyId-based incremental sync — возможное улучшение производительности, но для
первой версии используем `messages.list` + watermark по `internalDate`.)*

### 2. Схема БД (миграция `00016`)

Новая таблица **`gmail_messages`** (образец — `calendar_events`):

| колонка | тип | назначение |
|---|---|---|
| `id` | TEXT PK | Gmail message ID |
| `thread_id` | TEXT | Gmail thread — кластеризация composer'ом и группировка треда |
| `from_email` | TEXT | отправитель (email) |
| `from_name` | TEXT | отправитель (отображаемое имя) |
| `to_json` | TEXT | получатели To (JSON-массив) |
| `cc_json` | TEXT | получатели CC (JSON-массив) |
| `subject` | TEXT | тема |
| `snippet` | TEXT | превью от Gmail (~200 символов тела, отдаёт сам API) |
| `body_text` | TEXT | полное plain-text тело письма (для сильного AI-tier) |
| `internal_date` | TEXT | время письма (ISO8601) |
| `labels_json` | TEXT | ярлыки Gmail (INBOX, UNREAD, IMPORTANT, CATEGORY_*) |
| `is_unread` | INTEGER | производное для быстрых фильтров |
| `permalink` | TEXT | `https://mail.google.com/mail/u/0/#inbox/{id}` |
| `synced_at` | TEXT | время последнего синка строки (дефолт now) |
| `updated_at` | TEXT | служебное |

Таблица `gmail_auth_state` (singleton `id=1`, образец `calendar_auth_state`) для
телеметрии авторизации и детекта `revoked`. Добавляется в `TestAllTablesExist`.

Watermark: новое поле `gmail_last_internal_date` в таблице `workspace` (той же
миграцией; расширение существующей таблицы, а не enum — обычным `ALTER TABLE ADD COLUMN`).

Миграция также **расширяет CHECK `inbox_items.trigger_type`** двумя значениями:
`email_received` и `email_cc` — через «table-recreation dance» (образец
`00002_target_due_inbox.sql`), т.к. SQLite не умеет `ALTER TABLE ... ADD CONSTRAINT`.

Обязательные сопутствующие правки (по CLAUDE.md):
- зеркалирование новой таблицы и расширенного CHECK в `internal/db/schema.sql`;
- добавление `gmail_messages` и `gmail_auth_state` в `TestAllTablesExist`;
- регенерация golden snapshot: `go test ./internal/db/ -run TestSchemaGolden -update`;
- Go-модели в `internal/db/` + слой доступа (`internal/db/gmail.go`): upsert, чтение
  для детектора, работа с watermark.

### 3. Детектор `internal/inbox/gmail_detector.go`

По образцу `calendar_detector.go`:

- сигнатура: `func DetectGmail(ctx, database *db.DB, myEmail string, sinceTS time.Time) (int, error)`;
- ранний выход при `myEmail == ""`;
- читает `gmail_messages` с `synced_at > sinceTS`;
- **полностью вычитывает rows в слайс до начала вставок** (guard против deadlock
  in-memory SQLite при `MaxOpenConns(1)`);
- определение `trigger_type`: `email_received`, если `myEmail` присутствует в To;
  иначе (только CC) — `email_cc`;
- создание `inbox_item`:
  - `ChannelID = thread_id` (тред как «канал» → группировка в inbox/ситуациях),
  - `MessageTS = message_id` (Gmail message ID уникален → надёжный дедуп),
  - `SenderUserID = from_email`,
  - `Snippet = subject + " — " + gmail snippet` (тема в одиночку слишком слаба для
    triage; см. раздел «AI-обработка»),
  - `Permalink = gmail permalink`;
- локальный хелпер `gmailInboxExists` для дедупа по `(channel_id, message_ts, trigger_type)`.

### 4. Проводка в pipeline и daemon

- **`internal/inbox/pipeline.go`**: расширить `detectAll` дополнительным счётчиком
  `email` и вызовом `DetectGmail(...)`; обновить оба места вызова — `Run` и
  `RunFastDetection` (позиционные счётчики).
- **`internal/inbox/classifier.go`**: добавить в `defaultClasses`:
  `email_received → actionable`, `email_cc → ambient`.
- **`internal/daemon/daemon.go`**: поле `gmailSyncer *gmail.Syncer`, сеттер
  `SetGmailSyncer`, метод `phaseGmailSync(ctx)` (no-op guard если nil), вызов в
  `runCycle` рядом с `phaseCalendarSync`.
- **`cmd/sync.go`**: проводка — при наличии `gmail_token.json` создать client и
  `d.SetGmailSyncer(...)` (образец — блок Calendar).

### 5. CLI `cmd/gmail.go`

По образцу `cmd/calendar.go`:
- `watchtower gmail login` — OAuth, сохранение `gmail_token.json`;
- `watchtower gmail logout` — удаление токена (+ опц. очистка `gmail_messages`);
- `watchtower gmail sync` — разовый синк;
- `watchtower gmail status` — connected/not, путь токена, `cfg.Gmail.Enabled`.

### 6. Конфиг

`internal/config/config.go`: секция
`GmailConfig{Enabled bool, InitialHistoryDays int, MaxMessagesPerSync int, MaxBodyBytes int}`
в `Config`. Дефолты в `internal/config/defaults.go` (`InitialHistoryDays=7`,
`MaxMessagesPerSync=100`, `MaxBodyBytes=51200` — предохранитель усечения тела в сильном
AI-tier), регистрация `v.SetDefault(...)` в `Load` (образец — секции Calendar/Jira).

### 7. Desktop (`WatchtowerDesktop/`)

- **`Sources/Services/GmailAuthService.swift`** — по образцу `GoogleAuthService.swift`,
  но на `gmail_token.json` и командах `gmail login/logout/status`. Собственный статус
  `isConnected` (сканирует `*/gmail_token.json`).
- **`Sources/Views/Settings/SettingsView.swift`** — секция `gmailSettingsSection`
  (образец `calendarSettingsSection`): статус, кнопка Connect/Disconnect Gmail, тоггл
  «Enable Gmail sync» (пишет `config.gmailEnabled`), обработка отмены/ошибок.
- **`Sources/Views/Inbox/InboxCardView.swift`** — `case`'ы для `email_received` и
  `email_cc` в `triggerLabel` («Email»), `triggerSymbol` (`envelope`), `triggerColor`.
- Опционально: фильтр по источнику Email через существующий `triggerTypeFilter`.

## AI-обработка писем

Письма НЕ обрабатываются отдельным email-специфичным AI-вызовом. Они вливаются в
существующий AI-конвейер inbox через `inbox_items` и проходят те же стадии, что и
Slack-сигналы. Что видит AI на каждой стадии:

1. **Triage** (`inbox.triage`, дешёвый tier) — на каждый новый email-item. Присваивает
   tier (action/awareness/ignore) и priority — это и есть фильтр важности. В промпт
   уходит одна строка на кандидата вида
   `[TRIGGER] key=item:<id> type=email_received from=<sender> channel=<thread> :: <Snippet>`
   (см. `triage.go`, `runTriage`). Triage судит **только по `Snippet`**, поэтому для
   писем `Snippet = subject + Gmail preview` (тема в одиночку неинформативна). Полное
   тело на дешёвый tier НЕ подаётся. Trigger-item можно только понизить, не повысить
   (INBOX-01).
2. **Compose** (`inbox.compose`) — кластеризует триажированные письма в **ситуации** по
   `thread_id` (переписка = одна ситуация), мёржит в открытую ситуацию при совпадении
   истории (DASH-01).
3. **Situation cards** (`inbox.situation_card`, **сильный** tier) — why-it-matters /
   summary / chronology. Здесь в контекст ситуации подаётся **полное тело `body_text`**
   писем (аналог member-signal сообщений у Slack). Единственный жёсткий предохранитель:
   письма с телом больше разумного предела (порядка 50 КБ) усекаются, чтобы экстремальное
   письмо не сломало context window; типичные деловые письма подаются целиком.
4. **Discuss chat** — по запросу пользователя, черновик ответа в стиле владельца.

Стоимость: triage идёт на весь входящий поток дёшево (плюс отсечка PROMOTIONS/SOCIAL до
AI и cap `MaxTriageMessages`); дорогой сильный tier работает на уровне ситуации, а не
на каждое письмо.

Промпты `inbox.triage`/`inbox.compose`/`inbox.situation_card` — общие для всех
источников; отдельные email-промпты не создаются. AI отличает письмо по `trigger_type`
(`email_received`/`email_cc`) в строке кандидата. Если на этапе реализации выяснится,
что общим промптам не хватает email-контекста, правка ограничится добавлением
пояснения о email-типах в существующие шаблоны (а не новым промптом).

## Поток данных (пример)

1. daemon `phaseGmailSync` → `Syncer.Sync` тянет новые письма из Inbox → upsert в
   `gmail_messages`, watermark продвигается.
2. daemon `phaseFastInbox`/`phaseInbox` → `DetectGmail` читает новые строки
   `gmail_messages` → создаёт `inbox_items` (`email_received`/`email_cc`).
3. Существующий pipeline: triage классифицирует (важное/шум), compose кластеризует
   письма (по `thread_id`) в ситуации, situation cards генерируют сводку.
4. Desktop Dashboard показывает ситуации; Email-item получает иконку конверта и метку.

## Обработка ошибок

- Детектор Gmail индивидуально non-fatal в `detectAll` (ошибка накапливается в
  `errors.Join`); суммарная ошибка детекции морозит inbox-watermark (окно не теряется)
  — существующее поведение.
- `phaseGmailSync` логирует ошибку синка и не прерывает цикл daemon (как
  `phaseCalendarSync`).
- `invalid_grant` при рефреше → `ErrAuthRevoked`, запись `revoked` в `gmail_auth_state`,
  синк пропускается до переавторизации.

## Тестирование

- **Go:** unit-тесты `DetectGmail` (создание item'ов, разделение received/cc, дедуп,
  degenerate-вход — пустая таблица, письмо без CC и т.д.); тест синка с мок-HTTP
  Gmail API (образец — тесты calendar с переопределяемыми endpoints); тест миграции
  `00016` (up/down) и golden snapshot.
- **Swift:** тест `GmailAuthService` (connect/cancel/status), проверка расширения
  `TestDatabase.swift` под новую таблицу и trigger_type (schema.sql ↔ TestDatabase.swift
  не должны разъезжаться).
- Проверять реальный exit-код (не пайпить через tail).

## Риски и зависимости

- **Google verification:** `gmail.modify` — restricted scope. Для личного/командного
  использования через test users работает сразу; для широкого продакшена требуется
  Google security assessment. Это внешний процесс, вне кода. См.
  `docs/legal/google-verification.md`.
- **Приватность:** тело писем (`body_text`) хранится локально в SQLite — консистентно
  с существующей моделью хранения Slack-сообщений локально. Подтверждено владельцем.
- **Объём данных:** лимит `MaxMessagesPerSync` и watermark ограничивают нагрузку;
  шумовой фильтр (PROMOTIONS/SOCIAL) снижает объём AI-обработки.

## План 2 (набросок): email-дайджесты

Детальный дизайн — отдельной спекой; здесь фиксируется только направление, чтобы
План 1 не закрыл к нему дорогу.

- Источник — та же таблица `gmail_messages` (её строит План 1); псевдо-`messages` НЕ
  создаются.
- Новый генератор (по образцу `internal/digest/`) группирует письма (по треду/ярлыку/
  отправителю — уточняется) и пишет записи в таблицу `digests`. `digests.channel_id` —
  обязательный ключ, поэтому email-дайджесту нужен синтетический стабильный идентификатор
  «канала» (например `email:<label>` или `email:<thread_id>`); тип дайджеста — уточняется
  (возможно новое значение `digests.type`).
- Треки подхватывают email-дайджесты автоматически (они читают `digests`). Известное
  ограничение: `key_messages`/`source_refs` в формате не-Slack `ts` отбрасываются
  регэкспом `reSlackTSExact` в треках — обогащение ссылками на исходные письма
  деградирует. Решается либо ослаблением регэкспа, либо отдельным форматом email-ref
  (решение — в спеке Плана 2).
- daily briefing включает email-дайджесты как ещё один тип входа.
- People-статистика по внешним контактам в План 2 НЕ входит (требует прямых `JOIN` на
  `messages`, т.е. фактически Варианта B).

## Что НЕ входит (явно отложено)

- Email-дайджесты/треки/briefing — План 2 (см. выше), не входит в План 1.
- Write-back статусов (прочитано/архив) в Gmail — План 3.
- Отправка писем из Watchtower (`gmail.send`) — не планируется в этой итерации.
- Влитие email в таблицу `messages` (Вариант B) — отвергнуто, см. раздел «Охват».
- People-статистика по внешним email-контактам — вне охвата (требует Варианта B).
- IMAP / Outlook / другие провайдеры — только Gmail.
- historyId-based incremental sync — возможное улучшение позже.
- Отдельная категоризация email в `targets.source_type` / `feedback.entity_type` —
  не нужна (email-item это обычный `inbox`-источник).
