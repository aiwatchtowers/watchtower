# Резервный AI-провайдер: Claude ↔ Codex

**Статус:** поведение D1–D7 согласовано в ask #937; спецификация одобрена без замечаний в ask #939. Реализация routing начнётся после одобрения плана.
**Target:** #1480. **Research:** [provider parity and fallback](../../research/2026-11-02-provider-parity-and-fallback.md).
**Дата:** 2026-11-02. Макеты — presentation-only, не работающие настройки.

## Decisions

| ID | Решение / источник |
|---|---|
| O1 | **Владелец, ask #927:** «Воркбенчи переключать не надо. Но я должен иметь возможность добавить провайдера кодекса и если клод по лимитам пошел по пизде будет через кодекс работать. Тут важно ничего текущего не поломать и продумать моменты когда лимиты восстановятся. Давай брейнштормить». |
| O2 | **Владелец, ask #930, дословно:** «не то что основным. Смотрим с точки зрения кастомера. У одного основной клод. У другого кодекс. Важно уважать это». Это НЕ одобрение конкретной политики возврата живого чата. |
| D1 | **Владелец, ask #937 (routing):** opt-in reserve для обеих сторон; fallback только по подтверждённой quota, максимум две попытки одного безопасного вычисления. |
| D2 | **Владелец, ask #937 (recovery):** shared persistent cooldown, один recovery probe после reset; фон возвращается на preferred, уже переключённый чат остаётся на actual до ручной смены. |
| D3 | **Владелец, ask #937 (routing, existing_chats):** явный provider/model pin запрещает автоматическую замену в этой операции; per-provider light/strong настройки сохраняются отдельно. |
| D4 | **Владелец, ask #937 (safe_scope):** preflight routing tool-bearing turn допустим, повтор после его запуска запрещён; произвольные automation recipes не перезапускаются. |
| D5 | **Владелец, ask #937 (safe_scope):** deferred outcome только для явно перечисленных идемпотентных pipeline AI-шагов; generic persistent job queue не вводится. |
| D6 | **Владелец, ask #937 (routing):** попытки учитываются отдельно в usage и budget; logical SDK step один; сохранение настроек должно подтверждать их фактическое применение к daemon. |
| D7 | **Владелец, ask #937 (routing):** UI и reason codes ниже — предлагаемый контракт v1; макеты не доказывают реализацию. Guard tests и inventory на стадии проекта не меняются. |

В **ask #937** владелец выбрал «Да, как в спецификации», «Оставить до ручной смены», «Сохранить закрепление» и «Да, безопасный первый этап». D1–D7 согласованы в этих границах. Конкретные ключи, интервалы и механизмы ниже — детализация агента для review; одобрение направления не заменяет review документа. Старые чаты сохраняют закрепление до явного включения Preferred + reserve.

## 1. Продуктовый результат и границы

Владелец сохраняет привычный preferred provider и по желанию подключает второй. Когда preferred действительно исчерпал лимит, поддерживаемая операция выполняется резервом без изменения основной настройки. UI показывает фактически использованный provider. При восстановлении фоновая работа возвращается к preferred по правилам §5.

Направления равноправны: Claude preferred / Codex reserve и Codex preferred / Claude reserve. `ai.provider` остаётся источником preferred. Наличие второго установленного CLI само по себе не разрешает fallback и не подключает его.

**Вне v1:** переключение/перезапуск Workbench terminal sessions, перенос CLI transcripts между системами, app-server rewrite, балансировка по процентам плана, резерв Ollama/API, новая универсальная очередь заданий, повтор всего pipeline или recipe, автоматическая подмена недоступных tools/attachments. `workbench.default_agent`, hosted session adoption, PTY и hooks остаются как есть.

## 2. Подключение и настройки

В существующем Settings → System → AI разместить два компактных блока: Preferred provider и Reserve provider. У каждого свои Light/Strong model overrides, CLI path и connection status. Существующие поля выбора provider, моделей и CLI path сохраняют нынешний UI и переиспользуются при выборе bucket; этот проект не переделывает весь Settings. Макеты показывают новые компактные панели fallback и read-only summaries этих существующих полей; сами существующие editors находятся вне кадра. Для двух поддерживаемых providers reserve всегда другой; один provider не может резервировать сам себя.

