# Plans и Codex — реализация

**Spec:** docs/superpowers/specs/2026-11-01-plans-codex-design.md

Задача #1470. Дизайн: ask #919 approved. Identity/freshness/CLI/locking approved ask #923; Plans+menu scope approved ask #925, notifications Claude-only. Спецификация утверждена в ask #934. План декомпозирует этот согласованный объём; техническое ревью плана выполняется отдельно.

## Task 1. Прочитать квоты Codex через app-server

Depends on: none.

Добавить узкий reader внутри `internal/codex`, переиспользовать transport без расширения интерфейса hook trust. Нормализовать optional buckets/windows, duration, usedPercent, accountId scope, ordinaryUsageAllowed. Не читать auth.json. Разрешён только transcript initialize → initialized → account/read с refreshToken:false → account/rateLimits/read с excludeResetCreditDetails:true. В initialize нет experimentalApi/experiment capabilities; supportsLunaReserve не включается. Никаких дополнительных RPC, model/thread/turn, login/logout/refresh/reset-credit методов. Безопасные типизированные ошибки; таймаут/cancel/cleanup процесса.

Проверка: fake app-server записывает полный исходящий transcript; assertions точного allowlist/порядка RPC, refreshToken:false, excludeResetCreditDetails:true, отсутствия experiment capabilities/supportsLunaReserve и любых незаявленных RPC. Затем сценарии legacy и multi-bucket, переставленные/отсутствующие окна, malformed/null/unknown, API key/no auth, ID отсутствует, unsupported method, timeout/cancel, redact canaries. `go test ./internal/codex/`.

## Task 2. Хранение Codex и прогноз

Depends on: Task 1.

Новая additive Go migration для Codex status/samples с hashed scope; зеркала schema.sql, snapshots и generated Swift schema. В той же migration добавить `plot_json TEXT NOT NULL DEFAULT '{}'` в Claude/Codex status; default {} допустим до следующего poll. Codex транзакция snapshot+samples, идемпотентность, retention 8 days как existing poller. Claude сохраняет samples-before-status, plot/fetchedAt/limits публикуются одним upsert; error сохраняет good plot/fetchedAt. История обоих providers ограничена published fetchedAt и sameReset±60s. Экспортировать существующую pure projection policy узким helper, не менять Claude расчёт. Go строит typed Line от status.fetched_at/limit.percent; plot_json schema 1 и private DTO не раскрывают accountId/scope. Сброс/смена scope не используют прежнюю историю. Unknown identity может сохранять последний current status, но не записывает samples и не выдаёт старые scoped limits/history/chart/forecast. Проверить успешный ответ без ID отдельно от failed response без подтверждённой identity.

Проверка: db isolation, rollback, duplicate poll, reset filter, account switch, retention, migration Up/Down; project safe/will_hit/collecting/idle/hit. Табличные gates по порядку спецификации: 900/901s, future60/61s, reset==now/expired, missing ID/duration/reset/sample, reset±60s, invalid/negative/nonfinite rate, hit_at==now/past/reset, safe rate 0, unknown state, prediction_expired; тестировать не только тексты, но и endpoint/drawable/reason. Default {}/null/missingkey→endpoints_unavailable; malformed/schema/fetched mismatch/invalid Line→storage error. Shared Go↔Swift fixture фиксирует plot_json и обязательную projection.line. `go test ./internal/db/ ./internal/planusage/`; schema regeneration по add-migration skill, затем повтор только нужных schema checks.

## Task 3. Независимый polling и агрегированный CLI

Depends on: Task 2.

Подключить Codex poller независимо от Claude; единый feature gate, раздельный backoff. Расписание каждого poller: первая попытка через 10 секунд, после успеха период 5 минут; последовательные transient failures дают задержки 5 → 10 → 20 → 30 минут, далее cap30; успех сбрасывает failure count. Занятый фоновой lock не увеличивает failure count и не пишет status; следующий обычный tick через 5 минут. Добавить `usage plans` aggregate/read/refresh/provider filtering, сохранив старый `usage plan` и его JSON. Строгое v1 envelope из спеки с обязательным полем projection.line:Line|null и drawable⇔line!=null; текущие временные gates маскируют stored candidate, partial failure и запрет refresh когда off. Общий per-workspace/provider stable0600 flock обязателен для daemon, нового CLI, legacy usage plan --now и MarkDisabled. Под lock reread status+feature gate; network вне SQL transaction; publish до unlock. Background TryLock busy пропускает цикл; manual wait≤20s внутри deadline45s; каждый внешний CLI делает собственный fetch. --all запускает оба независимо и ждёт обоих. Обновить описание feature без смены id/config key.

