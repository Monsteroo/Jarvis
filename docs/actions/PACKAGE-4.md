# Пакет 4: ACP, бюджет, підтвердження та обробник MCP

Гілка `codex/actions`, після `423cd1f`. Це модулі для інтеграції; головний застосунок і голосовий конвеєр не змінені. Жодних платних API-викликів не зроблено.

## Що працює ізольовано

- `JSONRPCProcess`: дочірній процес без shell, NDJSON ACP v1, обмеження кадру 256 KiB, тайм-аути, EOF/помилки, Task cancellation, завершення процесу. stdout/stderr не журналюються. POSIX read використано навмисно: Foundation read(upToCount:) затримував короткі повідомлення pipe до заповнення буфера.
- `GooseACPClient`: initialize → session/new → approve mode → streaming prompt, фільтрація session ID, дедуплікований cumulative USD cost. Будь-які permission requests відхиляються reject_once або cancelled; завжди/auto/FS/terminal/audio не підтримуються. Помилка провайдера скасовує provisional текст.
- `GooseConfig`: slim goose-acp 1.58.1, закріплений SHA256 executable, приватні каталоги, вимкнені extensions/naming/telemetry, максимум 8 turns; лише конкретний ключ провайдера в окремому env, без успадкування інших секретів та без перевизначення HOME. За pinned source `config/paths.rs`, GOOSE_PATH_ROOT покриває також .agents, тому старе припущення дослідження про обов'язковий HOME override не застосовується.
- `BudgetLedger`: точні integer micro-USD, максимум $10/UTC-місяць, типовий резерв $0.25 на запит. File lock між екземплярами, atomic write + fsync, права 0700/0600, відмова при пошкодженому журналі. Резерв перед inference; невідоме/перерване usage консервативно витрачає весь резерв. Неврегульовані резерви після crash не звільняються автоматично. Дублі usage не додають вартість повторно.
- `BudgetedGooseAgent`: один запит за раз, новий процес/session/private root на кожен turn; резерв до запуску, облік після відповіді, припинення на отриманому usage ceiling, спроба очищення тимчасових даних turn. Після crash або помилки cleanup приватні файли Goose можуть залишитися; перед релізом потрібна політика очищення старих turn-каталогів. Ключ/модель не задано в коді й не витягувались із системи.
- `AgentActionBroker`: конкретний typed plan → UI approve → одноразовий token → атомарне споживання token до await executor. Токен дійсний 120 s за monotonic clock; replay, інша дія, cancel, новий turn та expiry не виконують побічного ефекту. Agent не отримує API approve/commit. Диктування з LLM у неявне поле заборонено.
- `AgentMCPBridge`: legacy MCP 2025-11-25 handler з server/discover → -32601; інструмент лише propose_action. Сувора схема типізованих аргументів, зайві поля й невідомі дії відхиляються. Пропозиція не виконує дії. ActionExecutor тепер має typed handle(action:language:), який використовує той самий реєстр, cancellation та історію.

## Важлива межа поточного пакета

**Goose зараз підключається лише для текстової відповіді.** MCP handler/broker протестовані в одному процесі, але IPC між дочірнім MCP helper Goose і живим app-owned broker ще не реалізований. ACP session/new навмисно передає mcpServers: []. Не вмикай додаткові extensions і не додавай child-процесу власний необмежений executor заради обходу цієї межі.

Наступна інтеграційна задача: приватний IPC helper до єдиного broker у застосунку, preview/approve/cancel у native UI та узгоджене закриття turn. До цього складні AI-запити не можуть керувати Mac; локальні прості команди з попередніх пакетів продовжують працювати незалежно.

## Приклад першого текстового підключення Claude

Додай `Sources/Agent/*.swift` до swiftc invocation; Apple CryptoKit використовується через import (Swift linker autolink). Загальну збірку цього пакета я не запускав.