Подключение состоит из локального поиска CLI и проверки sign-in доступным metadata-механизмом; оно **не запускает inference** и не обещает entitlement модели. При отсутствии входа — конкретная подсказка входа в CLI и Retry. Network/metadata error отличается от «не вошёл». Если статус входа нельзя проверить без запроса модели, статус «Connection not verified», резерв не активируется автоматически; отдельный существующий Test Connection остаётся явным model call по нажатию владельца.

После подключения переключатель «Use reserve when limits are reached» изначально off. В ready mockup показан следующий шаг: владелец уже включил его и собирается нажать Save. Модели берутся из registry, не из литералов Swift. Успешный metadata check не превращает недоступную модель в quota error.

Предлагаемые ключи (названия требуют review):

```yaml
ai:
  provider: claude
  fallback:
    enabled: false
    provider: codex
  providers:
    claude:
      models: {light: "", strong: ""}
    codex:
      models: {light: "", strong: ""}
```

Остальные `ai.*`, `claude_path`, `codex_path`, Ollama configuration сохраняются. Fallback конфигурация с одинаковыми provider IDs, неизвестным ID или включённым Ollama preferred отклоняется с понятной ошибкой; не преобразуется молча в Claude. При выключенном fallback действующий Ollama путь неизменен.

**Миграция:** при первой записи нового формата перенести эффективные legacy `ai.models.light/strong` и `ai.model` только в bucket configured provider, с существующей нормализацией registry. Уже существующий новый bucket выигрывает; другие providers не получают эти pins. Legacy значения сохраняются для обратной совместимости, но при наличии нового bucket не участвуют в resolution. Отсутствующий bucket до миграции читает legacy для configured provider; пустые значения нового bucket означают Default. Миграция атомарна, не включает fallback и не меняет `ai.provider`. Старый бинарник не гарантированно понимает новый reserve; downgrade procedure должен явно сообщать об этом.

**Save/apply:** атомарно сохранить config revision; daemon на безопасной границе текущего job пересоздаёт AI factories/clients и подтверждает revision. Предпочтителен reload AI routing между jobs; если нужна остановка daemon, она проходит существующую очередь управления daemon, не закрывает PTY/hosted sessions и не теряет checkpoint. Новые embedded sessions получают новую revision, активный chat turn завершается со старой. UI показывает Applying до ack, а при сбое — «Settings saved; background update failed» + Retry и actual previous revision. Retry повторяет применение, не перезаписывает устаревшую копию config. Новая revision инвалидирует неподходящие warm clients. Ни Save, ни reconnect не выводят «готово» до ack. Проверка — actual provider следующего job, не просто текст настройки.

## 3. Pins, preferred и actual

Разделить три значения: configured preferred, routing mode конкретного запроса, фактический provider/model попытки. Fallback не переписывает preference.

| Выбор | Семантика |
|---|---|
| Global preferred + enabled reserve | Фон использует tier preferred, при quota — тот же tier reserve из его bucket |
| Chat «Preferred + reserve», model Auto | Наследует разрешённый reserve и capability policy; может использовать уже выбранный для диалога actual |
| Chat «Only Claude» / «Only Codex» | Жёсткий provider pin; no fallback, даже если reserve включён глобально |
| Явный chat model или `--model` | Жёсткая пара provider/model; no automatic substitution. Для включения fallback выбрать Auto |
| `--provider` отдельной CLI-команды | Сохраняет нынешний смысл явного выбора одного provider; no fallback v1 |
| Global Light/Strong overrides | Это tier preference соответствующего provider, не запрет его резерва |

Старые conversations с записанным provider/model мигрируют консервативно в pin: нельзя угадать, был ли старый provider сознательным выбором. Новые chats по умолчанию — Preferred + reserve / Auto. На старом чате UI предлагает явное включение этого режима. Это ограничение означает, что upgrade не спасёт старый pinned чат молча.

Выбор reviewer по author session из #1479 остаётся отдельным входом будущей интеграции: explicit author provider/model должен трактоваться как pin. Возможное использование reserve при author preference относится к будущему объёму после согласования двух спецификаций; автоматический spec reviewer исключён из fallback v1.

## 4. Eligible surfaces и безопасный retry

Router принимает purpose, preferred/model mode, capabilities, retry class, общий deadline, budget hook, config revision и operation ID. Нельзя определять безопасность только по тому, что object реализует `Generator`.

