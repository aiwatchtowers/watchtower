# Резерв Claude ↔ Codex — план реализации

**Spec:** [2026-11-02-provider-fallback-design.md](../specs/2026-11-02-provider-fallback-design.md).
**Target:** #1480. **Статус:** одобрен без замечаний в ask #940; выполняется последовательно.
**Решения:** ask #937; спецификация одобрена без замечаний в ask #939; план одобрен в ask #940.
**Доска:** подготовка/review — #1482; Tasks 1–12 — #1483–#1494 соответственно, под группой #1480.

## Decisions и границы

- **Владелец, asks #927/#930/#937/#939:** равноправные preferred/reserve, opt-in, quota-only, sticky текущий чат, старые чаты pinned, безопасный первый этап. Workbench terminals, spec reviewer и replay произвольных recipes вне объёма.
- **Решил агент:** 12 последовательных задач в трёх фазах. Каждая — отдельный агент в отдельном worktree, независимое review и PR в main. Следующая задача ответвляется от main после merge зависимостей. Параллельных implementation lanes в этом плане нет.
- **Решил агент:** shared quota health — installation-level приватный файл с межпроцессным lock, не таблица отдельного workspace. Chat routing metadata хранится в существующей workspace DB через goose. Файл health не содержит текстов, credentials или raw account IDs.
- **Решил агент:** тестовые CLI и фиктивные часы; реальные inference/login/config installed app не используются при разработке и проверках.

План не расширяет согласованное поведение. Если реализация требует изменить контракт или ослабить guard, остановить соответствующую задачу и подать отдельный decision ask до такого изменения. Наличие новых полей не даёт права менять смысл существующих настроек.

## Исполнение и общий checklist

Перед задачей: прочитать её inventory, feature notes и owner comments, поставить leaf `in_progress`; передать комментарии дословно агенту. Каждая задача включает implementer self-review и независимое review по тому же checklist. `in_review` — начало agent review; возврат замечаний — `in_progress`. `done` только после успешного review и merge PR; комментарий с итогом и commit. Обновить branch/PR на соответствующей карточке. В списках Swift-файлов сокращённые `Sources/` и `Tests/` относятся к `WatchtowerDesktop/`; предлагаемые новые файлы/пакеты помечены как новые.

Общий checklist для всех задач:

1. Fallback off сохраняет прежний выбор провайдера и поведение ошибок. Наличие Codex/health другой операции само по себе резерв не включает. Направления проверяются зеркально.
2. Policy denial, cancel, auth, model error, transport error, invalid output и краткий 429 не превращаются в quota. Не расширяются tools, trust, surface или sandbox.
3. Нет повторного исполнения начатого tool-turn/recipe, потери owner text, partial output, pending proposals или checkpoint. Ни routing, ни Save не управляют hosted Workbench session.
4. Deadline и concurrency не умножаются на число attempts. Leaf ledger — ровно одна запись на реальный model call. Бюджет автоматизации общий для attempts.
5. Проверки — task scope, без полной сборки на каждой правке. Сначала focused failing test, затем реализация и focused regression. Никаких weakened guards, новых lint suppressions, live fixtures или локальных личных путей в репозитории.

После каждой фазы controller запускает полный gate один раз: `make test`, `make test-swift`, `make lint-all`. Такой же gate перед финальным интеграционным PR, если с предыдущего gate менялся код. Для отдельных task PR достаточно scoped checks ниже и gate соответствующей фазы; соблюдать дополнительные обязательные CI проверки репозитория. Все spawned fake subprocesses очищают process group в cleanup; временные git repositories используют `gittest.DisableBackgroundGit()`.

## Фаза A — конфигурация и безопасное ядро

### Task 1. Per-provider config и атомарная legacy migration

**Depends on:** none.
**Файлы:** `internal/config/config.go`, `internal/config/config_test.go`, `internal/providers/registry.go`, `internal/providers/registry_test.go`, `cmd/config.go`, `cmd/config_test.go`; новый `internal/config/provider_fallback.go`.

- Добавить validated preferred/reserve и отдельные model buckets по схеме spec §2. Default reserve off; Ollama без включённого резерва работает как прежде; неизвестный provider не преобразуется в Claude.
- Реализовать общую нормализацию для CLI и Desktop writer: legacy переносится только в bucket исходного configured provider; существующий bucket выигрывает, explicit empty bucket означает Default. Не размножать `opus` в Codex. Новые чтения не меняют config на диске.
- Атомарная запись сохраняет неизвестные/посторонние настройки и legacy поля; migration не меняет preferred и не включает reserve. CLI validation/policy выполняется до записи.
- Ввести нормализованный config revision для routing-relevant полей; ack protocol будет в Task 10. Config write не утверждает, что daemon применил revision.