Проверка: fake источники и injected clock/scheduler: до 10s нет вызовов, на 10s первая попытка, успех → ровно 5min; failures → 5/10/20/30/30min, последующий успех → 5min; busy не увеличивает failure count; сбой/таймер одного провайдера не задерживает другой. Без реальных минутных sleeps. JSON golden snapshots всех обязательных ключей/null/enum/finite numbers и выбранной сортировки; local --provider не меняет AI provider. Exit 0/1/2/3/130/143 и отдельная комбинированная таблица приоритета signal > disabled > failure > success: SIGINT/SIGTERM + refresh_requested + feature_disabled + retained-storage failure → 130/143; без сигнала disabled+failure → 3; enabled+частичный failure → 1; все successful → 0; read-only disabled+storage failure → 1, без refresh ошибочный exit3 запрещён. Failure при disabled моделировать ошибкой чтения retained status, без source fetch; invalidargs → 2 до любых calls/writes. Timeout45s через injected clock/budgets, stderr-only invalidargs, partial results без fail-fast, read-only unavailable ok=true, no-row status=null, readfailure storagenull. Параллельные subprocess daemon+два CLI на одном provider: serialize каждый fetch, busy20s без sourcewrite/backofferror, kernel release после crash, cancel unlock без errorstatus; different providers не блокируются. MarkDisabled и legacy используют тот же inode. Read-only режим и disabled --now без calls/writes/migrations/создания DB, включая отсутствующую DB или таблицу. Targeted `go test ./internal/planusage/ ./internal/daemon/ ./internal/features/`; `go test ./cmd/ -run 'UsagePlan|PlanUsage'` с дополнением названий новых тестов.

## Task 4. Swift models, queries и presentation

Depends on: Task 3.

Новые модели/queries Codex, независимые чтения и refresh app-wide center, single-flight per-provider с ожиданием одного task всеми callers; явное состояние DB read failure. Сохранить 30 s DB read, typed plot/Line queries и явное{} vsstorage error; Swift не вычисляет rate/end. Вся UI copy и display states в pure presentation model; duration/reset/projection mapping и chart data без новой оценки rate в Swift. Добавить Codex в menu/tray по ask #925: прежний togglekey/default на оба providers, имена/порядок Claude→Codex, утверждённый в ask #931 вариант A: most-restrictive quota из всех buckets/windows (hit, ближайший will_hit, max used%, stable key), фактическая duration; правило выбора и макеты approved ask #931, popup показывает все квоты, omit missing / без фиктивных 0%. Unknown ID только current numbers; stale / unconfirmed scoped Codex скрыт и без⚠. Системные notifications / Claude ledger не менять.

Проверка: targeted Swift query/model/center tests: wire nullability/always-arrays, absent windows, gates freshness900/901 и future60/61, expired reset, safe/will_hit invalid endpoints, stale source, unknown identity без истории/прогноза, ordinaryUsageAllowedfalse без обещания «можно работать», navigate while refresh, stop while read, scope change. Повторные UI refresh ждут один result; provider Retry изолирован. Shared fixture plot_json/public line→Swift и stale/fetched mismatch/points outside window. Menu/tray copy tests: fresh/stale/error/disabled/unknown ID/scope change/missing window/duration/warning одного / обоих/toggle off; gates отдельно на provider. Проверки всех copy/result/error states. Не ослаблять существующие guard tests.

## Task 5. Экран Plans по макетам

Depends on: Task 4.

Production content на DesignKit/Tone с двумя карточками и графиками, адаптивная ширина, Weekly/5h picker, forecast markers, dynamic details; выбранное отсутствующее5h не заменяется weekly. Все projection unavailable_reason имеют согласованный copy. Реальные Refresh/Retry и честные sign-in instructions. Rename tab label с сохранением raw persistence и notification routes. Заменить test-only drawing production content в DesignShotCatalog fixtures.

Проверка: обе темы и все состояния через DesignShotCatalog, включая menu/tray states из spec; открыть PNG и сравнить с утверждёнными. Targeted UI/model tests, `make lint-swift`, build. Визуальные отклонения или новое поведение вне спецификации — отдельный ask до ревью.

## Task 6. Интеграционное ревью и PR

Depends on: Task 5.

Обновить feature docs, сохранить PLANUSAGE-01..03, LLMUSAGE-01 и PROJ-*; покрыть deterministic fixtures от raw Codex response до готового экрана. Выполнить local-review, независимое ревью и исправить принятые findings. Проверить production screenshots, приложить PNG к PR в main. Merge только по действующим правилам проекта, не объявлять задачу done до прохождения ревью.

Проверка: один итоговый набор затронутых Go/Swift тестов, lint/build, leak-check; не повторять дорогие полные проверки без новых причин. Описание PR: реальный Codex на Plans + независимые сбои + сохранённые контракты, команды и ограничения.

## Общий checklist implementer/reviewer

На каждой задаче читать owner comments, выставлять in_progress; при независимом ревью in_review; после принятого ревью done + короткий summary. Проверять scope/reset isolation, реальные optional windows, stale forecast gating, process cleanup, no credentials/log leaks, совместимость Go↔Swift, все UI тексты в model, DesignKit/Tone и соответствие макетам. Задачи выполняются последовательно в отдельном worktree этого target; новые параллельные lanes не нужны.

## Decisions

- Последовательная реализация, отдельные Codex storage и adapter — решил агент.
- UI/прогноз утверждены — ask #919; вариант A menu/tray, правило выбора и макеты утверждены в ask #931; B/C только для сравнения.
- Plans+menu/tray Codex, notifications Claude-only — ask #925 approved; Claude CLI/notice contracts сохраняются.
- Missing-ID policy, freshness, CLI/locking — ask #923 approved.
- Additive plot_json/Go typed Line, DB с периодом 30 s и retention 8 days(existing poller) — решил агент, rationale в spec; техническая спецификация утверждена в ask #934, план проходит независимое ревью.

- Продолжать согласованную реализацию без повторных рутинных разрешений — conversation, 2026-11-02; это не объявляется отдельным owner approval плана. Новые изменения поведения вне утверждённой spec остаются отдельными решениями.
