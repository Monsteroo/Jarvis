# Доповнення пакета 4: OpenAI → Goose → native approval

Продовження коміта `5537552`, гілка `codex/actions`. Користувач обрав **прямий OpenAI API**, не OpenRouter. `GooseConfig.openAI(root:model:)` фіксує провайдера; початковий рекомендований model `gpt-5.4-mini` залишається змінним параметром. Справжній API key не читався, не створювався й не використовувався.

Цей документ оновлює межу попереднього PACKAGE-4.md: локальний IPC helper уже реалізований і перевірений із pinned Goose. Підключення до App.swift/build.sh і живу перевірку панелі виконує Claude, оскільки ці файли в його роботі.

## Нові частини

- `AgentIPCServer` живе у головному застосунку та обслуговує лише AgentMCPBridge. Unix socket у приватному випадковому каталозі `/private/tmp/jarvis-…`, каталог 0700, сокет 0600. Перевірка same-user peer credentials і окремої випадкової capability на кожному повідомленні. Немає HTTP-порту, платіжного ключа чи native approval token у протоколі.
- `AgentMCPHelper` — маленький stdio↔Unix socket relay; він не містить окремого executor і не має MCP-методів approve/commit. Власна точка входу `Sources/Agent/Helper/Main.swift` компілюється в окремий executable, **не** у головний target.
- `GooseMCPServer` передає в session/new тільки наш helper. ACP permission allow_once допускається лише для jarvis__propose_action з pinned Goose `_meta.goose.toolCall` і незміненими rawInput. Всі інші інструменти відхиляються; allow_always і auto не використовуються. Дозвіл виклику propose_action не є дозволом виконати дію.
- `AgentPlanningContext` підключає broker/turn/helper до BudgetedGooseAgent.run. На success IPC закривається, плани залишаються на строк дії для native UI. На error/cancel broker скасовується та IPC закривається. У моделі немає каналу виконати план самостійно.
- `Sources/Actions/UI/AgentApprovalPanel.swift`: окрема SwiftUI/AppKit панель у стилі ARC Current, точні параметри дій, «Підтвердити один раз», «Відхилити», реальний результат. NSPanel не стає key/main і показується без NSApp.activate, щоб не забирати focus цільового вікна. Це ще потребує live перевірки у складі app.

## Підключення Claude