| Surface / профиль v1 | Разрешение и ограничение |
|---|---|
| `batch_text` | Изолированные no-tools `Generate` во всех общих factories: разрешён quota fallback одного вычисления до сохранения результата. Parser/domain validation сохраняются. Вызов обязан отключать owner MCP, hooks, shell/apps/web и прочие неразрешённые tools у обоих CLI |
| `image` | Только ImageGenerator с явным input и одинаковой поддержкой альтернативы; wrapper обязан прокидывать policy и capability. Ни PDF chat, ни текстовая потеря image не считаются эквивалентом |
| `review_readonly` | Read-folder code queries: только read-only sandbox, запрет MCP/network writes, общий deadline. No-tools diff overview относится к batch_text. Автоматический spec-review исключён из fallback v1 до согласования #1479 и supervisor boundary |
| `chat_tools`, embedded chat, automation `agent()` | Только preflight выбор reserve, если shared health уже подтверждает quota preferred и режим не pinned. После запуска child/agent loop автоматического повтора этого turn нет, даже если UI ещё не получил текст |
| Automation `llm()` | Изолированное вычисление; до двух attempts в одном SDK step, каждая через общий budget. Нет retry recipe. Ошибка обеих попыток возвращается в существующий SDK error flow |
| Workbench terminal, Stop/ask-guard hooks | Вне fallback v1, включая AI-классификатор stop hook: сохраняется нынешний bounded fail-open сценарий, никаких дополнительных ожиданий |
| Tool-bearing CLI query/REPL/Jira analyzer | Только preflight при подтверждённом health, если route не pinned. После старта нет replay; нельзя считать QuerySync чистой функцией |

Для `batch_text`/`image` первая quota ошибка открывает cooldown и допускает одну попытку reserve в остатке deadline. Для tool-bearing turn первая quota ошибка только регистрирует health и завершает ход с сохранённым состоянием; следующая новая безопасная операция сможет стартовать reserve. Это сознательный предел v1: первый такой запрос после достижения лимита может не завершиться автоматически.

Для запрещённого preferred policy error конечный: не пытаться reserve. Перед каждой попыткой проверить актуальную policy альтернативы и доступность требуемых capabilities/tools; организационный запрет никогда не становится quota. CLI/env, approval gates, surface/turn bindings и внешние tool allowlists остаются прежними. Если нужный claude.ai tool, attachment либо разрешённая Quick Connection недоступны на reserve — оставить запрос, назвать причину, не делать вид, что задача выполнена.

**Reason codes:** `quota_exhausted`, `both_quota_exhausted`, `quota_wait`, `recovery_probe_busy`, `fallback_disabled`, `explicit_pin`, `turn_already_started`, `required_capability_missing`, `policy_denied`, `auth_required`, `model_unavailable`, `transport_error`, `invalid_output`, `cancelled`, `budget_exhausted`, `config_apply_failed`, `surface_not_supported`. UI использует код, а не анализ stderr. User-visible детали редактируются и не содержат credentials/весь prompt.

## 5. Quota state и возврат

Fallback запускается только для provider-specific подтверждённого исчерпания usage/subscription quota. HTTP 429 сам по себе недостаточен: краткий rate limit, overload и сеть остаются существующими bounded errors. Structured status/type/reset предпочтительнее; string match разрешён только по узкому fixture-подтверждённому словарю. Неизвестная ошибка не переключает provider. Auth/model/policy/output failures не открывают quota circuit.

Состояния provider quota scope: `available → quota_wait → probe_leased → available | quota_wait`. Scope — provider + непрозрачный account/auth identity + bucket/model при явном ограничении модели; отсутствие надёжного account ID означает локальный installation scope этого provider, не заимствование идентификатора другой системы. Состояние общее для daemon и chat, переживает restart; автоматический spec reviewer его не использует в v1. Смена аккаунта создаёт новый scope; в health store не лежат токены. Процент плана или NearLimit не открывает circuit и не блокирует работу.

