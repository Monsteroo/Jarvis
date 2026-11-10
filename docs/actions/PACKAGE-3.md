# Пакет 3: диктування та приватна історія

Гілка codex/actions, після dca91c0. Голосові файли й загальна збірка не змінені.

## Диктування

`ActionExecutor.live()` тепер містить DictationActions з MacDictationAccess (AX). Контракт CommandHandling сумісний; додано явне передання токена цілі:

```swift
// Main actor, на початку голосового turn, ДО HUD/перемикання фокуса:
let token = try? handler.captureDictationTarget()
// Після ASR, тільки для того самого turn:
let outcome = await handler.handle(text, language: language, dictationToken: token)
// На cancel, mic-off, новому turn та завершенні:
handler.invalidateDictationTarget()
```

Не захоплюй ціль після розпізнавання. Прив'яжи UUID до voice generation, не зберігай спільний «останній токен» для довільних запитів. Відсутня доступна ціль не повинна блокувати інші команди. Старий handle(text,language:) працює для решти дій; диктування без токена відхиляється.

Токен одноразовий, дійсний 90 секунд за monotonic uptime; нове capture інвалідовує попереднє. Зберігаються конкретний AX element, процес, RAM snapshot тексту й виділення. Перед вставленням перевіряються focus, content, selection, role, subrole, enabled і settable selectedText. Поля паролів, невідомі/недоступні поля, поле Jarvis та змінена ціль відхиляються. Відсутній AX subrole теж відхиляється консервативно; деякі редактори через це не підтримуються.

Вставлення — один AXSelectedText write без клавіатурної емуляції, clipboard, Enter/Send. Unicode/UTF16 виділення перевіряється, readback повного значення має збігтися з очікуваним. Непідтверджене вставлення повертає partial; не повторюй його автоматично. Максимум snapshot 32768 UTF16 units, диктування 16000 Characters. Не показуй і не записуй snapshot поля в діагностичні журнали.

## Історія

```swift
let history = try HistoryStore() // краще створити поза UI-critical path
let handler = ActionExecutor.live(history: history)
let rows = try await history.read()
try await history.clear()
```

Історія опціональна: `live()` без аргументу не створює файлів. Claude має явно вибрати історію при bootstrap й обробити помилку створення каталогу.

Каталог: `~/Library/Application Support/Jarvis/history`, права 0700, файли 0600. JSONL містить timestamp/id, безпечну назву дії замість початкового тексту команди, status та duration. Немає параметрів, пошукових запитів, URL, диктованого тексту, довільних summary/reason або аудіо. Це свідоме приватне представлення історії, а не повний transcript.

Один actor обслуговує всі записи застосунку. Не створюй кілька незалежних HistoryStore для одного каталогу. Ротація: поточний history.jsonl і один history.1.jsonl, типовий максимум 1 MiB кожен; очищення видаляє обидва. Пошкоджені рядки пропускаються; після обірваного останнього рядка наступний запис починається з нового рядка. Немає синхронізації fsync на кожну дію: останній запис може загубитися при аварійному вимкненні.

Символічні посилання/небезпечні типи файлів відхиляються, включно з leaf log через O_NOFOLLOW; стандартні системні /var→/private/var і /tmp→/private/tmp враховано. При помилці журналу результат уже виконаної дії стає partial з поясненням проблеми історії, дія не повторюється.

## Перевірки та межі

`bash scripts/test-actions.sh`, Swift 5 mode, arm64 macOS14.5, warnings-as-errors. Нові тести перевіряють виділення й навколишній текст, token replay/expiry/supersession, втрату фокуса, зміну поля, cancel, secure/unsupported rejection, UTF16 surrogate boundaries, readback mismatch, privacy, 0700/0600, ротацію, пошкоджений/обірваний рядок, symlink rejection, executor integration та видиму помилку історії.

Живе диктування в TextEdit/браузері та UI історії не перевірено: app не запускався, дозволи не запитувались. Це модулі для підключення Claude. Нові Swift-файли треба додати в його build invocation, якщо він не використовує glob; нових frameworks понад пакет 2 немає.

API: https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute
