# Jarvis: завдання для ChatGPT (Sol 6.1, Medium), паралельно з Claude

Дата: 10 листопада 2026. Спершу прочитай:

- `AGENTS.md`;
- `docs/superpowers/specs/2026-11-10-jarvis-v0.1-design.md`;
- `docs/reports/2026-11-10-claude-progress-vs-spec.md` — що вже зроблено.

Ці завдання **не стосуються голосу**. Claude паралельно працює над активацією «Jarvis», аудіо й ASR. Мета — щоб ви не заважали одне одному: різні гілки, різні файли, одна узгоджена точка інтеграції.

## Як працювати паралельно

1. **Окремий worktree й гілка.** Не працюй у `/Users/user/Documents/Projects/Jarvis`: там незакомічена робота Claude.
   ```bash
   cd /Users/user/Documents/Projects/Jarvis
   git worktree add ../Jarvis-actions -b feat/actions feat/voice-prototype
   ```
2. **Не запускай `scripts/build.sh`, setup-скрипти й застосунок** без узгодження з користувачем.
   - `build.sh` збирає whisper.cpp у `.runtime/`, а це спільна директорія.
   - Застосунок має той самий bundle ID і мікрофон.
   - Для своїх модулів зроби окремий `scripts/test-actions.sh`. Він компілює лише `Sources/Actions/*.swift`, `Sources/Agent/*.swift` і їхні тести через `swiftc` з тим самим VFS overlay, що в `build.sh`. Створюй overlay у власному `.build/` свого worktree, системний SDK не редагуй.
3. **Стиль тестів** як у проєкті: окремий виконуваний файл з `@main` і функцією `check(...)`, без XCTest. Swift 6.0.3 CLT, `-swift-version 5`, target macOS 14.5.
4. Комітиш лише у `feat/actions`. Не робиш rebase і merge у `feat/voice-prototype` і не пушиш без дозволу користувача.

## Хто якими файлами володіє

| Власник | Файли |
|---|---|
| **Claude (не чіпати)** | `Sources/Audio.swift`, `Sources/WakeListener.swift`, `Sources/WakeSupport.swift`, `Sources/WakeBridge.*`, `Sources/VoiceState.swift`, `Sources/ArcRenderer.swift`, `Sources/Parakeet.swift`, `Sources/App.swift`, `scripts/build.sh`, `scripts/setup-wake.sh`, `scripts/wake_fixtures.sh`, усі наявні `Tests/*` |
| **ChatGPT** | нові `Sources/Actions/**`, `Sources/Agent/**`, `Tests/Actions/**`, `Tests/Agent/**`, `scripts/test-actions.sh`, нові документи в `docs/actions/` |
| **Спільне, через користувача** | `Sources/ArcViews.swift` — нові екрани додавай **новими файлами** (`Sources/Actions/UI/*.swift`), без правок наявних View; `THIRD_PARTY.md` — лише нові рядки внизу |

Інтеграцію в `App.swift` і в рядок компіляції застосунку в `build.sh` зробить Claude. Потрібна лише одна точка входу — контракт нижче.

## Контракт інтеграції

Голосовий конвеєр віддає готовий текст команди: слово «Jarvis» уже прибране, мова відома, `"uk"` або `"en"`. Реалізуй:

```swift
/// Sources/Actions/CommandHandling.swift
enum CommandOutcome: Equatable {
    case done(summary: String)                          // дію фактично виконано й перевірено
    case partial(summary: String, details: String)      // частина вдалась; чесно, що ні
    case failed(reason: String)                         // зрозуміла, відновлювана помилка українською
    case needsApproval(ApprovalRequest)                 // відправлення/видалення/покупка: конкретний вміст
    case notUnderstood                                  // далі піде в LLM-планувальник (дні 5–6)
}

protocol CommandHandling: AnyObject {
    /// Не на main thread; підтримує скасування через Task cancellation.
    func handle(_ text: String, language: String) async -> CommandOutcome
}
```

`summary` і `reason` — короткі тексти для UI українською (англійською, якщо `language == "en"`).

**Оновлено 10 листопада (Claude):**
- `summary` і `reason` Jarvis вимовляє вголос (`SpeechOutput`), тож тримай їх короткими: одне речення.
- Для диктування Claude використовує твій `ActionExecutor.captureDictationTarget()` на початку кожного голосового ходу, до показу HUD. Власний `FocusTarget` прибрано як дублікат.
- Текст команди вже очищено від відомих російських форм ASR («открій» → «відкрий»).

## Завдання (у порядку пріоритету)

Кожне — окремий коміт із тестами. Якщо щось неможливо без дозволів macOS або без живого запуску, явно напиши, що перевірено, а що ні.

### A1. Модель дій і реєстр (основа)

**Файли:** `Sources/Actions/ActionModel.swift`, `ActionRegistry.swift`.

- Типізовані дії: `openApp`, `quitApp`, `activateApp`, `openURL`, `webSearch`, `windowMinimize`, `windowMaximize`, `windowLeftHalf`, `windowRightHalf`, `volumeSet`, `volumeStep`, `mute`, `dictate`.
- Для кожної дії: схема параметрів, валідація, політика підтвердження і результат.
- Жодного «успіху» без перевірки факту.

**Тести:** валідація, відмова на невалідні параметри, політика підтвердження.

### A2. Розбір команд без LLM, UK/EN

**Файл:** `Sources/Actions/IntentParser.swift`. Текст → дія або `.notUnderstood`.

- Приклади: «відкрий браузер / термінал / пошту», «закрий Safari», «зроби гучніше», «вимкни звук», «знайди в інтернеті …», «open terminal», «maximize window», «відкрий сайт github.com».
- Нечутливо до регістру, пунктуації й закінчень.
- **Тільки українська й англійська, без російських форм**: правило `AGENTS.md`. ASR-помилки на кшталт «открій» виправлятиме Claude на боці ASR, не парсер.

**Тести:** щонайменше 30 фраз (≥20 сценаріїв — критерій релізу), включно з негативними («розкажи анекдот» → `.notUnderstood`).

### A3. Програми

**Файл:** `Sources/Actions/AppActions.swift`.

- Відкрити, активувати й закрити програму через `NSWorkspace` / `NSRunningApplication`.
- Словник синонімів UK/EN («браузер» → браузер за замовчуванням, «термінал» → Terminal, «пошта» → Mail), зберігається в JSON із дефолтами.
- Workspace — через протокол, щоб тести не відкривали реальних програм.
- Для неіснуючої програми — зрозуміла помилка.

### A4. URL і пошук

**Файл:** `Sources/Actions/WebActions.swift`.

- Відкриття URL у браузері за замовчуванням і пошук із правильним кодуванням запиту.
- Лише `http`/`https`; `file:` і `javascript:` відхиляються.

**Тести:** кодування, відхилення схем.

### A5. Вікна через Accessibility

**Файл:** `Sources/Actions/WindowActions.swift`.

- Згорнути, розгорнути, ліва чи права половина вікна активної програми через `AXUIElement`.
- Перевірка `AXIsProcessTrusted()`. Без дозволу — `failed` з поясненням, як його дати. Дозвіл не запитувати приховано.
- Якщо вікно не підтримує дію — `partial` або `failed`, чесно.

### A6. Гучність

**Файл:** `Sources/Actions/AudioOutputActions.swift`.

- Гучність, крок, mute для вихідного пристрою за замовчуванням через CoreAudio.
- Яскравість і Focus — лише перевірка можливості з поясненням, що не підтримується. Без неофіційних хаків.

### A7. Виконавець зі скасуванням

**Файл:** `Sources/Actions/ActionExecutor.swift`. Реалізує `CommandHandling`: розбір → валідація → підтвердження → виконання → перевірка результату.

- Підтримує скасування: дію, скасовану до старту, не виконано; дію, що вже виконалась, не «відкочено», а чесно звітовано.
- Події прогресу (`AsyncStream`) для майбутньої смуги кроків у UI.

### A8. Локальна історія

**Файл:** `Sources/Actions/HistoryStore.swift`.

- JSONL у `~/Library/Application Support/Jarvis/history/`, каталог 0700, файл 0600.
- Поля: час, текст команди, дія, результат, тривалість.
- **Без аудіо й без секретів.** Ротація за розміром, очищення історії.

**Тести:** права доступу, ротація, відновлення після пошкодженого рядка.

### A9. Каркас адаптера Goose (без ключа)

**Файли:** `Sources/Agent/GooseACPClient.swift`, `GooseConfig.swift`, `BudgetLedger.swift`. Спершу прочитай `docs/research/2026-11-10-goose-runtime-check.md`.

- JSON-RPC по stdio до `goose-acp`.
- Генерація заблокованої конфігурації. Клієнт **ніколи** не надсилає `allow_always`/`reject_always` і не вмикає `auto`.
- Облік `usage_update.cost`, ліміти на запит і на місяць ($10).
- Двофазне підтвердження: план, потім одноразовий токен.

**Тести:** проти локального mock, як у дослідженні. Реальний провайдер — лише коли користувач сам введе ключ (Keychain або змінна середовища, ніколи не в чат).

### A10. Ліцензії бандла (документація)

Зібрати тексти ліцензій ONNX Runtime (MIT), kaldi-native-fbank, kaldi-decoder, OpenFst, SentencePiece (Apache-2.0), kissfft (BSD-3), utf8proc (MIT). Ці бібліотеки статично лінкуються з sherpa-onnx v2.0.1.

- Поклади в `docs/licenses/`.
- Додай у `THIRD_PARTY.md` нові рядки внизу. Копіювання в бандл додасть Claude у `build.sh`.

## Потім, після узгодження з користувачем (не зараз)

- Екрани «Налаштування», «Історія», «Завдання» новими файлами.
- Onboarding дозволів (Accessibility, Automation).
- Самодостатнє пакування без `JarvisProjectRoot`. Воно зачіпає `build.sh` і `App.swift`, тож лише в координації з Claude.

## Звіт після кожного завдання

Коротко:
- змінені файли;
- які тести пройшли (команда й вивід);
- що не перевірено наживо;
- відкриті питання.

Не стверджуй, що дія працює, якщо її не запускали.