1. Перенести це доповнення після 5537552. Додати верхньорівневі Sources/Agent/*.swift і Sources/Actions/UI/*.swift до app swiftc invocation. Frameworks попередніх пакетів + SwiftUI.
2. Окремо зібрати helper. За зразком scripts/test-agent.sh використовуються Sources/Actions/*.swift + Sources/Agent/*.swift + Sources/Agent/Helper/Main.swift (без App.swift/ArcViews). Він має бути у Contents/Helpers/JarvisMCPHelper і підписаний разом із bundle. Потім можна звузити helper compile set до JSON/IPC файлів, не змінюючи протокол. **Не додавати Helper/Main.swift до app target: це друга @main.**
3. Helper URL брати зі свого app bundle, не з LLM, команди користувача чи довільної змінної середовища. App/helper мають однакову довірену збірку. Swiftc тестовий helper наразі ad-hoc; distribution signing залишається окремою роботою.
4. Створити спільний ActionExecutor/BudgetLedger/AgentActionBroker один раз. Приклад нижче. Синхронні файлові операції та bootstrap не виконувати на UI-critical path.
5. На новому voice turn/cancel/mic-off спочатку закривати approval controller попереднього turn, скасовувати Task AI-запиту та broker.cancel(turn:). Не показувати результат застарілого generation.

```swift
// Main actor: reuse the executor used by basic voice commands.
let runner = LocalTypedActionRunner(actionExecutor)
let broker = AgentActionBroker(executor: runner)
let agentConfig = try GooseConfig.openAI(root: appSupport.appendingPathComponent("goose"))
let ledger = try BudgetLedger(file: appSupport.appendingPathComponent("budget.json"))
let agent = BudgetedGooseAgent(config: agentConfig, ledger: ledger,
    launcher: PinnedGooseLauncher(executable: bundledGooseACP))

let context = AgentPlanningContext(broker: broker, turn: voiceTurnUUID,
                                  helperExecutable: bundledMCPHelper)
// apiKey is obtained locally from Keychain by the app, never from chat.
let answer = try await agent.run(text: acceptedComplexText, language: "uk",
                                apiKey: apiKey, planning: context)
// Verify voice generation before updating UI or showing the panel.
let approval = AgentApprovalController(broker: broker, turn: voiceTurnUUID, language: "uk") {
    plan, outcome in
    // Actual ActionExecutor result: update UI/history; no simulated success.
}
// Retain approval in the app controller until close/cancel/next turn.
await approval.show()
```

Новий `begin` у broker скасовує незавершені попередні плани. Не створювати нового broker на кожну пропозицію. Панель розрахована на показ після завершення відповіді AI; не змішувати native confirmation з ACP permission callback. Обробник ніколи не чекає кліку в MCP tools/call: він повертає «план очікує перевірки». Виконання та його результат живуть у Jarvis. Автоматичне продовження роздумів моделі після виконання плану в цьому пакеті не реалізоване.

Для керування вікном важливо зберегти frontmost app: панель не активує Jarvis. Якщо користувач активував саме головне вікно Jarvis, поточний MacWindowAccess відхилить дію над власним вікном; він не вгадує приховану попередню ціль. Потрібні живі focus-тести після інтеграції.

## Докази перевірки

1. `bash scripts/test-agent.sh` — 70 перевірок unit/mock-process/IPC та typecheck нової панелі (разом із 133 попередніми перевірками дій — 203). Окрема компіляція панелі: `bash scripts/test-agent.sh --typecheck-ui`. Через Unix sockets на цьому Mac запуск потрібен поза sandbox; sandbox bind відхиляє. Немає справжнього API, Keychain, аудіо чи системних дій.
2. `bash scripts/test-agent.sh --runtime-smoke /…/goose-acp` — **реальний pinned goose-acp 1.58.1**, локальний Python mock OpenAI SSE на 127.0.0.1, реальний helper і app-owned broker. Перевірено: ACP handshake → MCP discovery fallback/initialize → пропозиція від моделі → нуль побічних дій до approve → рівно одна fake-дія після approve. Proxy у дочірньому процесі блокує зовнішній models.dev fetch; ключ фіктивний. Runtime smoke не керує Mac.
3. Під час перевірки виправлено специфіку Darwin: accept() успадковує O_NONBLOCK від listener. Тепер прийнятий socket явно переходить у blocking mode з timeout; помилка EAGAIN на першому повідомленні більше не обриває relay.
4. Нативна панель пройшла компіляцію/typecheck під macOS 14.5. Візуальне відображення, кліки, focus, live Window/CoreAudio та main app bundle в цьому доповненні не перевірено.

Після збирання main app Claude має пройти живий сценарій: запит → конкретний план → reject нічого не змінює → approve виконує один раз → close/cancel інвалідовує решту → новий turn не показує старі результати. Лише тоді вважати інтеграцію завершеною.

## Межі бюджету й даних не змінилися

Аудіо залишається локальним; у провайдера передається тільки прийнятий складний текст і дозволений контекст. Бюджет Jarvis до $10/UTC-місяць, але фінальний рахунок залежить від точності/затримки usage; provider-side spending controls потрібно перевірити окремо. Доступу до пошти/календаря/довільних файлів чи shell у новому MCP немає. Helper/IPC capability не дорівнює дозволу на send/delete/purchase — цих actions у registry взагалі ще немає.

Keychain UI, справжній OpenAI API прогін, standalone packaging та тексти transitive ліцензій залишаються окремими незавершеними роботами.