**Проверки:** `go test ./internal/config ./internal/providers`; targeted config tests в `./cmd`. Cases: old Claude/Codex/Ollama config, отсутствующий/пустой bucket, конфликт new/legacy, неверная пара, отключённый резерв, отказ записи оставляет старый файл целым. Проверить POLICY-03.
**Review/acceptance:** один authoritative resolver; migration повторяемая, без смены выбора/данных; documented downgrade caveat совпадает со spec.

### Task 2. CLI isolation и typed quota/capability errors

**Depends on:** Task 1.
**Файлы:** `internal/digest/generator.go`, `internal/digest/timeout_generator.go`, `internal/codex/generator.go`, `internal/ai/client.go`, `internal/codex/client.go`, `internal/chat/claude_translate.go`; новые typed error/profile definitions в `internal/providers/` и профильные tests.

- Ввести structured error category/reset/scope hints, отличая подтверждённое исчерпание квоты от краткого rate limit и остальных отказов. Нормализовать CLI envelopes до human-message fallback; строковый словарь ограничить fixtures.
- Выделить явные invocation profiles `batch_text`, `image`, `review_readonly`, `tool_preflight`. Для no-tools batch запретить наследование owner MCP/hooks/shell/apps/web в обоих CLI; не отключать нужные tools обычного agent runtime.
- Прокинуть typed cause через timeout/error wrappers без утраты `errors.Is/As`, сохранив существующую обработку pipeline ошибок. Подтвердить capability выбранного leaf, не делать текстовую подмену image/PDF.
- Не менять жизненный цикл Codex instructions file, если это работа #1479; интегрировать её исправление при наличии merge, не восстанавливать старый баг.

**Проверки:** scoped `go test ./internal/digest ./internal/codex ./internal/ai ./internal/chat ./internal/providers`; fake argv/env/config capture для profiles. Quota/reset, unknown phrase, short 429, cancelled, timeout, auth/model/policy и malformed JSON различаются. Fake tool inheritance действительно отсутствует, контент не попадает на argv.
**Review/acceptance:** классификация не зависит от отсутствия UI text/tool events; CHAT-04 и FILES-01 сохраняются; CLI mismatch не маскируется quota.

### Task 3. Shared installation health и recovery leases

**Depends on:** Task 2.
**Файлы:** новый пакет `internal/providerhealth/`; `internal/config/config.go` (`AppSupportDir`), существующие `internal/fsutil/lock.go` и `internal/fsutil/atomic.go` как переиспользуемые seams.

- Хранить versioned health под installation Application Support в приватной директории, state file 0600. Применять `fsutil.LockFile` к стабильному lock path и atomic replace к data path. Не удалять lock inode, не держать lock при CLI/network/inference.
- Scope: provider + opaque auth/account identity, при доказанном model/bucket limit добавить bucket. Если identity недоступна, использовать installation scope этого provider. Не сохранять credentials или их raw значения; аккаунт после смены не наследует quota другого.
- Реализовать `available/quota_wait/probe_leased`, deadlines/lease ownership, CAS claim/release и expiry после crash. Два процесса и два workspace используют один и тот же store.
- Применить reset и интервалы из spec §5: неизвестный reset 5/15/30/60 мин, manual check не чаще минуты. Probe — один ожидающий safe request, не платный synthetic ping. Health failure даёт диагностическую деградацию и bounded per-call поведение из spec.

**Проверки:** `go test ./internal/providerhealth ./internal/fsutil`; fake clock; отдельные helper processes конкурируют за одну lease, завершение процесса освобождает flock, expired lease не блокирует работу. Corrupt file, permission error, смена identity, known/unknown reset, обе quota и cancellation проверены. Все helper процессы reap.
**Review/acceptance:** store действительно общий между workspace; metadata не содержит prompts/tokens/личных account IDs; read/write locks короткие; PLANUSAGE-01/02 не затронуты.

### Task 4. Bounded router, safe factories и leaf accounting

