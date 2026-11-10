# Goose як runtime для складних текстових запитів: фактична перевірка

Дата: 10 листопада 2026. Машина: Apple M1, 16 GB, macOS 14.5 (23F79). Перевірено реальним запуском офіційних бінарників на цьому Mac. Модель замінено локальним mock-сервером OpenAI Chat Completions, бо API-ключа немає. Глобально нічого не встановлено, системні налаштування не змінено.

## Рішення: go з умовами

Goose v1.58.1 підходить як runtime для складних текстових запитів через `goose-acp` (ACP по stdio, дочірній процес Jarvis). Усі сім пунктів, які можна перевірити без ключа, на macOS 14.5 працюють. Проте типова конфігурація Goose для Jarvis небезпечна і робить додаткові витрати, які не потрапляють в облік. Тому go діє лише за умов нижче. Остаточне підтвердження буде після одного прогону з реальним провайдером (див. «Що потрібно від користувача»).

Умови go (обов'язкові для v0.1):

1. **Закріплений бінарник** `goose-acp` v1.58.1 (SHA256 нижче) як дочірній процес зі stdio. `goose serve` (HTTP/WebSocket) не використовувати.
2. **Заблокована конфігурація:** усі platform extensions вимкнені; єдиний інструмент — наш MCP-адаптер типізованих дій; `GOOSE_MODE: approve`; `GOOSE_DISABLE_SESSION_NAMING: true`; `GOOSE_MAX_TURNS` малий (наприклад 8); `GOOSE_TELEMETRY_OFF=1`; `GOOSE_PATH_ROOT` у каталозі застосунку з правами 0700.
3. **Клієнт Jarvis ніколи не надсилає `allow_always`/`reject_always` і ніколи не вмикає `auto` через `session/set_mode`.** Варіант `allow_always` зберігає постійний дозвіл, і далі Goose вже не питатиме.
4. **Остаточна перевірка підтвердження — у нашому MCP-адаптері, а не в Goose.** Скасування в Goose не зупиняє інструмент, який уже виконується (перевірено). Тому дія з побічним ефектом має бути двофазною: спершу чернетка/план, потім виконання лише за одноразовим токеном підтвердження від UI Jarvis, і перед кожним комітом перевірка скасування.
5. **Бюджет рахує Jarvis**, а не Goose: облік `usage_update.cost` у власному журналі, ліміти на запит і на місяць, плюс ліміт витрат на боці провайдера як останній захист. Вбудованого ліміту витрат у Goose немає.

Якщо реальний прогін провайдера провалить пункти 4 або 7 нижче (немає usage/cost), застосувати запасний варіант (останній розділ).

## Закріплена версія

| Параметр | Значення |
|---|---|
| Репозиторій | `aaif-goose/goose` (сюди перенаправляє `block/goose`) |
| Реліз | `v1.58.1`, опубліковано 2026-11-10T04:09Z (patch до v1.58.0) |
| Commit тега | `c97af00bca96442611bb95155c56d6109afa42d6` |
| `goose-aarch64-apple-darwin.tar.gz` | SHA256 `9df32ef39ed696911ea2931435660393020e839013d0ccad30f82d68dfd49bce` — повний CLI, 177 MB |
| `goose-acp-aarch64-apple-darwin.tar.gz` | SHA256 `e6667ba0741efc959f09a7ccadbad368f0ca3c47de77395d4d5d120a81301d4f` — лише ACP-агент, 16 MB |
| Підпис | ad-hoc (`linker-signed`), без Developer ID і нотаризації; quarantine xattr немає, бо завантажено через `gh` |
| Мінімальна macOS у Mach-O | `LC_BUILD_VERSION minos 12.0`, arm64 |

v1.58.1 вийшов у день перевірки. Він виправляє лише промпт компактування й OAuth Databricks. Якщо потрібен реліз, який «відлежався», v1.58.0 відрізняється тільки цими двома виправленнями. Перед вбудовуванням у застосунок бінарник треба переписати нашим підписом. Ad-hoc підпис для розповсюдження не годиться.

Розміщення (не у git, `.runtime/` ігнорується):

```
.runtime/research-goose/v1.58.1/
  dl/            завантажені архіви
  cli/goose      повний CLI
  acp/goose-acp  slim ACP-агент
  src/           shallow clone тега v1.58.1 (для читання коду)
  root/          GOOSE_PATH_ROOT з типовими extensions
  root-locked/   GOOSE_PATH_ROOT із заблокованою конфігурацією
  harness/       mock-openai.mjs, mock-mcp.mjs, acp-probe.mjs, env.sh, логи
  licenses/      аудит ліцензій залежностей
```

Команди встановлення:

```bash
D=.runtime/research-goose/v1.58.1; mkdir -p $D/dl && cd $D/dl
gh release download v1.58.1 -R aaif-goose/goose \
  -p 'goose-aarch64-apple-darwin.tar.gz' -p 'goose-acp-aarch64-apple-darwin.tar.gz'
shasum -a 256 *.tar.gz        # збігається з digest у GitHub release
mkdir -p ../cli ../acp
tar -xzf goose-aarch64-apple-darwin.tar.gz -C ../cli
tar -xzf goose-acp-aarch64-apple-darwin.tar.gz -C ../acp
```

Ізоляція: `GOOSE_PATH_ROOT` переносить config, data (sessions.db) і state (логи) в один каталог; це перевірено через `goose info`. `HOME` теж перевизначено, бо `.agents/plugins` береться з home. Ключ провайдера — фіктивний рядок `OPENAI_API_KEY=mock-local-not-a-key` для локального mock, `GOOSE_DISABLE_KEYRING=1`, щоб нічого не писалося в Keychain.

## Як перевіряли

- `harness/mock-openai.mjs` — локальний (127.0.0.1:18431) streaming-сервер `/v1/chat/completions` з `usage` у фінальному чанку. Сценарії: звичайна відповідь по 150 мс на чанк; `SLOW` (40 чанків по 250 мс); `TOOL` (виклик інструмента); `ERR401`. Модель `gpt-4o-mini`, щоб Goose міг оцінити ціну.
- `harness/mock-mcp.mjs` — stdio MCP-сервер із побічним інструментом `draft_email`, який створює файл-маркер. Імітує наш майбутній адаптер типізованих дій.
- `harness/acp-probe.mjs` — мінімальний ACP-клієнт (JSON-RPC 2.0, по рядку на повідомлення через stdio) з тими ж кроками, які робитиме Swift-клієнт: `initialize` → `session/new` (з `mcpServers`) → `session/prompt` → обробка `session/update` і `session/request_permission` → `session/cancel`.

Конфігурація `root-locked/config/config.yaml`:

```yaml
GOOSE_PROVIDER: openai
GOOSE_MODEL: gpt-4o-mini
OPENAI_HOST: http://127.0.0.1:18431
GOOSE_MODE: approve
GOOSE_TELEMETRY_ENABLED: false
GOOSE_DISABLE_SESSION_NAMING: true
extensions:   # кожен із: code_execution chatrecall analyze tom developer skills
  developer:  # summon scheduler summarize todo apps extensionmanager
    enabled: false
    type: platform
    name: developer
    bundled: true
  # ... так само для решти
```

Запуск (приклад):

```bash
cd .runtime/research-goose/v1.58.1/harness && source env.sh
node mock-openai.mjs &                      # mock-модель
export GOOSE_PATH_ROOT=$R/root-locked
MCP_SERVER=$PWD/mock-mcp.mjs node acp-probe.mjs tool-reject ../acp/goose-acp
# сценарії: basic | cancel | err | tool-reject | tool-allow | tool-cancel-pending | tool-allow-then-cancel
# SET_MODE=auto|approve|smart_approve — режим через session/set_mode
```

## Результати по пунктах

| # | Пункт | Результат |
|---|---|---|
| 1 | Закріплена версія, ізольоване встановлення | **Працює** |
| 2 | Запуск на macOS 14.5 | **Працює** |
| 3 | Транспорт для власного клієнта (ACP) | **Працює** |
| 4 | Streaming | **Працює** з mock; з реальним провайдером **не перевірено** |
| 5 | Скасування | **Працює**, але з двома застереженнями |
| 6 | Approval перед побічними інструментами | **Працює** лише в режимі `approve`; типовий режим `auto` не питає |
| 7 | Облік токенів/вартості | **Частково**: облік є, ліміту немає, є невраховані виклики |

### 1–2. Версія і запуск на macOS 14.5 — працює

`goose --version` → `1.58.1`. Обидва бінарники запускаються без Rosetta. Холодний старт до відповіді на `initialize`: 106–272 мс (`goose acp`), 156–294 мс (`goose-acp`). Пам'ять під час стрімінгу: ~149 MB RSS (повний `goose acp`), ~46 MB (`goose-acp`, після ініціалізації). Режим `goose acp` по stdio не відкриває портів, у `lsof` видно тільки з'єднання до провайдера.

Мережа поза провайдером: при кожному старті Goose фоном завантажує `https://models.dev/api.json` (~6 MB, з ETag-кешем у `data/model_catalog`). Опції вимкнення в коді немає (`crates/goose/src/model_catalog.rs`). Звідти ж беруться ціни для оцінки вартості. Даних користувача цей запит не містить. Телеметрія PostHog працює лише за явної згоди: без вибору користувача `is_telemetry_enabled()` повертає `false`, і `GOOSE_TELEMETRY_OFF=1` її теж вимикає. З'єднань до PostHog не помічено.

### 3. Транспорт — працює: ACP по stdio

`goose acp` або окремий `goose-acp` — це ACP-агент (Agent Client Protocol, `protocolVersion: 1`), JSON-RPC 2.0, одне повідомлення на рядок через stdin/stdout. Stdout містив лише валідний JSON, логи пишуться у файли. Swift-застосунок може запускати `goose-acp` через `Process` + `Pipe` без мережі й портів.

Фактична відповідь `initialize`: `loadSession: true`, `promptCapabilities.audio: false`, сесії `list/delete/close`, `mcpCapabilities.http: true`. `session/new` повертає `sessionId` і режими `auto | approve | smart_approve | chat`. Наші MCP-сервери передаються в `session/new.mcpServers` (stdio-команда + env), Goose їх запускає й додає інструменти з префіксом (`jarvis__draft_email`).

Сумісність MCP: Goose 1.58.1 спочатку надсилає MCP-серверу `server/discover` (MCP `2026-07-28`). Якщо сервер відповідає на нього не помилкою, а порожнім `result`, Goose пише `failed to start extension ... process quit before initialization`, і інструмент мовчки зникає. З відповіддю `-32601 Method not found` Goose переходить на `initialize` (`2025-11-25`), і все працює. Наш адаптер має або коректно реалізувати `server/discover`, або відповідати `-32601`. Збій тихий, тож Jarvis має перевіряти, що його інструменти присутні.

Альтернатива `goose serve`: працює, але відкриває TCP (127.0.0.1:3284 плюс ще один випадковий порт на loopback). Без `GOOSE_SERVER__SECRET_KEY` не стартує; `/acp` без ключа повертає 401, `/health` і `/status` відкриті. Для нативного клієнта stdio простіший і безпечніший.

Помилка провайдера (mock 401): текст помилки приходить як звичайний `agent_message_chunk` («Ran into this error: Authentication error…»), а `session/prompt` завершується JSON-RPC помилкою `-32000 "Authentication required"`, `data.reason: "turn_failed"`. Клієнт має не озвучувати такий chunk як відповідь, а показувати стан помилки за кодом.

### 4. Streaming — працює з mock

Відповідь приходить як `session/update` → `agent_message_chunk` по одному на кожен чанк провайдера, без буферизації. Mock віддавав чанки кожні 150 мс; клієнт отримав їх на 389, 539, 689, 841, 993, 1143, 1295 мс. Перший чанк надійшов через ~160 мс після `session/prompt`, і майже весь цей час — локальна підготовка (mock відповідає миттєво). Запит до провайдера Goose робить зі `stream: true, stream_options.include_usage: true`.

З реальним провайдером не перевірено: потрібен ключ. Не виміряно затримку до першого токена, якість української та поведінку конкретного провайдера.

### 5. Скасування — працює, з двома застереженнями

- Під час стрімінгу: `session/cancel` (notification) → `session/prompt` повертає `stopReason: "cancelled"` за 5–27 мс. HTTP-з'єднання до провайдера обривається приблизно за 100 мс, стрім далі не читається. Наступний prompt у тій самій сесії працює.
- Під час очікування дозволу: cancel + `outcome: cancelled` → `stopReason: cancelled`, інструмент не викликаний, маркера немає.
- **Застереження 1: інструмент, що вже виконується, не зупиняється.** Після `allow_once`, коли інструмент виконувався 4 с, cancel повернув `cancelled` за 7 мс, і Goose надіслав MCP-серверу `notifications/cancelled`. Mock-інструмент ігнорує скасування, тож маркер з'явився після повернення `cancelled`. Гарантію «скасував — нічого не сталося» має давати адаптер Jarvis (умова 4).
- **Застереження 2: фонові LLM-виклики скасування не зупиняє.** Коли назви сесій увімкнені (типово), Goose на кожен хід робить окремий streaming-запит «Generate a short title…». Cancel його не обірвав: з'єднання жило 5,6 с, до завершення процесу. Тому вимикаємо `GOOSE_DISABLE_SESSION_NAMING: true`; після цього додаткових запитів не було.

### 6. Approval — працює в режимі `approve`

- Перед викликом інструмента приходить `session/update: tool_call` (назва, `rawInput` з аргументами), потім **запит агента до клієнта** `session/request_permission` з опціями `allow_always | allow_once | reject_once | reject_always`. До рішення клієнта інструмент не виконується; маркер перевірено.
- `reject_once` → `tool_call_update status: failed` з текстом «The user has declined…», MCP `tools/call` не надходить, маркера немає. `allow_once` → `tools/call`, маркер є, `status: completed`. Так поводиться і вбудований `shell`, і наш MCP-інструмент.
- **Типовий режим — `auto`** (`GooseMode::Auto` з `#[default]`, документація це підтверджує). У `auto` (встановленому через `session/set_mode`) `shell` виконав `touch` без жодного запиту. Режим має задавати конфігурація, а клієнт не повинен перемикати його на `auto`.
- **Типово увімкнені небезпечні інструменти:** без власної конфігурації моделі доступні 17 інструментів, серед них `shell`, `write`, `edit`, `delegate` та `extensionmanager__manage_extensions` (може вмикати нові extensions). Вимикання в `extensions:` працює: лишаються тільки наші `jarvis__*` і платформний `load_skill`.
- `allow_always` записує постійний дозвіл (`PermissionLevel::AlwaysAllow`), і в режимах `approve`/`smart_approve` Goose більше не питатиме (`permission_inspector.rs`). Jarvis не повинен показувати цю опцію для дій із побічними ефектами.
- `smart_approve` у нашому прогоні теж спитав дозвіл для `draft_email` (`readOnlyHint: false`). За кодом він для неанотованих інструментів робить окрему LLM-класифікацію, тобто це зайві виклики й недетермінізм. Для Jarvis — тільки `approve`.
- Для голосу: у `tool_call` є людська назва (`"jarvis: draft email · …"`) і повний `rawInput`. Цього достатньо, щоб UI сформулював конкретне підтвердження («Надіслати лист X на адресу Y?»). Але текст підтвердження має будувати адаптер із типізованих аргументів, а не з довільного тексту моделі.

### 7. Облік токенів і вартості — частково

Що працює:
- `session/update: usage_update` після кожного виклику моделі, включно з викликами посеред ходу (після tool call): `used` — поточний розмір контексту, `size` — ліміт контексту, `cost.amount` — **накопичена вартість сесії в USD**.
- Відповідь `session/prompt` містить `usage: {inputTokens, outputTokens, totalTokens}` за поточний хід.
- Оцінка ціни правильна для тестової моделі: 1000 in + 20 out для `gpt-4o-mini` дало $0.000162 = 1000×$0.15/M + 20×$0.60/M. Друге звернення в сесії підсумувалося до $0.00036. Джерело ціни: ціна, яку повернув провайдер (наприклад OpenRouter `usage.cost`), інакше оцінка за каталогом models.dev або ціни, задані в custom provider config.

Чого немає або що не рахується:
- **Ліміту витрат немає.** У коді немає бюджету в USD. `GOOSE_MAX_TURNS` типово 1000, його треба знизити.
- **Виклики для назви сесії не враховуються**: у basic-прогоні було два запити до моделі, а `cost` дорівнював одному. Лікується вимкненням naming.
- **Скасований стрім записується як 0 токенів**: `usage_update used: 0`, бо `usage` приходить лише в останньому чанку. Реальний провайдер, імовірно, візьме гроші за вхідні токени. Jarvis має рахувати скасований запит консервативно, за оцінкою вхідних токенів.
- Не перевірено: облік compaction-викликів (у коді є прапорець `is_compaction`), retry після 429/5xx, LLM-класифікація `smart_approve`.

Накладні витрати промпту (з `state/logs/llm_request.*.jsonl`): типова конфігурація — ~19,9 тис. символів на запит (system 5,6 тис. + 17 інструментів 13,3 тис.); заблокована — ~4,4 тис. символів (system 2,9 тис. + 1–2 інструменти). Це ~1,1–1,5 тис. токенів фонового входу на кожен виклик замість ~5 тис.

Орієнтовна оцінка бюджету (ще не вимір, перевірити на реальному провайдері): задача з 3 викликами по ~3 тис. вхідних і ~300 вихідних токенів коштує ~$0.0015 за ціни $0.15/$0.60 за M (≈6 600 задач на $10) або ~$0.04 за ціни $3/$15 за M (≈245 задач на $10).

## Приватність і дані на диску

- Аудіо до Goose не потрапляє: Jarvis передає лише текст. `promptCapabilities.audio: false`. Вбудоване диктування Goose не використовуємо.
- **Goose пише останні 10 повних LLM-запитів** (system prompt, історія, інструменти) у `state/logs/llm_request.{0..9}.jsonl` з правами `rw-r--r--`, а також усю розмову в `data/sessions/sessions.db`. Для голосових команд це чутливий текст. Потрібно: `GOOSE_PATH_ROOT` усередині `~/Library/Application Support/Jarvis/…` з 0700, політика очищення, і не передавати в Goose секрети без потреби.
- Ключ провайдера: типово macOS keyring, з file-based fallback. Для Jarvis — ключ у Keychain застосунку, у дочірній процес передавати через env, `GOOSE_DISABLE_KEYRING=1`, щоб Goose не тримав окрему копію.

## Ліцензії

- Код Goose: **Apache-2.0** (`LICENSE` у теґу v1.58.1).
- ACP-бінарник і CLI зібрані з того самого workspace (`Cargo.lock`: 1128 пакетів).
- Upstream `cargo-deny` у CI перевіряє лише `advisories`, **ліцензії залежностей upstream не перевіряє** (у `deny.toml` немає секції `[licenses]`).
- Власний аудит ліцензій залежностей за `Cargo.lock` через crates.io API: див. наступний підрозділ.

### Аудит залежностей (crates.io, 1 запит/с)

Скрипт: `harness/license_audit.py`, результат: `licenses/crates.tsv`. `Cargo.lock` тега v1.58.1 містить 1112 registry-пакетів, 15 workspace-крейтів (усі `license.workspace = true` → Apache-2.0) і 1 git-залежність (`cudaforge`, CUDA). У 1112 пакетів ліцензія задана, помилок запиту 0.

- Пермісивні (MIT, Apache-2.0, BSD, ISC, Zlib, Unlicense, Unicode-3.0, BSL-1.0, 0BSD, CC0, bzip2-1.0.6, CDLA-Permissive-2.0 для `webpki-roots`): переважна більшість.
- Вибір ліцензії, де є копілефт: `mach-sys` (`GPL-3.0 OR Apache-2.0`) і 2 пакети `MIT OR Apache-2.0 OR LGPL-2.1-or-later` — беремо пермісивну гілку.
- **MPL-2.0 (23 пакети, копілефт на рівні файлу):** `symphonia*` (аудіо-декодери для dictation), `uniffi*` (goose-sdk), `colored`, `option-ext`. MPL допускає статичне лінкування в закритому застосунку, але вимагає зробити доступним вихідний код самих MPL-файлів і зберегти повідомлення.
- **LGPL-3.0-or-later (1 пакет):** `ansi_colours 1.2.3`, залежність `bat` (підсвітка коду в терміналі CLI). Статичне лінкування LGPL у Rust-бінарнику накладає обов'язок дати змогу перелінкувати. Для розповсюдження в складі Jarvis це небажано.

Що реально злінковано (евристика за шляхами `registry/src/...` у `strings` бінарника; це не доказ, остаточну відповідь дасть `cargo tree --target aarch64-apple-darwin -p goose-acp` / `cargo about`):

| Пакет | `cli/goose` | `acp/goose-acp` |
|---|---|---|
| `bat` (→ `ansi_colours`, LGPL-3.0) | є | не знайдено |
| `symphonia` (MPL-2.0) | є | не знайдено |
| `colored` (MPL-2.0) | є | не знайдено |
| `uniffi`, `mach-sys` | не знайдено | не знайдено |

Висновок: для вбудовування брати **`goose-acp`**, а не повний CLI. За евристикою в ньому немає LGPL і MPL-аудіо. Перед релізом Jarvis зібрати точний перелік ліцензій для `goose-acp` під `aarch64-apple-darwin` (потрібен Rust toolchain, у цій перевірці не встановлювався) і покласти `NOTICE`/третьосторонні ліцензії в бандл. Apache-2.0 вимагає зберегти `LICENSE` і `NOTICE` Goose.

## Що потрібно від користувача

Щоб закрити «не перевірено», потрібен один реальний прогін із провайдером:

1. **Вибір провайдера і моделі** для складних запитів у межах $10/міс (наприклад Anthropic, OpenAI або OpenRouter; OpenRouter повертає `usage.cost`, і тоді вартість — від провайдера, а не оцінка).
2. **API-ключ цього провайдера** з **увімкненим лімітом витрат у кабінеті провайдера** (рекомендовано $10/міс). Ключ вводить користувач сам: у Keychain або в змінну середовища в терміналі. У чат його не передавати.
3. Після цього перевірити тим самим `acp-probe.mjs` (без mock, лише змінивши `GOOSE_PROVIDER/GOOSE_MODEL`): затримку до першого токена, streaming, `usage_update.cost` проти рахунку провайдера, скасування посеред стріму, 10–20 українських/англійських складних запитів.

## Запасний варіант, якщо no-go

Межа та сама: Jarvis володіє голосом, UI, підтвердженнями, бюджетом і набором типізованих дій (`open_app`, `open_url`, `draft_email` тощо), а виконання дій проходить через той самий адаптер із двофазним підтвердженням. Замість Goose — маленький прямий планувальник у Swift:

- один HTTP-клієнт до вибраного провайдера (streaming SSE, `URLSession`), tool calling із JSON-схемами наших дій;
- цикл не більше N кроків, кожен tool call — через ту саму перевірку підтвердження;
- скасування — `Task.cancel()` + обрив `URLSession`; облік usage з кожної відповіді в той самий журнал бюджету;
- без MCP-оркестрації, recipes і багатосесійності у v0.1; історія — лише поточна розмова.

Це ~500–800 рядків Swift. Код адаптера дій і бюджету залишається тим самим за будь-якого рішення, тож почати можна з нього, не чекаючи вибору runtime.

## Наслідки для плану

- Наступний крок не залежить від рішення: MCP-адаптер типізованих дій (stdio) з `server/discover` → `-32601`, двофазним підтвердженням і перевіркою скасування.
- Swift ACP-клієнт: `Process` + рядковий JSON-RPC; обробка `agent_message_chunk`, `tool_call`, `request_permission` (тільки `allow_once`/`reject_once`), `usage_update`, `stopReason`, помилки `-32000/turn_failed`.
- Конфігурація з умов go генерується Jarvis під час першого запуску і перевіряється при кожному старті (наявність лише `jarvis__*` інструментів і режим `approve`).
