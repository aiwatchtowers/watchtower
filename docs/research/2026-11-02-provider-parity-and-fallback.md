# Claude / Codex: равноправие провайдеров и восстановление при лимитах

Дата: 2026-11-02. Исследование для target #1480. Срез кода: `8a36e3c87` (`v0.26.4`).

Это research report, не согласованная спецификация и не план реализации. Продуктовый код, настройки установленного приложения и учётные данные не изменялись. Model calls не запускались. Исследованы репозиторий, справка установленного CLI и официальная документация OpenAI.

## Вывод

**Добавлять Codex с нуля не требуется: он уже обслуживает почти все основные AI-пути. Проблема в выборе провайдера, применении настроек и отсутствии механизма восстановления.** Рабочая сессия Codex, основной чат и фон приложения выбирают провайдера по разным правилам. Даже после изменения общего AI Provider работающий daemon сохраняет ранее созданный генератор; Save в System Settings перезапускает его только при изменении настройки очистки данных.

Рекомендация агента: сначала сделать надёжным переключение всего AI приложения на Codex и явно показывать, какой провайдер сейчас работает. Затем добавить симметричный Claude ↔ Codex fallback для изолированных вычислений без инструментов, с общим состоянием недоступности и ограниченными повторами. Чаты и агентные автоматизации переводить только на безопасной границе, с проверкой уже выполненных действий. Полный переход чата на Codex app-server полезен для равноправного UX, но не нужен, чтобы вернуть работоспособность сейчас.

Наличие бинарника Codex не доказывает доступность модели и оставшийся лимит. Реальная конфигурация владельца и его текущий quota state не читались: ниже — доказанные свойства кода, объясняющие симптом, а не утверждение о точном состоянии его установки.

## Decisions

- **Владелец, conversation:** «Закончились лимиты на клод и очень трудно стало приложением юзаться. При том что кодекс стоит на машине. Надо ввести некое равноправие этих систем ну или какой-то фолбек. Отправь агента на астре это поресерчить чтоб мы нашли решение».
- **Рамки поручения, conversation / основной агент:** исследовать и предложить решение; сохранить отдельный Markdown report; не менять продуктовый код и не запускать платные model calls. Доску и запрос решения владельца ведёт основной агент.
- **Решил агент — рекомендация, не продуктовое обязательство:** не переписывать существующие adapters; исправить применение общего выбора провайдера, затем добавить общий маршрутизатор с ограниченным безопасным fallback.
- **Решил агент — рекомендация:** смена провайдера никогда не отменяет policy, ограничения инструментов, подтверждение действий, лимиты автоматизаций и требования к результату.
- **Решил агент — рекомендация:** запрет выбранного провайдера организацией остаётся конечным отказом; fallback на quota/outage разрешённого провайдера рассматривается отдельно и только внутри разрешённого списка.
- **Решил агент — рекомендация:** существующий Claude/Codex terminal session не превращать автоматически в сессию другого CLI. Для продолжения нужен новый агент с контекстом работы.
- **Пока не решено владельцем:** режим по умолчанию, порядок fallback, степень автоматизации чата, выбор моделей по провайдерам и роль лимитов в опережающей маршрутизации. Варианты приведены ниже.

## 1. Что можно сделать уже сейчас

Для ручного восстановления через интерфейс:

1. В **Settings → System → AI → AI Provider** выбрать **Codex**. Переключатель автоматически очищает старые Light/Strong/legacy model pins. Оставить модели на Default либо выбрать заведомо доступные для этого CLI и аккаунта.
2. Нажать **Save**. Затем полностью закрыть и вновь запустить Watchtower, чтобы пересоздать daemon и удерживаемые UI-компоненты. В исследованной версии одного Save недостаточно. Не использовать Reset LLM Data: для смены провайдера удаление данных не нужно.
3. В уже существующем основном чате отдельно выбрать **Codex** в provider pill. Диалог хранит последний provider/model и может восстановить Claude даже после изменения глобальных настроек. Смена между завершёнными ходами создаёт новый backend и передаёт историю из БД.
4. Для новых рабочих терминалов отдельно выбрать **Settings → System → Workbench → Default Agent → Codex**. Это не настройка фонового AI. Уже запущенный Claude-терминал остаётся Claude.