**Depends on:** Tasks 1–3.
**Файлы:** новый пакет `internal/providerrouting/`; `cmd/generator.go`, `cmd/provider_policy.go`, `internal/digest/pooled.go`, `internal/digest/image.go`, `internal/llmusage/`, `internal/daemon/coach.go` и call sites factories из research.

- Ввести route request с preferred/mode/tier, required capabilities, retry class, operation ID, config revision, общим deadline/cancel и attempt hook. Policy проверяется перед каждой попыткой, forbidden preferred даёт конечный отказ.
- Для eligible isolated call выполнить максимум preferred + reserve; для tool-bearing surface пока только route selection до child start. Circuit/quota wait не создаёт фиктивный model call. Reuse existing pool limits; слот занят ровно исполняющимся запросом, reset не ждут в слоте.
- Общие factories и отдельный coach используют один router, но automation activation и chat activation откладываются до Tasks 7/8. Spec reviewer и Stop/ask guards используют прежний bounded путь без fallback.
- Сохранить optional image capability через policy/timeout/pool wrappers, не обходя policy. Actual provider/model и attempt linkage связываются с leaf records; wrapper не пишет второй usage row. При необходимости изменения БД — goose, schema.sql и generated Swift schema по repository skill.
- Fallback off должен проходить legacy path без новых cooldown gates. Проверить explicit `--provider/--model` и capabilities отказ до альтернативы.

**Проверки:** `go test ./internal/providerrouting ./internal/providerhealth ./internal/providers ./internal/digest ./internal/llmusage`; targeted `./cmd` factory/policy tests и `./internal/daemon` coach tests. Матрица обоих направлений, total deadline, cancel между attempts, reserve forbidden, image mismatch, ledger exactly-once, unchanged off/pinned behavior.
**Review/acceptance:** POLICY-03/LLMUSAGE-01 сохраняются; неeligible factories не получают автоматический replay. **Gate A:** controller full gate перед интеграцией фазы.

## Фаза B — фон, автоматизации и Go chat

### Task 5. Deferred Slack digests и people batches

**Depends on:** Task 4.
**Файлы:** `internal/digest/pipeline.go`, `internal/digest/backfill.go`, `internal/guide/pipeline.go` (people cards), `internal/daemon/daemon.go`, `internal/daemon/daemon_people_backoff_test.go`; существующие pipeline/outcome tests.

- Перед попыткой проверять typed deferred outcome; quota wait не расходует success/poison markers и не продвигает input cursor/due. Если quota обнаружилась внутри call, сохранить уже committed результаты, не помечая несохранённый шаг успешным.
- People использует persistent daily attempt marker (`peopleAttemptsPath`), поэтому отдельно обработать quota-before-call и quota-after-call: provider failure не превращается в исчерпание data-processing attempt budget. Учитывать физический вызов в ledger независимо от deferred результата.
- При следующем штатном schedule обрабатывать только несохранённые границы/пользователей; не сбрасывать дневные данные и не вводить очередь всех jobs. Неeligible phases сохраняют нынешнюю cadence.

**Проверки:** `go test ./internal/digest ./internal/guide`; targeted daemon people/digest/backoff tests. Сравнить реальные DB markers/stamps и persistent attempt file до/после отказа; смешанный batch success+quota не повторяет committed output. Обычная неquota ошибка сохраняет прежние guards.
**Review/acceptance:** три состояния success/no-data/provider-deferred различаются; нет ложного completed outcome, бесконечного пересканирования committed output или продвижения cursor при quota.

### Task 6. Deferred ideas extraction и history chunks

**Depends on:** Task 5.
**Файлы:** `internal/ideas/pipeline.go`, `internal/ideas/backfill.go`, `internal/ideas/backfill_account.go`, `internal/historybackfill/runner.go`, `internal/historybackfill/chunk.go`, `internal/daemon/history_backfill.go` и их tests.

- Протянуть typed provider-deferred через email/Jira extraction и backfill AI chunk: не считать это invalid material/poison strike и не двигать cursor за необработанный вход. Не вызывать обычный history `fail()` с увеличением strikes на quota.
- Сохранить разделение forward marks и backfill window, существующие account scopes и first-sync условия. Источники продолжают синхронизацию независимо от AI health.
- Не возвращать прежний percentage/NearLimit gate: решение только по фактической quota. Существующие builtin recipes получают гарантию своего primitive, не replay всего recipe.

