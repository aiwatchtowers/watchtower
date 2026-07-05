# Task AI Agent — агентский чат на таск

**Дата:** 2026-06-26
**Статус:** Design (approved in brainstorm)
**Ветка:** TBD (от `main`)

## Проблема

У таска (`targets`) есть поле `intent` — свободный текст, что пользователь хочет
получить. Сегодня это мёртвый текст. Нужна кнопка, по которой AI стартует беседу
от интента, читает локальную Slack-базу и помогает довести таск до результата,
**предлагая действия и спрашивая разрешение** — как tool-calls у LLM.

## Решения (из брейншторма)

1. **Поверхность действий AI:** читать Slack-базу + драфтить ответы; **изменять сам
   таск**. Никаких внешних отправок (Slack/Jira/Calendar). Все записи — только в
   локальную SQLite watchtower. → нет внешних побочных эффектов и TCC-рисков.
2. **Модель подтверждения:** AI **предлагает** структурированное действие → Desktop
   рисует карточку Approve/Reject → запись в БД делает **Swift** (детерминированно),
   не AI. Модели write-доступ к БД не даём.
3. **Беседа:** одна постоянная беседа на таск (привязка к `target_id`), интент —
   seed/контекст, история копится между сессиями.
4. **Механизм передачи действия:** fenced-блок ```` ```watchtower-action ```` в тексте
   ответа, парсинг на стороне Swift. **Go-стрим не трогаем.**
5. **Action types v1:** все 5 — `updateStatus`, `updateNotes` (append),
   `updateProgress`, `addSubItem`, `createChildTarget`.

## Архитектура

Вся логика — в Desktop (Swift) + новый prompt-фрагмент. Go (`internal/ai`, CLI,
`internal/db`) **не меняется**. MCP остаётся read-only (`read_query`).

Прецедент в кодовой базе: `TrackChatView` / `TrackChatViewModel` — чат, привязанный
к треку через `ChatConversationQueries.fetchByContext(type:id:)` /
`create(contextType:contextID:)`. Новый чат — копия этого паттерна с контекстом
`type:"target"`.

### Компоненты

- **`TaskChatView` + `TaskChatViewModel`** — по образцу `TrackChatView`. Контекст
  беседы `type:"target", id:String(target.id)`. System-prompt строится из таска:
  `text`, `intent`, `status`, `notes`, `sub_items`. Стримит через
  `WatchtowerAIService` (существующий `ai query`), MCP read-only.
- **`ProposedAction`** — Swift-тип (struct + enum `kind`), декодируется из JSON
  блока. Поля по типам:
  - `updateStatus` → `status` (todo/in_progress/blocked/done/dismissed/snoozed)
  - `updateNotes` → `note` (append к существующим notes)
  - `updateProgress` → `progress` (0–100)
  - `addSubItem` → `text` (+ опц. `done` bool)
  - `createChildTarget` → `text`, `intent`, опц. `priority`
  - у всех — обязательный `reason` (зачем, для текста карточки)
- **`TaskActionParser`** — выделяет все ```` ```watchtower-action ```` блоки из
  накопленного текста turn'а, прячет их из видимого текста, возвращает
  `[ProposedAction]` + очищенный текст.
- **`TaskActionCard` (View)** — человекочитаемое описание действия + `reason` +
  кнопки Approve / Reject. Pending/applied/rejected состояния.
- **`TaskActionExecutor`** — по Approve вызывает существующие `TaskQueries`
  (`updateStatus`, `updateSubItems`, `create` для child, апдейт notes/progress).
  По завершении формирует follow-up сообщение и отправляет его в беседу как
  очередной user-turn, чтобы AI продолжил.

### Поток данных

```
intent + контекст таска ──seed──▶ system-prompt
user msg ─▶ ai query (read_query, read-only) ─stream─▶ текст + ```watchtower-action```
                                                  │
                          TaskActionParser ───────┘──▶ [ProposedAction]
                                                          │
                                              TaskActionCard [Approve/Reject]
                                       Approve │                    │ Reject
                          TaskQueries.write(targets)          follow-up "user rejected: <reason>"
                                       │                             │
                          follow-up "action executed: <summary>" ───┴──▶ next turn (AI продолжает)
```

Инвариант: **AI только предлагает, запись всегда делает Swift.** Модели не выдаём
write-MCP-тулов; `--allowed-tools` остаётся read-only.

## Контракт действия (prompt)

Новый фрагмент в system-prompt беседы инструктирует модель:

> Чтобы изменить таск — НЕ пиши в БД и НЕ вызывай инструменты записи. Выведи блок
> ```` ```watchtower-action ```` с ОДНИМ JSON-объектом `{ "type": "...",
> ...поля, "reason": "..." }`. Одно действие на блок (можно несколько блоков).
> После блока остановись и жди подтверждения — НЕ считай действие применённым.

Перечень `type` и обязательных полей фиксирован и валидируется Swift-декодером.

## Обработка ошибок / краевые случаи

- Невалидный/неизвестный `type` или битый JSON → видимая **карточка-ошибка**
  (не тихий no-op), AI получает follow-up «action invalid: …».
- Reject → follow-up «user rejected, reason: …»; AI переспрашивает/корректирует.
- Беседа выживает между запусками: resume по `session_id` из `chat_conversations`
  (как в `TrackChatViewModel`).
- Approve применяет ровно одно действие; UI сериализует подтверждения — гонок нет.
- Пустой intent → seed строится из `text`; беседа работает без секции intent.

## Тестирование

- **Go:** не меняется → существующие тесты остаются зелёными (явный non-goal: не
  трогать `internal/ai`/CLI/`internal/db`).
- **Swift:**
  - `TaskActionParser`: один блок, несколько блоков, блок посреди текста, битый
    JSON, отсутствие блока (чистый текст) — корректное вырезание и видимый текст.
  - `ProposedAction` декодер: каждый из 5 типов; неизвестный type → ошибка.
  - `TaskActionExecutor`: каждый type мапится на правильный `TaskQueries`-вызов;
    follow-up формируется и при Approve, и при Reject (degenerate clean-exit ветки
    тестируем явно — см. рабочий принцип «test degenerate clean-exit branches»).
  - `TaskChatViewModel`: загрузка/создание беседы по `target_id`, seed-промпт
    содержит intent.

## Не делаем (YAGNI)

Внешний Slack-send, Jira/Calendar-действия, batch-подтверждение в конце,
настоящий MCP write + `canUseTool`, отдельный модель-тир (берём текущую модель
чата), редактирование произвольных полей таска вне 5 action types.