Основания: [SystemSettings.swift:185](../../WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift#L185), [SystemSettings.swift:37](../../WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift#L37), [AppState.swift:1471](../../WatchtowerDesktop/Sources/App/AppState.swift#L1471), [ChatViewModel.swift:641](../../WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift#L641), [ChatViewModel.swift:1198](../../WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift#L1198), [SystemSettings+Workbench.swift:9](../../WatchtowerDesktop/Sources/Views/Settings/SystemSettings+Workbench.swift#L9).

Эквивалент общего переключения через CLI, **пример для владельца, не выполнен исследователем**:

```sh
watchtower config set ai.provider codex
watchtower config set ai.model ''
watchtower config set ai.models.light ''
watchtower config set ai.models.strong ''
watchtower ai models --json
```

`config set ai.provider` сам не очищает модели, в отличие от UI. Поэтому очищаются все три override. Если используется нестандартный config, ко всем командам нужно добавить один и тот же `--config <config-file>`. Для нескольких workspaces учитывать соответствующий `--workspace <workspace>`.

Для установки, где daemon управляется вручную, после сохранения:

```sh
watchtower sync stop
watchtower sync --daemon --detach
```

Запускать вторую команду только после успешной остановки; не создавать второй daemon параллельно Desktop. В Desktop проще закрыть/открыть приложение. `sync --now` только будит текущий процесс и не заменяет перечитывание конфигурации. Разовый `--provider codex` меняет провайдера отдельной поддерживающей его команды, не глобальную настройку. Основания: [config.go:294](../../cmd/config.go#L294), [generator.go:605](../../cmd/generator.go#L605), [sync.go:98](../../cmd/sync.go#L98), [CLI guide](../guide/reference/cli.md).

В этом срезе defaults Codex — `gpt-5.6-luna` / `gpt-5.6-sol`, зафиксированные в registry. Это факт кода, **не проверка доступности моделей сегодня**. На исследовательской машине `codex --version` показал `0.166.0`; комментарии defaults опираются на проверку `0.145`. Не следует автоматически закреплять новую модель только из-за версии CLI. `watchtower ai models --json` для Codex показывает registry, а не подтверждённые права аккаунта. **Test Connection вызывает модель**: это полезная проверка пользователя после выбора, но в исследовании она не выполнялась.

Ручное переключение не переносит claude.ai connectors/publishing и не устраняет ограничения вложений Codex-чата. Основные native Watchtower tools уже доступны Codex.

## 2. Причины и доказательства

| Наблюдение в коде | Последствие |
|---|---|
| `ai.provider` по умолчанию `claude`; factories выбирают ровно один backend — [defaults.go:16](../../internal/config/defaults.go#L16), [generator.go:56](../../cmd/generator.go#L56) | Установленный Codex сам не становится резервом |
| `workbench.default_agent` независим от `ai.provider` — [config.go:458](../../internal/config/config.go#L458), [SystemSettings+Workbench.swift:9](../../WatchtowerDesktop/Sources/Views/Settings/SystemSettings+Workbench.swift#L9) | Можно работать в Codex, пока все сводки/reviews/embedded chats продолжают использовать Claude |
| Основной чат имеет собственный provider/model — [ChatViewModel.swift:1208](../../WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift#L1208) | Изменение одного чата не спасает фон, а глобальная смена не переводит автоматически старые диалоги |
| Общий generator создаётся один раз — [sync.go:936](../../cmd/sync.go#L936); он хранит один `inner` — [provider_policy.go:79](../../cmd/provider_policy.go#L79) | Работающий daemon не следует за сохранённым новым provider |
| Save вызывает restart только при `lastSaveChangedPurge` — [SystemSettings.swift:37](../../WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift#L37) | UI может показывать Codex и Saved, пока фон остаётся на Claude; это конкретный дефект применения настройки |
| `ClassifyClaudeError` возвращает `rate_limit, retryable=true` — [claude_translate.go:656](../../internal/chat/claude_translate.go#L656) | Ошибка распознана, но смены провайдера, reset time и общего circuit breaker нет |
| `ErrAICall` объединяет timeout/network/auth/quota — [timeout_generator.go:118](../../internal/digest/timeout_generator.go#L118) | Это сигнал для обработки сбоя pipeline, а не готовая политика fallback: не различает короткий rate limit и исчерпанную подписку |
| Plan usage — отдельный информационный poller — [plan_usage.go:15](../../internal/daemon/plan_usage.go#L15), [guide](../guide/concepts/ai-providers-and-cost.md) | Показанный 100% сам по себе не приостанавливает задачи и не переключает backend |
| `ByID` возвращает Claude для неизвестного ID — [registry.go:73](../../internal/providers/registry.go#L73) | Новый router не должен наследовать молчаливое превращение ошибки конфигурации в Claude |

Не найден общий runtime fallback Claude → Codex либо Codex → Claude. Существующие fallback внутри файлов относятся к default model, parsing, credentials lookup, устаревшей session или восстановлению локального состояния; они не дают отказоустойчивость между провайдерами.

## 3. Карта AI-путей

Здесь «общий provider» — `ai.provider` на момент создания соответствующего объекта/процесса, с возможным `--provider` там, где команда его применяет.

| Путь | Выбор и состояние Codex | Основные точки |
|---|---|---|
| Slack digests, rollups, tracks, people, Inbox, ideas, reactions, next steps, custom tracks, briefing/day plan | Общий pooled generator; Claude/Codex/Ollama уже реализованы | [sync.go:936](../../cmd/sync.go#L936), [generator.go:93](../../cmd/generator.go#L93), [models.go:17](../../internal/digest/models.go#L17) |
| Memory: extraction, email episodes, beliefs, reflection, rewrites | Отдельная factory, тот же configured provider через bounded generator | [memory.go:134](../../cmd/memory.go#L134), `internal/memory/` |
| AI extraction целей/задач, next steps, meeting prep/recaps/chapters/notes/follow-up, dictate clean, prompt experiments, catchup | Через общий Generator; не Claude-only | [targets_ai.go:73](../../cmd/targets_ai.go#L73), [meeting.go:93](../../cmd/meeting.go#L93), [meeting_transcript.go:56](../../cmd/meeting_transcript.go#L56), [dictate.go:25](../../cmd/dictate.go#L25), [catchup.go:162](../../cmd/catchup.go#L162) |
| Main/target chat protocol v2 | Claude — тёплый процесс; Codex — новый `codex exec` на ход с replay из БД | [ai_session.go:236](../../cmd/ai_session.go#L236), [turn_backend.go:52](../../internal/chat/turn_backend.go#L52) |
| Embedded chats / automation editor / setup / code questions | Обычно global provider; `ai query`, Codex MCP и read-folder поддержаны; нет единого picker как в main chat | [generator.go:147](../../cmd/generator.go#L147), [EmbeddedChatWiring.swift:76](../../WatchtowerDesktop/Sources/Services/EmbeddedChatWiring.swift#L76), [CodeQuestionSurface.swift:50](../../WatchtowerDesktop/Sources/Services/ChatSurfaces/CodeQuestionSurface.swift#L50) |
| `ask`, query, REPL | Общий `ai.Provider`; Codex реализует Query/QuerySync. Неинъецированный REPL имеет исторический Claude fallback, обычный root его обходит | [generator.go:118](../../cmd/generator.go#L118), [root.go:196](../../cmd/root.go#L196), [repl.go:47](../../internal/repl/repl.go#L47) |
| Jira board analysis и AI helpers tools | Отдельный `checkedAIClient`, общий provider; wrapper проверяет policy при каждом вызове | [sync.go:1259](../../cmd/sync.go#L1259), [actions_registry.go:114](../../cmd/actions_registry.go#L114) |
| Built-in automations и custom recipe `llm()` | Shared/bounded Generator, оба CLI; schema валидируется приложением | [automations_backends.go:98](../../cmd/automations_backends.go#L98), [sdk_llm.go:155](../../internal/automations/sdk_llm.go#L155), [automations_run.go:25](../../cmd/automations_run.go#L25) |
| Recipe `agent()` | Отдельный runner по общему provider; Codex уже запускается с изолированным home и bound MCP | [automations_backends.go:137](../../cmd/automations_backends.go#L137), [automations_backends.go:174](../../cmd/automations_backends.go#L174) |
| Recipe `session()` | Workbench agent, а не просто Generator; существующий session lifecycle и записи | [automations_backends.go:114](../../cmd/automations_backends.go#L114), `internal/automations/sdk_session.go` |
| Spec/plan independent review | Общий provider, Codex read-folder без MCP уже поддержан; не обязан совпадать с автором рабочей сессии | [workbench_spec_review.go:89](../../cmd/workbench_spec_review.go#L89), [workbench_spec_review.go:104](../../cmd/workbench_spec_review.go#L104) |
| Diff/session overview и review lessons | Общий bounded Generator | [workbench_review_overview.go:43](../../cmd/workbench_review_overview.go#L43), [reviewai/overview.go:297](../../internal/reviewai/overview.go#L297) |
| Workbench ask guard, terminal/chat titles, instruction suggestions, coach | Общий provider; coach имеет собственную тройную factory, её важно не пропустить при router migration | [workbench_askguard_stop.go:445](../../cmd/workbench_askguard_stop.go#L445), [terminal.go:27](../../cmd/terminal.go#L27), [chat.go:26](../../cmd/chat.go#L26), [daemon/coach.go:36](../../internal/daemon/coach.go#L36) |
| Media descriptions и link summaries | Text generator + optional ImageGenerator; image adapter есть у обоих CLI | [media/describe.go:62](../../internal/media/describe.go#L62), [codex/generator.go:70](../../internal/codex/generator.go#L70), [digest/image.go:207](../../internal/digest/image.go#L207) |
| Workbench coding sessions | Отдельный `AgentKind` Claude/Codex, свои hooks/resume/transcripts; уже реализованы обе системы | [Codex workbench design](../superpowers/specs/2026-10-12-codex-workbench-agent-design.md), [Codex guide](../guide/features/workbench/codex.md) |

Не все операции, называемые extraction, требуют LLM. `internal/extract` обрабатывает text/OOXML/PDF и локальный OCR helper; перенос этого компонента между AI-провайдерами не нужен. Запись и распознавание аудио имеют отдельный transcription stack; Claude/Codex нужны последующей очистке/recap. Обычный sync, поиск и чтение уже сохранённых данных должны продолжать работать при недоступном AI.

### Настоящие Claude-specific возможности

- **claude.ai connectors и publishing**: включаются только при provider Claude, на нужной surface и допустимом auth mode — [ai_session_gate.go:61](../../cmd/ai_session_gate.go#L61). Native интеграции Watchtower и Quick Connections — другой механизм; наличие их у Codex не означает переноса claude.ai сервисов.
- **Тёплый chat process, контроль разрешений claude.ai, Claude tool/event dialect**: `internal/chat/claude_backend.go`, `claude_translate.go`, `controlproto.go`. Это adapters, а не основание привязать бизнес-логику к Claude.
- **Claude plan usage**: `internal/planusage`; read-only чужие credentials, собственный polling/backoff. Расширение Codex usage ведётся отдельно в #1470.
- **Часть analytics/integration**: Claude transcripts/settings имеют собственные parsers. Workbench уже использует Codex hooks/rollouts/sessionfeed, но это не тот же протокол. Полная аналитическая паритетность — отдельный объём и не блокирует исправление AI routing.

## 4. Несовпадения capabilities

| Capability | Что имеется | Значение для fallback |
|---|---|---|
| Текст / JSON | Оба генератора возвращают текст. CLI `--json` описывает envelope событий, не гарантирует JSON внутри ответа | Сохранять parser/schema/domain validation; malformed output не считать quota failure |
| Native Watchtower tools | Claude/Codex монтируют общий MCP с surface/turn binding | Нужен тот же набор разрешений и контекст, а не голый второй client |
| Quick Connections | Codex загружает их перед каждым ходом; конфликтующие env настройки могут быть исключены | Проверять доступность требуемых инструментов до переключения — [generator.go:587](../../cmd/generator.go#L587) |
| claude.ai tools/publish | Только Claude mode | Не обещать продолжение той же задачи, если альтернативного инструмента нет |
| Вложения чата | Codex TurnBackend сейчас принимает text-like, image/PDF отвергает до model call | Способность Codex CLI принимать image ещё не означает её поддержку этим chat adapter — [turn_backend.go:57](../../internal/chat/turn_backend.go#L57) |
| Vision background | Оба leaf adapters умеют image | Capability должна проходить через wrappers; см. отдельное замечание ниже |
| Read-folder | Codex включает shell в read-only sandbox, reviewer выключает MCP | Не переносить ограничения обычного text generator на reviewer; timeout/read-only policy обязательны |
| Continuation | Claude — warm process внутри session; Codex chat — ephemeral exec и replay | Нельзя передать Claude session ID в Codex. Источник общей истории — Watchtower DB |
| Tool events | Codex client отдаёт bare ToolBoundary, не подробный ToolEvent | Отсутствие видимых шагов не доказывает отсутствия побочных эффектов — [client.go:353](../../internal/codex/client.go#L353) |
| Model catalog | Claude aliases, статические Codex defaults, live models только у Ollama | Модели и их доступность держать отдельно для каждого провайдера; не переносить `opus` в Codex |

`ResolveModelsFor` уже защищает per-command override от использования моделей другого configured provider — [registry.go:115](../../internal/providers/registry.go#L115). Но конфигурация хранит только одну пару overrides активного провайдера. Для равноправного переключения туда/обратно потребуется модель настроек, сохраняющая предпочтения обоих, либо первоначально использовать defaults альтернативы. Это изменение схемы настроек нужно согласовать, а не скрыто вводить в этом исследовании.

**Две дополнительные находки для реализации, не причины установленного quota-инцидента:**

1. Обычный `CodexGenerator.Generate` использует `buildArgs → execArgs`; shell/apps отключены, но нет полного отключения owner MCP/hooks/web settings, которое отдельно предусмотрено в `buildImageArgs` и MCP-aware client. Поэтому классификация «любой Generator заведомо без инструментов» пока недостаточна. Перед безопасным batch fallback нужна проверяемая изоляция именно этого пути — [generator.go:48](../../internal/codex/generator.go#L48), [generator.go:159](../../internal/codex/generator.go#L159), [generator.go:218](../../internal/codex/generator.go#L218).
2. `policyCheckedGenerator` не реализует ImageGenerator; `ImageCapable` проходит только известные wrappers и затем делает type assertion. В текущей daemon-цепочке `pool → timeout → policyCheckedGenerator` image capability теряется независимо от Claude/Codex. Это статически установленное wiring-расхождение, его runtime проявление на данных владельца не проверялось — [provider_policy.go:79](../../cmd/provider_policy.go#L79), [image.go:59](../../internal/digest/image.go#L59). Новый router должен прокидывать capability вместе с policy, а не обходить policy ради image.

## 5. Повтор после ошибки: где безопасно

**Единица retry — вычисление или проверяемый шаг, не pipeline, не весь рецепт и не произвольный агентный ход.**

- Для изолированного text/JSON вызова без инструментов повтор допустим: результат проверяется, а запись производится один раз вызывающим pipeline. Цена первой попытки всё равно учитывается. Timeout ограничивает совокупную работу, а не даёт каждому fallback новый полный бюджет.
- Для chat/`agent()` quota может возникнуть после успешных tools. Простой `if err { call codex }` повторит часть действий либо создаст второй pending proposal.
- `Registry.Propose` каждый раз делает новый `InsertAgentAction`; гарантии Apply относятся к одной строке action, а не к двум одинаковым вызовам модели — [registry.go:517](../../internal/tools/registry.go#L517), [agent_actions.go:65](../../internal/db/agent_actions.go#L65). Даже если внешняя запись требует approval, дублирование предложений уже побочный эффект. При `TrustExecute` действие могло выполниться inline.
- В automation replay уже есть журнал с проверкой sequence и args hash; он восстанавливает завершённые SDK steps без исполнения. Но `agent()` — один SDK step, а его внутренние tools не превращаются автоматически в безопасную точку рестарта — [replay.go:75](../../internal/automations/replay.go#L75), [automations inventory](../inventory/automations.md).
- EmbeddedChatEngine несёт `alreadyApplied` на Retry — [EmbeddedChatEngine.swift:270](../../WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/Embedded/EmbeddedChatEngine.swift#L270). Это существующий механизм конкретной surface, не общая межпровайдерная дедупликация.
- Replay основного чата сознательно исключает текущий turn — [replay.go:118](../../internal/chat/replay.go#L118). При fallback посреди того же turn нужен отдельный handoff record о совершённых действиях; нельзя надеяться, что обычный ReplayFromDB уже передаст их.

Рекомендация для первого выпуска: автоматически переключать chat только после доказанного отказа до начала инструментов и любого эффекта. Консервативный вариант — после старта tools показывать «Продолжить через Codex», сначала завершать старый процесс и сверять журнал. Одного отсутствия text_delta недостаточно: инструменты могли работать молча. Нужны сведения на серверной стороне dispatch, а не только видимые UI steps.

Системный вариант: стабильные operation/attempt IDs, привязка эффекта к logical step, повторное получение существующего receipt вместо нового proposal, состояния `not_started / started / effect_unknown / completed`, сверка внешнего результата при неопределённом исходе. Одинаковый hash аргументов сам по себе не годится: пользователь мог намеренно попросить одинаковое действие дважды. Не обещать exactly-once для внешнего API без его idempotency/reconciliation механизма.

Workbench terminal session переносить в другой CLI только как новый session с кратким handoff: цель, прогресс, git diff, незавершённые asks, выполненные операции и места неопределённого результата. Старую сессию сохранить; не запускать два write-capable агента поверх одного незавершённого действия.

## 6. Рекомендуемый механизм маршрутизации

Следующее — предложение агента для будущей спецификации.

Общий router должен выбирать **провайдера для задачи с требованиями**, а не просто «следующее имя из списка». Нужны purpose/surface, tier или explicit model, необходимые capabilities, политика повторного исполнения, общий deadline и budget. Существующие `digest.Generator`, `ai.Provider`, `chat.Backend`, `automations.AgentRunner` можно сохранить как фасады; единое решение о маршруте должно обслуживать все четыре, включая отдельные coach/reviewer factories.

Порядок решения:

1. Проверить выбранный provider и policy. Если выбранный provider запрещён, вернуть текущий policy error без fallback.
2. Построить только заранее разрешённые владельцем альтернативы; пересечь их с актуальной организационной policy. Для каждой попытки заново проверить её provider и необходимые tools.
3. Разрешить модель именно этого провайдера и tier. Explicit pin не переписывать молча; показать фактическую альтернативную модель. Ошибка model unavailable не равна исчерпанию quota.
4. Проверить capability, доступность binary/auth configuration и состояние circuit. «CLI установлен» и «каталог содержит model» не равны успешной авторизации или entitlement.
5. Выполнить попытку с ограничением времени; классифицировать результат типизированно. Если retry безопасен и альтернативе разрешён доступ, переключиться один раз. Не выполнять бесконечный Claude → Codex → Claude цикл.
6. Сохранить actual provider/model, причину и attempt linkage. Leaf пишет usage каждой реальной попытки, wrapper не создаёт второй ledger row.

### Классы отказа

| Класс | Предлагаемое действие |
|---|---|
| `quota_exhausted` с reset time | Закрыть этот quota scope до reset/проверки; выбрать безопасную разрешённую альтернативу |
| Краткий `rate_limited` / overload / временная сеть | Небольшой ограниченный backoff с jitter либо fallback в оставшемся общем deadline; не считать каждый 429 недельным исчерпанием |
| Auth required/expired | Явное действие «Войти»; не долбить login повторными model calls. Допустимость разрешённого резервного provider определить отдельно |
| Model unavailable / CLI incompatible | Показать исправление model/CLI; не отправлять тот же ID другому provider и не маскировать как quota |
| Policy/security/sandbox refusal | Не обходить fallback. Ошибка безопасности остаётся видимой |
| Invalid request / schema mismatch / context too large | Исправление конкретного запроса; bounded validation retry отдельно от provider health |
| User cancel / deadline/budget exhausted | Остановиться; никакого запуска второй модели после отмены |
| Ошибка после side effect или неизвестный исход tool | Сверка состояния/явное продолжение; не слепой повтор |

Сейчас generic classifiers строковые и различаются: chat знает `usage limit`, digest matcher — `rate_limit_error`, `429` и др. Формулировка наподобие `You've hit your limit` без этих маркеров не обязана классифицироваться как quota. Нужен набор fixture-тестов реальных публичных форматов обеих CLI, с typed metadata там, где она доступна; парсинг человекочитаемой фразы — запасной путь. Не логировать credentials или промпты ради диагностики.

### Circuit, оба провайдера исчерпаны, восстановление

- Health хранить по account/auth scope, provider и при необходимости model/quota bucket. Один и тот же аккаунт может обслуживать несколько workspace и процессов; локальный bool в одном generator не остановит остальных.
- Минимум общего состояния должен переживать restart и быть видим daemon/chat/reviewer. Не удерживать DB lock во время CLI или сети. Для неизвестного account identity использовать приватный локальный opaque scope, без токенов в БД.
- При закрытом circuit фон откладывает AI-шаги, оставляет входные данные и cursors для повторной обработки. Ошибка провайдера не должна переводить материал в «невалидный/навсегда пропущен». Сохранить semantics `ErrAICall` history backfill; проверить отдельно budgets/attempt counters остальных pipelines.
- Если обе системы недоступны, не ставить весь sync на многоминутное ожидание. Продолжить сбор данных и не-AI операции; показать одно состояние «AI временно недоступен», отдельно причины Claude/Codex и ближайший известный reset. Не обещать точное время, если провайдер его не дал.
- После reset — single-flight half-open probe: один реальный ожидающий запрос, затем постепенный возврат очереди с приоритетом интерактивного чата. Не запускать каждый отложенный job одновременно и не расходовать quota регулярными «reply ok» probes.
- Пользовательский «Повторить» может инициировать ограниченную проверку; policy и budget продолжают действовать. Успешный вход, смена модели или конфигурации инвалидируют только соответствующий failure state.
- Чтобы избежать постоянных переключений, не возвращать активный чат на Claude посреди диалога; policy preference и фактически текущий provider — разные значения.

Plan usage полезен как advisory signal с freshness и reset time. Не делать проценты или линейную projection единственным источником отказа: spec-review уже удалил NearLimit gate по решению владельца 2026-10-26 из-за ложных прогнозов после reset — [spec-review note](../features/spec-review.md). Опережающее резервирование квоты для чата потребует отдельного согласования; реактивный fallback по фактическому отказу можно реализовать независимо от #1470.

### Usage и budgets

В `llm_calls` уже есть provider/model/purpose/surface и запись leaf-вызовов — [ledger note](../features/llm-usage-ledger.md). Добавить корреляцию попыток можно без двойного подсчёта самих вызовов. UI должен объяснять, что «задача выполнена Codex после лимита Claude», а не показывать только ошибку первой попытки или только предполагаемый исходный provider.

Важно: automation `MeteredModelCall` сейчас оборачивает один `Generate` — [sdk_llm.go:255](../../internal/automations/sdk_llm.go#L255). Скрытый второй вызов внутри нового wrapper может не учитываться в budget так же, как в usage ledger. Поэтому router требует attempt-aware metering: каждая попытка учитывается, при этом сохраняется один logical SDK step. До этого `llm()` нельзя автоматически включать в fallback только потому, что его interface совпадает с batch. Ошибка/неизвестная usage первой попытки не делает её бесплатной; правила оценки должны быть согласованы с существующим контрактом автоматизаций.

## 7. Варианты и рекомендуемый объём

| Вариант | Что даёт | Ограничение | Оценка агента |
|---|---|---|---|
| Только ручной global Codex | Немедленно освобождает большинство AI-функций от Claude | Нужны Save + restart + учёт старых chats; следующую quota пользователь решает сам | Использовать для восстановления сейчас |
| Надёжное общее переключение + безопасный fallback вычислений | Автозапуск резервного provider для классификации/сводок/extraction; доступный явный switch чата | Agent/tool turns требуют отдельной границы; capabilities не становятся одинаковыми автоматически | **Рекомендуемый первый продуктовый объём** |
| Общий router, health store, per-provider настройки, безопасный chat/agent handoff | Системное равноправие и управляемое восстановление всех поверхностей | Нужны lifecycle, replay, metering и operation identity; больший объём | Целевая архитектура |
| Полный Codex app-server chat сразу | Warm session, richer events, approvals, structured status | Сам по себе не исправляет daemon routing, настройки и повтор side effects | Делать отдельным этапом, не блокировать восстановление |
| Прямой OpenAI API вместо Codex CLI | Другой транспорт и контроль запросов | Иная авторизация/расходы/продуктовая договорённость; установленный CLI уже даёт нужный seam | Не нужен для исходной проблемы |

Минимальное продуктовое спасение, предложенное агентом:

1. Исправить применение `ai.provider`/моделей к daemon и новым embedded sessions: одна управляемая остановка/перезапуск после Save либо безопасная реконфигурация между jobs. Показать исходный/фактический provider и объяснить отдельный выбор Workbench agent.
2. Добавить пользователю понятный переход на доступный Codex при quota Claude. Для первого выпуска достаточно явного переключения всего AI и кнопки продолжения чата между ходами; никаких автоматических изменений live config без выбранного режима.
3. Нормализовать ошибки и изоляцию, затем подключить один fallback на уровне безопасного вычисления. Сначала text-only batch; read-only reviewer — отдельный профиль с теми же ограничениями. Для automation llm включать только после корректного metering всех попыток. Tool-bearing `agent()` и terminal sessions не ретраить целиком.
4. Добавить общий cooldown/deferred state, чтобы обе исчерпанные подписки не превращали каждую синхронизацию в серию одинаковых неудач.

Это последовательность снижения риска, а не утверждённые таски или сроки. Главная ценность — перестать оставлять половину приложения на скрытом Claude и перестать безрезультатно вызывать заведомо недоступный provider.

## 8. Codex: что подтверждено без model calls

Локально выполнены только `codex --version` и `codex exec --help`: версия `0.166.0`, существуют exec/resume/fork, `--ephemeral`, `--image`, config overrides. Эти команды не проверяют аккаунт, доступ к модели или квоту.

Официальная документация OpenAI подтверждает:

- `codex exec` поддерживает structured output через `--output-schema` и повторное использование CLI authentication. В текущем Watchtower Generator schema передаётся текстом, отдельного schema-аргумента interface нет. [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).
- App-server предоставляет persistent threads/turns, `thread/resume`, per-turn `outputSchema`, `account/rateLimits/read`. Это возможная основа richer backend и общего quota-monitor, но текущий `internal/codex/appserver.go` используется для hook trust, а не model turns. [Codex App Server](https://learn.chatgpt.com/docs/app-server), [appserver.go:48](../../internal/codex/appserver.go#L48).

Документация и установленная CLI могут развиваться независимо. Перед реализацией нужно проверить доступные schemas/capabilities конкретной поддерживаемой версии без inference и закрепить протокольными fixtures. Не требуется читать или копировать OAuth tokens в собственную систему ради fallback.

## 9. Связанные работы и источники

- **#1470 — Codex plan usage**, по сообщению основного агента. Переиспользовать будущие limits/health DTO и freshness; не создавать второй poller. Reactive fallback не должен ждать завершения всего usage UI.
- **#1479 — reviewer provider/model из author session и lifetime Codex instructions file**, по сообщению основного агента. Не дублировать изменения. Сейчас reviewer выбирает global provider; `Client.Query` и Generator удаляют instructions file на первом output — [client.go:280](../../internal/codex/client.go#L280), [generator.go:96](../../internal/codex/generator.go#L96). Завершение этой работы — зависимость надёжности Codex, отдельная от quota routing.
- [Model/provider registry feature](../features/model-provider-registry.md) и [исходный design](../superpowers/specs/2026-08-18-model-provider-registry-design.md): существующие tiers, scoping и явно отсутствующий fallback.
- [Multi-provider design](../specs/multi-provider-design.md): историческая отправная точка; текущий код и более свежие feature notes приоритетнее.
- [Codex workbench design](../superpowers/specs/2026-10-12-codex-workbench-agent-design.md): отдельный lifecycle coding agent, shipped deviations в §15.
- [Chat redesign](../features/chat-redesign.md), [embedded chat](../features/embedded-chat.md), [claude.ai tools](../features/chat-claude-ai-tools.md): разные runtimes и surface capabilities.
- [Automations](../features/automations.md), [agent actions](../features/agent-actions.md), [Quick Connections](../features/quick-connections.md): budgets, replay, proposals и tool allowlists.
- [Spec review](../features/spec-review.md), [author loop design](../superpowers/specs/2026-10-26-spec-review-author-loop-design.md), [severity design](../superpowers/specs/2026-10-28-spec-review-severity-design.md): reviewer не должен блокировать доступ владельца к ask при недоступности AI.
- [Organization policy](../guide/reference/organization-policy.md), [provider_policy.go:15](../../cmd/provider_policy.go#L15): запрещённый configured provider не заменяется автоматически.

## 10. Открытые решения и проверка будущей реализации

Рекомендуемые ответы агента, требующие решения владельца:

1. **Режим:** сохранить ручной provider и добавить явный режим «основной + резервный», либо сразу сделать Auto по умолчанию? Рекомендую явный основной + резервный без молчаливого изменения существующих установок.
2. **Первый охват:** только batch/read-only вычисления или также chat до начала действий? Рекомендую batch и явное безопасное продолжение чата; автоматически повторять tool turns только после появления доказуемой границы.
3. **Model preference:** хранить light/strong отдельно для обоих провайдеров? Рекомендую да; defaults альтернативы допустимы как первый упрощённый шаг. Решение #1479 об авторской модели reviewer сохранять как отдельную входную preference.
4. **Quota strategy:** реакция на фактический отказ или опережающее распределение по процентам? Рекомендую реактивный механизм сначала; проценты показывать и использовать осторожно, учитывая свежесть.

Критерии, которыми стоит проверить будущую реализацию без реальных платных вызовов:

- Fake Claude отказывает до inference, fake Codex успешно возвращает JSON: одна запись результата, две честно учтённые попытки, правильный tier альтернативы.
- Выбранный provider запрещён policy: ни один fallback process не запускается. Альтернатива запрещена после изменения policy: не запускается тоже.
- Сохранение AI Provider действительно меняет следующий daemon job; незавершённая работа не теряет checkpoint. Старый chat честно показывает свой pin.
- Burst 429, quota с reset, expired auth, unavailable model, malformed JSON и user cancel приводят к разным действиям; после cancel второй process не появляется.
- Tool успел создать proposal/внешний объект, затем quota: новый provider не делает повтор автоматически; неопределённый исход виден и подлежит сверке.
- Обе системы исчерпаны: один понятный статус, данные продолжают синхронизироваться, очередь сохраняется, нет storm при reset или restart.
- Attachment/tool capabilities проверяются до отправки запроса; отсутствие claude.ai функций не маскируется уверенным успешным ответом.
- Все attempts входят в automation budget и leaf usage ledger, без удвоения одного вызова; общий deadline не умножается на число альтернатив.
- No-tools генератор действительно не наследует инструменты/хуки пользователя; wrappers не теряют image capability и не обходят policy.

В этом исследовании тесты продукта не запускались: код не менялся, выводы получены статическим чтением. До утверждения реализации остаются непроверенными фактический provider/config владельца, доступность его Codex-моделей, auth/quota и воспроизведение на установленном приложении. Эти проверки не нужны для подтверждения перечисленных wiring-дефектов, но нужны для утверждения «у владельца всё восстановлено».