**Проверки:** `go test ./internal/ideas ./internal/historybackfill`; targeted `./internal/daemon` history tests. Email/Jira и chunk quota до/после model call; restart/cooldown/recovery; committed results не дублируются. BACKFILL-01/02 и `TestRunner_NoPlanGate` остаются зелёными.
**Review/acceptance:** гарантированная deferred allowlist ровно соответствует spec §6; остальные pipelines не рекламируются как durable queued.

### Task 7. Automation attempt meter и preflight agent routing

**Depends on:** Task 6.
**Файлы:** `internal/automations/sdk_llm.go`, `internal/automations/meter.go`, `internal/automations/backends.go`, `internal/automations/sdk_agent.go`, `cmd/automations_backends.go`, `cmd/automations_run.go` и focused tests.

- Передать attempt admission/debit hook в router так, чтобы каждая физическая attempt проверяла общий остаток tokens/time. SDK `llm()` остаётся одним step; суммируются attempts, а existing schema retry не получает дополнительный общий бюджет.
- Явно закрыть расхождение текущего `generateMetered` с согласованным spec §8: сейчас failed attempt учитывает только reported usage, а successful unknown оценивается. Для reserve нельзя считать failed unknown бесплатной: использовать reported usage, если она есть; иначе оценку доступного фактически отправленного input/полученного partial output по действующим правилам оценки, пометить estimated и неизвестный остаток. До второй attempt meter должен учесть первую; если данных недостаточно для безопасного admission, вторую не запускать. Это выполнение одобренного требования «неизвестная usage не считается нулём», а не утверждение о фактическом биллинге провайдера. Точную границу observed usage/estimate проверить на review и покрыть guards, не ослабляя AUTO-08.
- Для `agent()` выбрать альтернативу только до запуска loop по shared known quota. После запуска ни внутренняя loop, ни весь SDK step/recipe не повторяются. Manifest, budget carve-out, isolated CODEX_HOME и proposal-only semantics прежние.
- Обе quota дают существующий SDK error flow; новый waiting type/автоматический replay recipes не добавлять. `shell/mcp/output/session/ask` не повторяются.

**Проверки:** `go test ./internal/automations`; targeted `./cmd` automation backend tests. Две attempts = один dense SDK step, верный суммарный usage, unknown success/failed usage, schema retry + reserve, бюджет перед второй attempt, cancel. Quota после proposal не делает второй agent run.
**Review/acceptance:** AUTO-08/11, AGENT-01/03/05/07 и replay guards не ослабляются; recipe approval hash и grants не переписываются.

### Task 8. Go chat/tool preflight, pins и failed-turn receipts

**Depends on:** Task 7.
**Файлы:** `internal/chat/turn_backend.go`, `internal/chat/replay.go`, `internal/chat/claude_backend.go`, `cmd/ai_session.go`, `cmd/generator.go`, `internal/db/chat.go`; новые chat routing migration/models и protocol fixtures по необходимости.

- Хранить routing mode отдельно от configured preferred и actual attempt provider/model. Existing conversations migrate pinned; новые могут inherit auto/reserve. Explicit model/CLI provider остаются pin. Goose номер выделяется при реализации от актуального main, не фиксируется в плане.
- До запуска tool-bearing child выбрать reserve при известной quota и совместимых capabilities. После запуска — никакого автоматического retry этого turn. Первый обнаруживший quota turn может завершиться ошибкой: сохранить user message, partial answer и tool/action receipts.
- При новом turn replay включает summary предыдущих actions/results и незавершённых proposals. Не передавать session/thread ID одного provider другому; не сбрасывать streamed text. Смена backend только между turns с корректным Close/reap.
- Прокинуть actual/reason/routing mode через protocol v2 с fixtures и обратимой обработкой неизвестных полей. Embedded/tool clients и CLI query получают только допустимый preflight profile; spec reviewer/Stop hooks исключены.

**Проверки:** `go test ./internal/chat ./internal/db` и targeted `./cmd` session/query tests; миграция old chats, pin/auto, replay partial failure+proposal, quota до/после spawn, capability rejection, cleanup stubborn child, cancellation. При schema change — golden/generated schemas по add-migration skill.
**Review/acceptance:** CHAT-01..04 и AGENT-05 не меняют смысл; spec-review writes-only-own-row guard остаётся прежним. **Gate B:** controller full gate.

## Фаза C — Desktop, применение конфигурации и выпуск

### Task 9. Desktop chat automatic/sticky/actual states