- При известном reset раньше него автоматических probes нет. После reset следующий подходящий pending no-tools запрос захватывает CAS lease с deadline вызова + 15 секунд. Только один probe на scope, lease освобождается при завершении или истекает после аварии.
- Если reset неизвестен: первый eligible probe через 5 минут, затем 15, 30, максимум 60 минут после повторных quota failures. Интерактивный «Check again» может инициировать проверку не чаще раза в минуту на scope и не обходит policy/budget. Он использует ожидающий безопасный запрос; без него выполняет только metadata refresh, без «reply ok» inference.
- Пока probe идёт, другие eligible операции используют reserve; если reserve тоже quota-wait — сразу получают deferred/unavailable, не занимают worker slot ожиданием reset.
- Успех preferred probe возвращает новые фоновые операции к preferred. Уже запущенную reserve попытку не отменять. Повторная quota ставит новое reset/cooldown. Иная ошибка probe сохраняет диагностическую ошибку и задерживает следующий probe, не объявляет provider здоровым и не меняет её на quota.
- **Текущий chat остаётся на reserve после восстановления preferred.** Показать «Preferred is available again» с действием Use preferred между ходами; новые automatic chats используют preferred. Это D2, одобрено в ask #937 (recovery). In-flight turn никогда не меняет provider.
- Sticky chat, чей actual reserve позже исчерпан, может перед новым ходом выбрать восстановленный configured preferred, если auto-mode и capabilities это разрешают. Sticky — защита от gratuitous switch, а не запрет безопасного восстановления. Весь turn всё равно имеет один actual backend.

**Главный UX tradeoff v1:** если лимит впервые проявился внутри tool-bearing chat turn, этот turn завершится ошибкой; автоматическое продолжение начатого хода не обещано. Только последующий новый ход сможет заранее выбрать reserve. Даже отсутствие видимых действий не разрешает скрытый повтор. Это должно быть отдельно принято владельцем, а не спрятано в технических ограничениях.

Одна операция — максимум preferred + reserve, без ping-pong. Параллельность существующего worker pool не увеличивается из-за fallback. После восстановления очередь не запускается целиком: обычный scheduler/concurrency limit, интерактивные запросы не стоят за backlog. Новые calls не увеличивают total deadline, cancellation прекращает обе возможности.

## 6. Оба исчерпаны: что именно сохраняется

**Новой durable queue всех AI jobs нет.** Сохраняются источники, existing rows и семантика конкретного владельца работы.

Гарантированный deferred retry v1 — только scheduled шаги Slack digest batch/period, people batch, ideas email/Jira extraction и history-backfill AI chunk. Перед их budget/attempt claim scheduler проверяет health; `quota_wait` оставляет due/cursor как есть. Если фактический вызов обнаружил quota, возвращается typed provider-deferred, success stamp и input cursor не продвигаются; provider failure не считается poison/invalid-material strike. Физическая попытка при этом учитывается в usage. Следующий штатный запуск повторяет только несохранённый AI-шаг с теми же входными границами, не уже сохранённые outputs. Каждая из перечисленных pipeline integrations требует теста quota-before-call и quota-after-call на сохранность cursor/due; если адаптер не обеспечивает это, surface не объявляется deferred-capable.

Остальные scheduled pipelines v1 получают тот же typed unavailable и сохраняют существующую failure/retry cadence; документ **не обещает их немедленного автоматического возобновления**. UI не показывает «все задачи возобновятся». Разовая CLI-команда завершается с понятной ошибкой; команда сама по себе в очередь не ставится. Chat message/partial answer и action receipts сохраняются, пользователь видит, что ход не завершён.

Custom automation recipe не перезапускается и не становится новым `waiting`-типом. `llm()` при обеих исчерпанных системах завершает один SDK step ошибкой, которую рецепт обрабатывает по нынешним правилам; если run завершился, следующий cron — новый run, а не скрытый replay старого. `agent()` после старта не повторяется; созданные proposals/receipts остаются. `shell`, `mcp`, `output`, `session` никогда не повторяются из-за нового router. Built-in recipe получает гарантии только своего явно перечисленного primitive, не всего рецепта.

Spec-review ask не прячется до reset: обе системы недоступны → reviewer fails/skips с причиной, существующий author loop раскрывает ask владельцу. Запустить review позже можно существующим действием, без удержания ask. Нельзя тратить три relaunch attempts как quota polling.

## 7. Эффекты и целостность чата

В v1 нет гарантии межпровайдерного exactly-once внешних записей. Отсутствие UI tool_start не является доказательством отсутствия действий. Консервативная граница — запуск tool-bearing child/loop, поэтому автоматический retry такого turn после запуска запрещён.

