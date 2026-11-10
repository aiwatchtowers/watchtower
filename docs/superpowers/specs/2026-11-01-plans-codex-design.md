# Plans: Claude и Codex

Задача #1470. Техническая спецификация утверждена в ask #934 без замечаний. Дизайн Plans — ask #919, правила — #923, объём меню — #925, вариант A и макеты меню — #931.

## Результат

Usage → Plans показывает лимиты подписок Claude и Codex на одном экране: отдельные карточки, история расхода, прогноз до сброса, детализация Claude. Проценты подписок не складываются. Никаких вымышленных данных или неработающих кнопок подключения в рабочем экране.

## Источник Codex

Использовать установленный Codex, найденный через `codex.FindBinary(cfg.CodexPath)`, и его JSON-RPC app-server. Проверены официальная [документация](https://learn.chatgpt.com/docs/app-server) и локально сгенерированная схема Codex CLI 0.166.0 (`app-server generate-json-schema`).

Внутри `internal/codex` добавить отдельный helper чтения лимитов поверх существующего транспорта. Интерфейс hook trust не расширять. Только initialize/initialized, `account/read` с `refreshToken:false` и `account/rateLimits/read`; без thread/turn/model вызовов, login/logout, reset-credit consumption и записи настроек. Фоновый запрос передаёт `excludeResetCreditDetails:true`, не включает experiment capabilities. Процесс ограничен бюджетом и завершается вместе со всей группой, включая cancel/EOF/error. Не логировать сырые ответы, email, токены или stderr с учётными данными.

Watchtower не обновляет credentials. Сам Codex может обслуживать собственную OAuth-сессию при запросах; это не распространяет разрешения на существующий сборщик Claude.

При наличии непустого `rateLimitsByLimitId` использовать buckets из него; иначе legacy `rateLimits`. Учитывать nullable primary/secondary, необязательные planType/limitName. Длительность берётся из `windowDurationMins`: 300 — 5 часов, 10080 — неделя; прочие положительные длительности отображать с собственным названием. Нельзя определять окно по позиции primary/secondary или выдумывать отсутствующее. Нулевые/невалидные длительности не становятся графиком. Некорректные/пустые ответы дают явную ошибку чтения, а не 0%.

Процент расхода проверять на finite и ограничивать 0…100, сброс читать как Unix seconds. Ключ квоты однозначно включает bucket, слот primary/secondary и длительность, без коллизий компонентов. Разные buckets не объединять. `ordinaryUsageAllowed:false` показывать как ограничение сервиса; безопасный прогноз одной квоты не означает разрешение запускать запросы.

## История и расчёт

Существующие singleton `plan_usage_status`, `plan_usage_samples` и CLI `usage plan --json` остаются совместимыми. Codex получает отдельные additive таблицы `codex_plan_usage_status` и `codex_plan_usage_samples` через новую Go migration. В той же migration добавить `plot_json TEXT NOT NULL DEFAULT '{}'` в существующий Claude status и новое Codex status. Go — единственный писатель. Зеркалировать schema.sql и сгенерировать schema snapshots/Swift test schema. Отдельное Codex storage сохраняет legacy singleton/CLI совместимость: технический default агента, не отдельное owner approval.

Codex status хранит состояние, причину, plan, fetchedAt, безопасную ошибку, identity scope, нормализованные квоты с duration/reset/projection; samples — scope, limit key, takenAt, percent, resetsAt. В одной транзакции публиковать успешный снимок и его samples; повтор одного снимка идемпотентен. Хранить samples 8 дней: источник существующий `internal/planusage/poller.go`, а не новая owner policy. Историю обоих providers ограничивать workspace/provider, reset ±60s и `taken_at ≤ опубликованный status.fetched_at`; дополнительно для Codex обязательно совпадение account scope. Существующая схема истории Claude не получает нового accountId/scope-gate. Последний фильтр не допускает ещё неопубликованные Claude samples: их запись по-прежнему предшествует status. Codex snapshot+samples остаются атомарными.

Scope — SHA-256 от namespace Codex home и `accountId` того же ответа о лимитах. Raw account ID не записывается. Если ответ не даёт accountId, показывать только текущие числа этого успешного ответа. Последний status допустимо сохранить, но samples не записывать, прежние samples не читать, историю/график и прогноз не показывать; `history_available=false`, `projection.drawable=false`, причина `identity_unknown`. Не читать auth.json и не использовать email как замену ID. При смене scope не показывать прошлые аккаунтные значения и прогноз. При неизвестной identity или неуспешном новом чтении, не подтвердившем scope, скрыть прежние scoped значения и историю: сохранённая строка не является доказательством текущего аккаунта. Успешный ответ без ID показывает собственные числа, не старый status. Никакого fallback на email/auth.json.

Переиспользовать существующий чистый Go расчёт `planusage.project` через узкий экспортируемый helper, сохранив формулу: минимум 15 минут наблюдений, slope ≥0, lookback 1 час для session и 24 часа для прочих окон, фильтр reset. Состояния idle/collecting/safe/will_hit/hit. Допустимость прогноза определяется таблицей ниже. Swift отображает Go projection и предрасчитанные endpoints, не вычисляет rate заново.

## Передача endpoints из Go в Swift

Desktop сохраняет 30 s чтение daemon DB, не заменяет его CLI polling. `plot_json` сериализует существующий Go forecast, без новой формулы в Swift. Точная форма:

```json
{"schema_version":1,"fetched_at":"2026-11-02T09:00:00Z","limits":{"weekly_all":{"start_at":"2026-11-02T09:00:00Z","start_percent":40,"end_at":"2026-11-04T09:00:00Z","end_percent":64},"session":null}}
```

Все верхние keys обязательны: `schema_version:1`, `fetched_at:UTC RFC3339 timestamp`, `limits:map<limit_key,Line|null>`. Line имеет ровно четыре обязательных поля: `start_at:UTC timestamp`, `start_percent:finite 0…100`, `end_at:UTC timestamp`, `end_percent:finite 0…100`. Начало строго равно status.fetched_at/limit.percent. End вычисляет Go по существующему projection и gates. Private DTO с accountId/scope не сериализуется в plot_json или CLI.

Успешный status upsert атомарно публикует plot_json/fetched_at/limits_json; у Codex в той же транзакции samples. Error сохраняет last-good plot/fetchedAt, но eligibility gates скрывают старую линию. Успешный Codex без ID публикует текущий status с null-кандидатами, без старого scope.

Validate schema 1, plot.fetched_at==status.fetched_at, точное начало, finite проценты, end>start, обе точки внутри известного окна. `{}` — единственное legacy/default исключение: endpoints_unavailable, ждать следующего poll/Refresh без source call из read. Валидный null/отсутствующий limit key также endpoints_unavailable, если более ранний gate не дал другую причину. Malformed JSON, неизвестная schema, fetched mismatch или невалидный Line — storage error, без нулей и пересчёта.

Новый CLI обязательно включает projection.line:Line|null. Go read применяет текущие freshness/identity/reset/hitAt gates к stored candidate; Swift DB presentation применяет те же gates к typed Line без вычисления rate/end. `drawable ⇔ line!=null`, только при валидной линии и пройденных gates; иначе line=null даже при старом stored candidate. Legacy `usage plan --json` сохраняет прежние три поля projection, без этих расширений. Go↔Swift shared fixture закрепляет plot_json и новую projection.line.

## Свежесть и запрет прогноза

Снимок свежий только при `state=ok`, наличии `fetched_at` и возрасте `now-fetched_at ≤ 900s`. Строго `>900s` — stale; `fetched_at > now+60s` — stale с причиной `clock_skew`. Разрешённый небольшой сдвиг в будущее не даёт отрицательного текста возраста. `error/stale/unavailable/disabled` stale немедленно. Общий feature gate `false` также делает представление disabled/stale без записи при ручном refresh.

Проверки идут сверху вниз, первая совпавшая задаёт `projection.drawable=false` и `unavailable_reason`:

| Порядок | Условие | Причина |
|---|---|---|
| 1 | Feature выключен или status disabled | `disabled` |
| 2 | Future timestamp >60s; иначе не ok/нет fetched_at/возраст >900s | `clock_skew`; иначе `stale` |
| 3 | Codex snapshot без подтверждённого accountId/scope | `identity_unknown` |
| 4 | Нет положительной известной duration; иначе нет reset | `missing_window_duration`; иначе `missing_reset` |
| 5 | `reset ≤ now` | `reset_expired` |
| 6 | Raw projection idle/collecting/hit | соответственно `idle`/`collecting`/`hit` |
| 7 | Нет текущего scoped sample или его reset отличается >60s | `collecting` |
| 8 | Есть `hit_at ≤ now` | `prediction_expired` |
| 9 | Нет опубликованного endpoints candidate: {}, null или отсутствующий limit key | `endpoints_unavailable` |
| 10 | Rate не finite/отрицательный либо projection противоречит валидному endpoint | `invalid_projection` |

После gates линия допустима только для `safe/will_hit` и finite `rate_per_hour ≥0`. Для will_hit обязательны rate>0 и `now < hit_at < reset`; endpoint=(hit_at,100). Для safe допускается rate=0 с плоской линией до reset; при rate>0 обязателен hit_at≥reset, endpoint=(reset,clamp(limit.percent+rate×hours,0…100)), hours=(reset−status.fetched_at)/3600, рассчитывается Go. Начало — опубликованные fetched_at/percent, не неопубликованная sample. Отсутствующий/противоречивый hit_at при положительном rate — `invalid_projection`. Не рисовать отрицательный countdown: прошедший hit_at показывает «Forecast needs an update», а не новый safe-прогноз. Пустая текущая история означает collecting, не 0%. При drawable=false текст карточки также определяется первой причиной gate, а не сохранённым raw safe/will_hit. Raw state остаётся пятизначным; неизвестный state в сохранённом JSON — ошибка storage, не подмена на idle и не шестое состояние.

`ordinaryUsageAllowed=false` переопределяет общий вывод о возможности работать: «Codex usage is currently restricted». Прогноз квоты может оставаться safe, но описывает только расход квоты, не разрешение сервиса. Null/true не являются обещанием доступности запросов. Все пояснения/freshness/countdown/ошибки задаются presentation model и проверяются тестами.

## Polling и координация писателей

Опрос Codex независим от Claude: первая попытка через 10 секунд, затем 5 минут; transient failure backoff до 30 минут. Каждый provider refresh имеет общий deadline 45s (включая lock wait), ограничение app-server не увеличивается автоматически. `plan_usage.enabled=false` запрещает обе fetch-операции. Feature id/config key не переименовывать; описание расширить на обе подписки.

Все писатели одного провайдера используют `fsutil.LockFile/TryLockFile`: стабильные файлы `.plan-usage-claude.lock` / `.plan-usage-codex.lock` в workspace, mode0600. Это daemon, новый CLI, legacy `usage plan --now` и `MarkDisabled`. Lockfile не удалять/не заменять: inode стабилен, kernel освобождает flock при crash. Разные провайдеры не блокируют друг друга. SQL-транзакция не содержит сетевых/процессных вызовов.

Фоновый poll использует TryLock: busy → пропустить цикл без изменения status/backoff/failure count; следующий обычный tick через5min. Manual --now ждёт максимум20s в пределах45s; истечение ожидания → operation `busy`, без записи source status. Получив lock, заново прочитать feature flag и последний status, выполнить ровно один настоящий fetch, вычислить projection и опубликовать результат до unlock. Для Codex snapshot+samples публикуются одной транзакцией; последовательность записей существующего Claude poller не меняется, его fetch/store целиком защищены тем же lock. MarkDisabled тоже сериализован; manual --now при off ничего не fetch/write. Отмена и общий provider deadline освобождают lock и не публикуют ошибочный source status. Внутренний HTTP timeout при ещё действующем общем context может записать source error; operation error в обоих случаях `timeout`. Два внешних CLI сериализуются и каждый делает один fetch: межпроцессного coalescing не обещаем. UI center использует single-flight на provider: повторный вызов ожидает тот же task/result.

`--provider all --now` запускает провайдеров независимо/параллельно, не fail-fast, дожидается обоих и выдаёт partial results. Retry обновляет только выбранный источник. Состояние и ошибка одного не переписывают другого. Существующий backoff Claude/JSON legacy сохраняется, добавляется только общий lock.

## Новый CLI: точный контракт v1

`usage plans --json [--now] [--provider all|claude|codex]`. Локальный `--provider` этого subcommand выбирает подписки, default all; он не меняет глобальный AI provider или config. Без --now только DB read через read-only handle: без создания DB, migrations или записи status/samples. При feature-off --now также допускается только read-only handle для retained status; отсутствие DB/таблицы не вызывает создание или migration. Legacy `usage plan --json` и его трёхпольная projection не меняются. Ниже все перечисленные ключи обязательны; nullable обозначен `|null`, дополнительные ключи v1 не выдаются. Массивы никогда не null; timestamps — UTC RFC3339, rate/percent — finite JSON numbers.

| Объект | Поля и типы |
|---|---|
| Envelope | `schema_version:1`, `requested_provider:"all"|"claude"|"codex"`, `refresh_requested:bool`, `feature_enabled:bool`, `providers:Provider[]` |
| Provider | `provider:"claude"|"codex"`, `ok:bool`, `error:Error|null`, `refresh_outcome:"not_requested"|"updated"|"failed"|"busy"|"disabled"|"cancelled"`, `status:Status|null` |
| Error | `code:ErrorCode`, `message:string` (safe/redacted; никакого raw stderr) |
| Status | `state:"ok"|"stale"|"unavailable"|"error"|"disabled"`, `reason:string`, `plan:string`, `fetched_at:timestamp|null`, `updated_at:timestamp`, `last_error:string`, `stale:bool`, `history_available:bool`, `ordinary_usage_allowed:bool|null`, `limits:Limit[]`, `breakdown:Breakdown[]` |
| Limit | `key:string`, `label:string`, `group:string`, `percent:number` (0…100), `window_duration_minutes:int|null`, `resets_at:timestamp|null`, `projection:Projection` |
| Projection | `state:"idle"|"collecting"|"safe"|"will_hit"|"hit"`, `hit_at:timestamp|null`, `rate_per_hour:number` (finite≥0), `drawable:bool`, `unavailable_reason:UnavailableReason|null`, `line:Line|null` |
| Line | `start_at:timestamp`, `start_percent:number` (finite 0…100), `end_at:timestamp`, `end_percent:number` (finite 0…100), правила и validation — раздел endpoints |
| Breakdown | `key:string`, `label:string`, `percent:number` (finite 0…100) |

`UnavailableReason` — закрытый enum из таблицы gates: disabled, clock_skew, stale, identity_unknown, missing_window_duration, missing_reset, reset_expired, idle, collecting, hit, endpoints_unavailable, invalid_projection, prediction_expired. При drawable=true причина null. Невалидный rate источника не сериализовать как NaN/negative: normalized rate 0 + drawable=false/invalid_projection. Невалидный percent не становится фиктивным0: неуспех parse/недопустимое окно. Неизвестная duration → null, unknown group сохраняется строкой, полного chart нет. `ordinary_usage_allowed=null` для Claude/неизвестного Codex. history_available требует хотя бы один sample текущего окна и, только для Codex, подтверждённый текущий scope; новый accountId-gate к старым данным Claude не применяется.

Providers содержит только выбранные записи, сортировка Claude→Codex. `ok ⇔ error=null`: это результат текущей операции, не состояние подписки. Успешный DB read stale/unavailable status может иметь ok=true; ещё нет строки → status=null,error=null,ok=true. Ошибка DB read → status=null,error storage,ok=false. После failed/busy/cancelled refresh допускается читаемый retained status, но его freshness/identity gates обязательны; error относится к операции. Unknown identity скрывает прежние scoped данные даже при retained row. `last_error` — безопасная source-ошибка либо пустая строка; не заменяет operation error. Без --now outcome всегда not_requested (включая read failure).

Закрытый ErrorCode: `no_credentials`, `unsupported_auth`, `cli_missing`, `unsupported_cli`, `network`, `parse`, `storage`, `busy`, `feature_disabled`, `cancelled`, `timeout`. Отсутствие ChatGPT sign-in→no_credentials, API key-only→unsupported_auth; нет CLI→cli_missing; неизвестный метод/версия→unsupported_cli. Fetch/parser/storage failure→failed; lock timeout→busy; feature off→disabled; signal cancellation→cancelled. Source no_credentials/unavailable при --now — operation failure, exit1; при read-only чтении такой сохранённой строки operation успешна.

| Exit | Правило |
|---|---|
| 0 | Все выбранные операции успешны (не означает свежесть/доступность подписок) |
| 1 | Ошибка выбранного source/read, busy либо provider deadline45s; полный partial JSON сохраняется |
| 2 | Неверные аргументы: без fetch, stderr с ошибкой, stdout JSON не выдаётся |
| 3 | Feature off при --now: без fetch/write, JSON с feature_enabled=false и feature_disabled для выбранных providers |
| 130 / 143 | SIGINT / SIGTERM: best-effort полный partial JSON с cancelled-ошибкой у незавершённых providers; SIGKILL ничего не гарантирует |

Приоритет завершения: invalid args до работы; signal130/143, затем feature-off3, иначе operation failures1, иначе0. При feature-off можно прочитать существующие строки; status=null допустим, источник не обновляется. stdout содержит только один JSON document, диагностические сообщения — безопасный stderr. AccountId/email/scope/credentials/raw response не входят в envelope.

Пример read-only ответа до первого Codex poll (без вымышленных нулевых квот):

```json
{"schema_version":1,"requested_provider":"codex","refresh_requested":false,"feature_enabled":true,"providers":[{"provider":"codex","ok":true,"error":null,"refresh_outcome":"not_requested","status":null}]}
```

Codex states различают отсутствие CLI, неподдерживаемый метод, sign-in, API key-only, malformed и transient errors. Инструкции предлагают самостоятельно открыть/войти в Codex и Retry; не начинать login автоматически.

## Desktop

App-wide center продолжает 30-секундное чтение daemon DB: независимый read каждого провайдера, явное состояние ошибки чтения, start/stop/cancellation как сейчас. Навигация не отменяет refresh. Swift модели и queries читают typed plot_json/Line и зеркалируют новый Go wire/storage контракт; shared fixture фиксирует Go↔Swift соответствие. Default {} — endpoints_unavailable до следующего poll, malformed/fetched mismatch — явная ошибка чтения. Все тексты прогресса, результатов, ошибок и CTA задаются в чистой presentation model и проверяются тестами.

Вкладка называется Plans; сохранить raw persisted tab value и маршруты уведомлений. Карточки Claude/Codex рядом от 800pt, ниже одним столбцом. Основная квота — weekly при наличии, иначе доступная с корректным названием. Дополнительные buckets/модельные лимиты и breakdown сохраняются. Недоступная подписка не блокирует доступную. Карточка показывает plan, расход, reset, freshness и прогноз. Главное уведомление отражает самый важный актуальный прогноз, не объявляет всё безопасным при ошибках.

Графики Weekly/5 hours показывают выбранные реальные окна. Если выбранного окна нет — явное объяснение; не подменять его другой квотой. Ось X: reset минус фактическая длительность → reset. История сплошная, прогноз пунктиром от опубликованных status.fetched_at/limit.percent, маркеры Now/Reset и достижения 100%. will_hit заканчивается у 100% до reset; safe — у прогнозного значения на reset. При stale/expired/collecting/idle прогнозная линия отсутствует с пояснением. Переключение периода не смешивает истории разных окон.

Scope утверждён владельцем в ask #925: «Экран и меню-бар». Codex входит в Plans и menu-bar/tray. Тумблер с существующим key/default управляет обеими подписками. Имена providers обязательны перед числами, порядок Claude→Codex; проценты не суммировать. Claude сохраняет существующие5h/7d counters. Правило выбора утверждено владельцем в ask #931 (вариант A): показывать одну самую ограничивающую Codex quota среди всех buckets/windows. Сначала hit≥100%, затем валидный drawable will_hit по ближайшему hit_at, затем максимальный used%; равенство — стабильный bucket/limit key. Unknown-ID свежие числа участвуют по used%, без forecast. Duration фактическая, отсутствующие окна опускать без0%. В popup показать все Codex buckets/windows с forecast/state; не прятать дополнительные квоты только в Plans. Вариант A и его визуальный эталон утверждены в ask #931 без замечаний. Base bucket и все квоты в строке остаются только сравнительными альтернативами, не реализацией.

При unknown-ID допустимы только текущие числа успешного ответа, без history/forecast. Старые/неподтверждённые scoped Codex числа скрыты. Stale не добавляет предупреждение ⚠; актуальные предупреждения providers могут объединяться одним prefix. Freshness/identity/expired gates применяются отдельно к каждому provider, а не глобально ко всей строке. Системные уведомления остаются Claude-only: не добавлять Codex notifications и не менять существующие notice ledger/dedupe, PLANUSAGE-01..03 и PROJ-*.


## Макеты и проверка совпадения

Утверждённые макеты: [каталог](../../design/mockups/plans/index.html), [описание](../../design/2026-11-01-plans-mockups.md). `PlansShotFixtures.shots` уже зарегистрирован в DesignShotCatalog.

- [Заполненный, dark](../../design/mockups/plans/plans-filled-dark.png) и [light](../../design/mockups/plans/plans-filled-light.png).
- [Пусто](../../design/mockups/plans/plans-empty-dark.png), [загрузка](../../design/mockups/plans/plans-loading-dark.png), [ошибка с Retry](../../design/mockups/plans/plans-error-dark.png).
- [Обновление](../../design/mockups/plans/plans-busy-dark.png), [одна подписка](../../design/mockups/plans/plans-scoped-dark.png), [Codex недоступен](../../design/mockups/plans/plans-unavailable-dark.png), [узкое окно](../../design/mockups/plans/plans-narrow-dark.png).

Для production menu/tray добавить DesignShotCatalog fixtures: оба fresh, один отсутствует, один stale/error, unknown-ID current numbers, неподтверждённый scope, отсутствующее окно, неизвестная duration, warning одного/двух providers и toggle off. Отрендерить обе темы/узкую строку и сверить prefix/provider names/порядок/без0% с утверждённым scope; Утверждённые menu/tray mockups строятся тем же DesignShotCatalog: [рекомендуемый выбор](../../design/mockups/plans/plans-menu-filled-dark.png), [base bucket](../../design/mockups/plans/plans-menu-policy-base-dark.png), [все квоты в строке](../../design/mockups/plans/plans-menu-policy-all-dark.png), [узкое окно](../../design/mockups/plans/plans-menu-narrow-dark.png); у каждого есть light-пара. Правило выбора и основной/узкий макеты утверждены в ask #931; base/all изображения являются только сравнением. Apple/File/Edit в макете — только контекст, сокращённый в узком preview; это не предложение управлять меню других приложений. Числа counters в рекомендованном preview не обрезаются.

Полный утверждённый набор menu/tray: [описание и правило A](../../design/2026-11-02-plans-menu-mockups.md), [галерея](../../design/mockups/plans/index.html#menu-filled). Состояния: [пусто](../../design/mockups/plans/plans-menu-empty-dark.png), [загрузка](../../design/mockups/plans/plans-menu-loading-dark.png), [ошибка с Retry](../../design/mockups/plans/plans-menu-error-dark.png), [обновление](../../design/mockups/plans/plans-menu-busy-dark.png), [один provider](../../design/mockups/plans/plans-menu-scoped-dark.png), [текущие числа без history](../../design/mockups/plans/plans-menu-unknown-id-dark.png), [stale](../../design/mockups/plans/plans-menu-stale-dark.png), [toggle off](../../design/mockups/plans/plans-menu-off-dark.png). У каждого есть light-пара.

У каждого состояния есть светлая пара. Production content подключить к DesignShotCatalog на синтетических моделях и перерендерить обе темы. Проверить рядом с утверждёнными макетами: геометрия, тексты, forecast markers, отсутствие обрезки; семантические отличия для реальных отсутствующих окон отображать честно. Только DesignKit/Tone, без stock GroupBox и разделителей строк.

## Acceptance: обязательная самостоятельная матрица

Каждый сценарий проверяется детерминированными тестами с injected now/budgets, fake app-server и без внешней сети. CLI goldens закрепляют весь JSON, stdout/stderr, exit и отсутствие запрещённых side effects. Конкуренция проверяется реальными subprocess flock с короткими injected deadlines без20s sleeps.

| Сценарий | Ожидаемый результат |
|---|---|
| Stateok fetched900s /901s назад | На900 fresh; на901 stale, line=null/reason stale |
| Fetched now+60s /+61s | +60 допустимо без отрицательного copy; +61 clock_skew, line=null |
| Reset==now или раньше | reset_expired, без линии/отрицательного countdown |
| Codex successful response без accountId | Текущие числа допустимы; samples не писать, history/chart/forecast скрыть, identity_unknown |
| Scope changed / failed response без подтверждения scope | Старые scoped числа/история скрыты |
| Observations span <15 min | Collecting без forecast |
| Safe rate 0 | Typed Line плоская от fetched_at/percent до reset |
| Will_hit now < hit_at < reset, rate>0 | End=(hit_at,100), пунктир и100% marker |
| Hit_at ≤ now /will_hit hit_at≥reset | prediction_expired /invalid_projection, line=null, не safe |
| Missing duration/reset/sample; sample reset отличается>60s | Правильный gate; не подменять окно/0% |
| Unknown raw projection state | Storage error, не fake idle/шестое состояние |
| Default plot{} /валидный null/missing key | endpoints_unavailable после ранних gates, без source call из read |
| Malformed plot/schema не 1/fetched mismatch/invalid Line | Storage error, без Swift rate/end math и фиктивных координат |
| Claude sample новее published fetched_at /иной reset | Не входит в историю/forecast |
| Go→Swift shared fixture | Точный plot_json/Line keys/nullability/gates; accountId/email/scope отсутствуют в DTO |
| ordinaryUsageAllowedfalse | Общий статус restricted, даже если quota safe |
| CLI all/claude/codex | Только выбранные providers, Claude→Codex, обязательные keys/null/[]/закрытые enums, golden |
| Read unavailable/no row/readfailure | ok=true+source unavailable /ok=true+status=null /ok=false+storage+status=null |
| Exit 0 /exit 1 partial | Все операции успешны /ошибка с результатом другого provider; --all ждёт обоих |
| Exit 2 | Invalidargs, без fetch, stderr, stdout пуст |
| Exit 3 | Feature off --now: без calls/writes, feature_disabled JSON |
| Exit 130/143 | SIGINT/SIGTERM: best-effort partial JSON, cancelled незавершённым providers, unlock |
| Signal+disabled+failure | Приоритет signal>disabled>failure>success |
| Daemon + два CLI на одном provider | Serialize fetch, каждый внешний --now делает свой fetch; daemon busy skips без error/backoff write |
| Lock wait 20 s /provider deadline 45 s | busy /timeout; короткие injected budgets, no sourcewrite при busy/общейотмене |
| Разные providers /cancel /crash | Providers независимы; cancel/kernel release lock, стабильный inode |
| UI center повторный refresh | Один fetch, все awaiters получают один result; навигация task не отменяет |
| Legacy usage plan JSON | Полный golden прежней схемы; projection ровно три поля, plot_json не добавлен |
| Menubar fresh/stale/error/disabled/unknown ID/scope changed | Отдельные provider gates; имена/порядок/фактическиеduration, omit missing / без фиктивных 0%, без ⚠ на stale |
| Menubar warning одного/обоих/toggle off | Warning только fresh, общий prefix; прежний key/default действует на оба |
| Codex additional buckets /Claude notices | Все Codex buckets/windows в tray; вариант A выбора bar утверждён в ask #931; Codex notifications отсутствуют, Claude dedupe/ledger неизменны |
| Production UI | DesignShotCatalog все states / обе темы / узкий экран+menu, сравнение с макетами и UI copy tests |

Scope/reset isolation, migration Up/Down, retention 8 days и snapshot rollback проверяются отдельно. Независимое ревью и PR до merge; task не done до принятого ревью.

## Decisions

- Общий экран/прогнозы — ask #919 approved; conversation «норм. Делаем».
- Missing-ID policy, freshness/gates, CLI schema/exitcodes и lock/deadlines — ask #923 approved, уточнения ask #921; это согласование завершено.
- «Экран и меню-бар»: Codex Plans+menu/tray, notifications Claude-only — ask #925 approved.
- App-server reader, отдельные Codex storage/accountId scope — решил агент; техническая спецификация утверждена в ask #934.
- Additive plot_json и typed Go Line при DB с периодом 30 s/legacyJSON compatibility — решил агент как endpoint serialization, не новая формула; утверждено в составе спецификации ask #934.
- Retention8 days — источник существующий internal/planusage/poller.go; отдельный storage сохраняет legacy singleton/CLI — решил агент, технический default, не отдельное owner approval.
- Вариант A: наиболее ограничивающая квота Codex в строке и все buckets в popup; основной/узкий макеты и состояния — ask #931, approved без замечаний. Объём «экран и меню-бар» — ask #925.
- Spec/plan review до production-кода — watchtower-flow; текущая правка runtime не меняет.