**Depends on:** Task 8.
**Файлы:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, `Sources/WatchtowerCore/Models/ChatConversation.swift`, `Models/ChatModels.swift`, `Database/Queries/ChatConversationQueries.swift`, `Sources/Services/Chat/`, `Sources/Views/Chat/`, `Sources/Services/EmbeddedChatWiring.swift` (пути внутри `WatchtowerDesktop/`); existing Chat tests.

- Добавить Preferred + reserve / Only provider и Auto model без молчаливого снятия old pins. Отделить предпочтение от actual для turn и sticky conversation; не показывать preferred как фактического исполнителя reserve ответа.
- После recovery новые automatic chats используют preferred, старый переключённый чат остаётся на reserve; явный Use preferred между ходами меняет actual. Если sticky actual исчерпан, применять согласованное safe preflight правило spec §5, не слепой replay.
- Ошибка начатого turn показывает сохранённый partial и Review actions; эта кнопка открывает actions, не отправляет prompt. Unsupported capability объясняет сохранённый запрос. Embedded queues/drafts и warm session limits сохраняются.
- User-facing copy берётся из модели, tests проверяют статус и действия для обеих сторон. Reuse утверждённых catalog fixtures; не заводить независимый набор mockup strings.

**Проверки:** `make test-swift FILTER='ChatViewModelTests|ChatTurnDriverTests|ChatSessionPolicyTests|ProviderFallbackPreviewTests'` плюс фактически затронутые query/embedded test classes. DB-write-before-send, partial persistence, explicit pin, sticky/manual recovery, busy pool и wrong actual provider regression.
**Review/acceptance:** сверка chat narrow/light/dark shots со spec; no duplicated proposals, никаких прямых config changes от temporary fallback.

### Task 10. Config revision apply/daemon ack без hosted terminal restart

**Depends on:** Task 9.
**Файлы:** `cmd/sync.go`, `internal/daemon/daemon.go`, `WatchtowerDesktop/Sources/Services/ConfigService.swift`, `Sources/WatchtowerCore/Services/DaemonManager.swift`, `DaemonStartQueue.swift`, `DaemonRestartPolicy.swift`, `Sources/App/AppState+DaemonStart.swift`, `Sources/Views/Settings/ConfigSaveBar.swift` и targeted tests.

- Пересоздавать routing factories/clients на безопасной границе текущего job; ack содержит фактически применённую revision. Не ограничиваться `lastSaveChangedPurge`. Обновление сохранённого config и его применение имеют разные результаты.
- Выбрать hot reload AI dependencies между jobs как основной механизм. Если существующая архитектура требует controlled daemon restart, controller обязан доказать preservation checkpoints и текущих automation semantics; не считать произвольный restart эквивалентным safe reload. Не закрывать app chats/PTY/session-host ради Apply.
- Новые embedded clients читают новую revision, active turns заканчиваются на своей. Apply Retry повторяет применение актуально сохранённой revision, не затирает более новое сохранение; delayed old ack игнорируется.
- Потеря daemon/ack показывает сохранённые и фактические настройки раздельно. Fallback usage/recovery не записывает preferred/config revision.

**Проверки:** targeted `./cmd` sync config tests, `./internal/daemon` lifecycle tests; `make test-swift FILTER='ConfigServiceTests|DaemonStartQueueTests|ProviderFallbackPreviewTests'` с уточнением фактических class names. Fake long job завершается, следующий job использует new actual provider; apply failure/retry/stale ack/concurrent Save; hosted terminal PID/run ID неизменны.
**Review/acceptance:** PROJ-20 и CHAT-03 не ослаблены; не запускается второй daemon; no success UI до actual ack.

### Task 11. Settings reserve connection и actual apply UI

**Depends on:** Task 10.
**Файлы:** `WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift`, `Sources/Services/ConfigService.swift`, `Sources/WatchtowerCore/Services/ProviderFallbackPreview.swift` (переиспользовать/переименовать в production presentation model), новые provider connection/presentation files; `Tests/Core/ProviderFallbackPreviewTests.swift`, `Tests/DesignShots/DesignShotFixtures+ProviderFallback.swift`, `DesignShotCatalog.swift`.