```swift
let base = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Jarvis/agent")
let ledger = try BudgetLedger(file: base.appendingPathComponent("budget.json"))
let config = try GooseConfig(provider: selectedProvider, model: selectedModel,
                            root: base.appendingPathComponent("goose"))
let agent = BudgetedGooseAgent(config: config, ledger: ledger,
    launcher: PinnedGooseLauncher(executable: installedGooseACP))
// Тільки обраний складний текстовий запит, ніколи кімнатне аудіо/неприйнятий transcript:
let answer = try await agent.run(text: acceptedText, language: "uk", apiKey: keyFromKeychain)
```

Створення/виклик агентів та дискові операції не виконувати у UI-critical path. Збережи Task і викликай cancel разом із voice generation invalidation. Для streaming є `GooseACPClient.stream()`; події тексту provisional, не озвучуй і не показуй як успішну дію до фінального result. Якщо потрібен streaming саме BudgetedGooseAgent, додай явне forwarding UI events через той самий turn, не обходь ledger прямим prompt у production.

Значення `answer.cost` у низькорівневому client — cumulative session USD; BudgetedGooseAgent щоразу створює нову session, тому повторне віднімання/накопичення не потрібне. Не використовуй один client для багатьох платних prompts із прямим обліком усієї суми як нової.

Конкретні provider/model обирає користувач. API key він вводить у Keychain застосунку або власному терміналі; не просити його в чаті. Текстовий AI може помилятися — його заяви про виконання дій не є ActionExecutor events.

## Бюджет: що саме гарантується

Ledger не допускає новий зарезервований запит понад локальний $10 ліміт. Goose повідомляє ціну після викликів, інколи оцінює її за models.dev; тому це **не гарантія зовнішнього рахунку ≤$10**. Поточний запит може перевищити резерв до надходження usage; таке перевищення зберігається й блокує наступні запити, якщо вичерпано місячний ліміт. Для реального провайдера потрібен ліміт на його боці й звірка usage з рахунком. Нульове/відсутнє usage не вважається доведеним безкоштовним викликом.

Ledger не має автоматичного «скинути бюджет»: пошкодження/завислі резерви потребують явної діагностики, щоб restart не відкривав новий безкоштовний ліміт. API ключів, тексту запиту й відповідей у ledger немає.

## Перевірки

- `bash scripts/test-agent.sh`: 57 перевірок, mock Python stdio process, без мережі та реального провайдера.
- `bash scripts/test-actions.sh`: 133 перевірки попередніх локальних дій.
- Перевірено archive SHA256 `e6667ba0741efc959f09a7ccadbad368f0ca3c47de77395d4d5d120a81301d4f` і executable SHA256 `6e1ffe11b7e54db34adf56a1ef1f3bf3c3493c8ac259ad45c49eb8299e73e0b7` без запуску pinned binary. Після власного підписування executable digest зміниться: packaging має свідомо оновити trusted manifest, не прибирати перевірку.
- Перевірені framing, streaming, duplicate usage, provider error, timeout/EOF, cancellation, чужі session chunks, неправильна валюта, cost stop, ledger restart/місячна межа/overrun/corruption, approval replay/cancel/expiry, MCP propose-only.
- Не перевірено: Swift client проти реального Goose binary, реальний LLM provider, native approval UI, IPC helper, інтегрований app build, реальна затримка/вартість. Наявний upstream прогін Claude не заміняє цих інтеграційних перевірок.

## Що залишилось

1. App-owned broker ↔ MCP helper IPC і підключення proposal UI.
2. Вибір провайдера/моделі, Keychain UI та один реальний контрольований прогін.
3. Ліцензії transitive sherpa/Goose dependencies для distribution, standalone packaging (разом із Claude).

Primary references: pinned Goose v1.58.1 source у `.runtime/research-goose/v1.58.1/src`, попередній дослідницький звіт; https://agentclientprotocol.github.io/typescript-sdk/types/SessionUpdate.html ; https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-06-18/schema.mdx (legacy lifecycle/tools, точна runtime negotiation у тестах — 2025-11-25).