Ошибка quota после начала turn сохраняет partial output, action IDs/status/results и показывает Review actions. Это открывает существующие действия, не отправляет новый prompt. Пользователь после проверки может выбрать другой provider и отправить **новое сообщение**; pending proposals не дублируются и не исполняются автоматически. Не предлагать blind Retry whole turn. Автоматический handoff не сериализует Claude session ID как Codex thread ID.

Новый backend между ходами использует Watchtower replay, вместе с action-summary context прежнего завершённого/partial turn. Current-turn exclusion существующего ReplayFromDB сохраняется. Для failed turn action summaries должны быть доступны в следующем новом turn независимо от видимых token events. Изменение провайдера не отменяет approvals и не меняет trust. Capability check выполняется до запуска альтернативы.

## 8. Учёт, reviewer boundary, конфигурационные слои

Каждая реальная model attempt записывается leaf ровно один раз; router не пишет дополнительный `llm_calls` row. Ввести logical operation ID и attempt index для связи попыток, сохранить actual provider/model, cause и duration. Пропущенный из-за cooldown provider — routing decision, не фиктивный model call. При parse failure остаётся usage фактической попытки.

Automation `llm()` хранит ровно один SDK step; tokens/duration этого step суммируют attempts, каждый admission/debit проходит existing meter. Неизвестная usage не считается нулём: сохраняются действующие estimated semantics. При недостатке остатка budget/deadline вторая попытка не запускается. Повтор JSON validation и provider fallback делят общий бюджет; максимум две provider attempts на каждое разрешённое validation вычисление, существующий максимум validation retry не расширяется.

Автоматический spec-review исключён из fallback v1 (`surface_not_supported`) до #1479 и отдельного решения о supervisor boundary. Он сохраняет configured provider/модель и нынешние ошибки/раскрытие ask, не пишет shared health и не служит recovery probe. Это обоснованное ограничение ради `SPECREVIEW-01`: менять reviewer launcher/IPC в данном объёме не требуется. No-tools diff overview использует обычный host router; это другой runtime. Будущее включение spec reviewer требует host-side health writer вне `specreview.Run` без ослабления guard, но не специфицируется здесь.

Health persistence failures не разрешают bypass policy или дополнительные attempts. При недоступном health store — ограниченная текущим запросом попытка preferred и безопасный reserve после подтверждённого quota, без обещания общего cooldown; host показывает диагностическую деградацию. Не держать DB transactions на время model/IPC/network call.

## 9. Макеты и presentation model

Сцены зарегистрированы в `DesignShotCatalog` через `ProviderFallbackShotFixtures.shots`; copy/states живут в `ProviderFallbackPreview`, meaningful tests — `ProviderFallbackPreviewTests`. Это отдельная presentation proposal, не подключённая к runtime. Используются SettingsSection, kitPrimary, semantic Tone, spacing tokens; никаких разделителей строк. На узкой ширине сообщения переносятся, кнопка располагается под текстом. Контекст ограничен AI Settings либо конкретным chat; Workbench UI не меняется.

Render directory: `docs/design/mockups/provider-fallback/`. Обязательные состояния и ожидаемые stems:

| Группа | Stems `provider-fallback-…` |
|---|---|
| Подключение | `empty`, `checking`, `notInstalled`, `notVerified`, `connectionNetworkError`, `connectionError`, `ready` |
| Применение | `applying`, `applyError` |
| Лимиты | `fallback`, `bothLimited`, `probing` |
| Chat scope | `recovered`, `stopped`, `pinned`, `unsupported` |
| Policy | `policy` |
| Равноправие | `ready-codex`, `fallback-codex`, `recovered-codex` |
| Узкий экран | `bothLimited-narrow`, `stopped-narrow` |

Созданы 44 PNG: [галерея всех light/dark состояний и validation notes](../../design/mockups/provider-fallback/README.md). Проверены глазами узкие [Settings light](../../design/mockups/provider-fallback/provider-fallback-bothLimited-narrow-light.png) / [dark](../../design/mockups/provider-fallback/provider-fallback-bothLimited-narrow-dark.png) и [Chat light](../../design/mockups/provider-fallback/provider-fallback-stopped-narrow-light.png) / [dark](../../design/mockups/provider-fallback/provider-fallback-stopped-narrow-dark.png): тексты и кнопки помещаются. [Recovery с Codex preferred](../../design/mockups/provider-fallback/provider-fallback-recovered-codex-light.png) — sticky вариант, одобренный в ask #937 (recovery). Focused render использует ту же catalog scene factory без холодной сборки приложения; 8 Core semantic tests passed. Loading/busy не имеют активной повторной кнопки; connection/apply error имеют разные Retry actions. В both-limited тексте обещано сохранение исходных данных, не универсальный replay jobs.