- Подключить реальные preferred/reserve, per-provider модели, enable switch (initially off), CLI path и connection status. Переключение provider не уничтожает другой bucket. Existing Ollama и прочие Settings controls сохраняются.
- Connection check отделяет CLI missing, sign-in missing, unknown metadata и transport error без inference. Test connection — явное пользовательское действие с предупреждением из согласованной copy. Не реализовывать отдельный OAuth token refresh/login manager.
- Apply/failed apply, quota/cooldown/recovery и both-limited состояния получают реальные DTO, timestamps и reason codes. Check again соблюдает lease/rate limit и не создаёт платный synthetic ping.
- Цвета Tone, kit controls, no row separators; loading/busy indeterminate; Retry привязан к конкретной операции. Все тексты в модели с tests. Сверить каждую из 22 утверждённых scene variants; никакие fixture 14:30 или Default model literals не остаются в live state.

**Проверки:** focused Swift presentation/config/connection tests с fake CLI/metadata; `make desktop-shots DESKTOP_SHOTS=build/provider-fallback-after` и визуальная сверка light/dark, narrow settings/chat, reverse direction с approved gallery. Проверить installed-but-not-authorized, both exhausted, policy denial и apply failure.
**Review/acceptance:** screenshots не противоречат spec; UI не обещает universal queue/replay или одинаковые capabilities двух providers; нет расхода модели при открытии настроек.

### Task 12. Integration, contract regression, rollback и spec↔shots gate

**Depends on:** Tasks 1–11.
**Файлы:** integration fixtures/tests в затронутых пакетах, `docs/features/` (новая feature note), `docs/guide/` по WRITING.md, `docs/inventory/` только новые узкие гарантии/ссылки без ослабления прежних, `CLAUDE.md` feature index.

- Прогнать оба направления end-to-end fake CLI: confirmed quota → safe reserve, both exhausted → deferred eligible step, reset → ровно одна probe, возврат фона и sticky chat, crash/restart, two workspace processes, concurrent Save. No-tools profiles не наследуют owner tools.
- Сопоставить main после merge #1470/#1479: reuse фактически существующих quota/account DTO без второго poller. Reactive routing не зависит от процентов/Usage UI. Reviewer остаётся excluded; не cherry-pick незавершённую чужую работу и не переписывать её code.
- Отдельные compatibility сценарии: no fallback config, fallback off, old pinned chats, Ollama, CLI explicit provider/model, MDM deny, code questions, custom recipes, media, stopped turn with pending action. Все прежние inventory guards сохраняются.
- Rollback feature: выключить reserve — будущие операции идут прежним способом без удаления data/chat/config buckets; активный turn завершается. Downgrade binary описать как ограниченный: old reader не понимает новые поля, миграции нельзя произвольно откатывать на живой DB. Никакого Reset LLM Data или удаления credentials.
- Controller full gate: `make test`, `make test-swift`, `make lint-all`; bounded targeted race для health/router; leak-check по реальному diff. Финальное независимое cross-task review и comparison actual screenshots ↔ approved mockups. Исправления проходят соответствующие scoped tests; новый gate только если новые изменения/риски его требуют.
- Обновить feature/guide и узкие routing contracts вместе с implementation; сохраняемые POLICY/CHAT/AUTO/AGENT/PROJ/SPECREVIEW/LLMUSAGE/BACKFILL guards не ослаблять. Annotate final diff, PR main, CI, merge, board done и cleanup/finish по workbench skill.

**Acceptance:** все D1–D7 покрыты, ниже нет пропущенной строки; release feature остаётся opt-in. Финальный handover честно сообщает known v1 exclusions и отсутствие paid/live acceptance, если такая проверка не выполнялась.

## Трассировка и gates

| Требование spec | Задачи |
|---|---|
| D1 symmetric opt-in, quota-only, bounded attempts | 1–4, 7, 12 |
| D2 shared cooldown/probe, background recovery, sticky chat | 3–6, 8–9, 11–12 |
| D3 per-provider models, explicit pins, old chat migration | 1, 8–9, 11–12 |
| D4 preflight-only tool turns, no recipe/side-effect replay | 2, 4, 7–9, 12 |
| D5 four named deferred source profiles | 5–6, 12 |
| D6 attempts in budget/leaf ledger, actual config apply | 4, 7, 10–12 |
| D7 states/copy/tests/Tone/catalog comparison | 9, 11–12 |
| Policy/credentials/Workbench preservation | Каждая задача + gates A/B/C |

Gate A после Task 4, Gate B после Task 8, Gate C в Task 12. Ни одна фаза не объявляется завершённой по одним mockups. Полные tests/gates здесь перечислены как будущая проверка реализации: в ходе написания этого плана runtime не менялся и эти команды не выполнялись.