## 10. Inventory: предполагаемые дополнения и сохраняемые гарантии

| Контракт | Что сохраняется / предлагаемое дополнение |
|---|---|
| POLICY-03 | Запрещённый preferred не вызывает reserve; tightening не переписывает настройки. Quota разрешённого provider — отдельная причина. Guard не ослаблять |
| CHAT-01 | Owner text/partial answer остаются; actual provider и reason сохраняются вместе с turn |
| CHAT-02 | Tool activity и action results видимы; no-tools classification не выводится из отсутствия UI events |
| CHAT-03 | Pool/session bounds сохраняются, один backend на активный ход; смена только между ходами, старый child закрывается |
| CHAT-04 | Prompt/history/credentials не попадают в argv и routing logs |
| AUTO-08 | Общие time/token limits не сбрасываются; каждая attempt admission/debit, никаких новых бесконечных waits |
| AUTO-11 | Один logical SDK step; attempt details и суммарный usage без второй step row; recipe не replay |
| SPECREVIEW-01 | Spec reviewer исключён из fallback v1; пишет только собственную строку, не shared health |
| SPECREVIEW-02/04 | Ask создаётся и становится видимым независимо от квот/reviewer; cooldown не продлевает author loop |
| PROJ-07/13 | Stop drift/ask guard не получают fallback latency и не trap turn |
| PROJ-20 | AI daemon reconfig не останавливает hosted terminals, не relaunch/adopt их повторно |
| LLMUSAGE-01 | Leaf exactly once per physical call; no synthetic call for cooldown; реальные расходы всех attempts видимы |
| BACKFILL-03 (retired) | Не восстанавливать прежний plan percentage gate; defer только фактическая quota, без NearLimit/projection |

Правила preferred/reserve, recovery/sticky chat, pins, безопасный первый этап и config ack одобрены в ask #937. На стадии этого документа inventory/guard tests не переписываются. После одобрения спецификации и плана сформулировать отдельные узкие routing contracts вместо ослабления перечисленных; новые изменения поведения за пределами ask #937 потребуют отдельного решения владельца.

## 11. Acceptance и зависимости

- Fake providers проверяют оба направления: quota → reserve, максимум две attempts, общий deadline, cancel до второй попытки, правильные per-provider tiers.
- Краткий 429, auth/model/policy/network/validation errors не переключают provider. Forbidden preferred не стартует ничего, forbidden reserve не вызывается.
- Два процесса видят одну quota state; после reset лишь один получает lease, авария не блокирует scope навечно. Неизвестный reset, обе квоты, смена аккаунта и restart покрыты без реальных model calls.
- Каждая гарантированная deferred pipeline сохраняет cursor/due/input и не пишет success; повтор делает только несохранённое вычисление. Неeligible pipelines не рекламируются как queued.
- Существующие recipes не replay; llm attempts укладываются в один step и meter; quota после tool dispatch не повторяет receipt/action.
- Preferences migration не включает fallback, не переносит Claude model в Codex, не теряет оба buckets; старые chats pinned. New automatic chat и явные pins имеют разные тесты.
- Save ack действительно меняет следующий AI job; apply failure виден; hosted terminal session ID/process сохраняется.
- Reviewer с quota сохраняет прежние ограничения таблиц и раскрытие ask; отсутствие fallback явно обозначено, никаких новых health writes.
- Presentation tests проверяют симметрию названий/actual provider, sticky recovery, busy suppression, разные Retry, честные ожидания и pins; catalog содержит состояния и narrow light/dark shots.

**#1470:** переиспользовать quota metadata/account scope DTO; проценты не управляют fallback. **#1479:** согласовать reviewer preference/pin semantics и использовать исправленный lifetime Codex instructions; не дублировать эту работу. Не переносить chat runtime на app-server в данном объёме.

Поведение D1–D7 одобрено в ask #937; конкретные cooldown durations и техническая детализация проходят review этого документа. Fallback ещё не реализован; макеты и presentation tests не доказывают работу routing.
