# Пакет 1: локальні команди для Claude

Статус: реалізовано ізольовано, ще не підключено до застосунку. Гілка `codex/actions`, worktree `/Users/user/.codex/worktrees/jarvis-actions/Jarvis`.

## Що готово

- `CommandHandling` / `CommandOutcome` за контрактом docs/CHATGPT-TASKS.md.
- Типізовані дії, перевірка параметрів, UK/EN парсер (34 позитивні фрази + негативні сценарії).
- Реальний AppKit адаптер відкриття/активації/звичайного закриття програм. Синоніми UK/EN; browser — системний браузер. AppAliases зберігається/читається як JSON через явний URL від клієнта; за замовчуванням вбудовані значення. Немає force quit і shell.
- HTTP/HTTPS і пошук через default browser. Повідомлення підтверджує передання посилання браузеру, а не завантаження сторінки.
- AsyncStream прогресу, turn IDs, Task cancellation. Cancellation до системного виклику не виконує дії; після старту можливий side effect, rollback не обіцяється.
- Поточний executor для вікон/гучності/диктування повертає явне «Цю дію ще не підключено». Це наступні пакети.

## Інтеграція, яку виконує Claude

1. Перенеси коміти з codex/actions, коли зручно; не копіюй .build і runtime. Додай `Sources/Actions/*.swift` у swiftc invocation; AppKit/Foundation уже присутні. Жодної зовнішньої залежності немає.
2. На main actor створи `let handler = ActionExecutor.live()` один раз. За потреби передай `AppAliases.load(from:)` з Application Support; JSON не створюється приховано в модулі.
3. Після прийнятого ASR тексту (wake слово вже вилучене) викликай handler.handle(text, language: "uk" або "en") у Task. Збережи Task handle; cancel/mic-off/новий turn інвалідовують UI turn і викликають cancel відповідно до голосової політики.
4. `.notUnderstood` — не успіх; поки планувальника немає, покажи зрозумілий fallback. `.failed` та `.partial` не показувати як виконано. Перед кожним UI update перевір generation/turn голосового шару.
5. Для кроків: `let stream = await handler.events.subscribe()`; Task з for-await; скасувати subscriber при знищенні view/controller. Події мають окремий action turn ID: прив'яжи його до voice turn на рівні інтеграції. Не використовуй глобальні події для неконтрольованого показу старих результатів.
6. Узгодити з користувачем живий запуск. Не запускати другий app з однаковим bundle ID паралельно.

## Перевірки

Команда: `bash scripts/test-actions.sh`. Скрипт збирає лише цей модуль/тести, створює власний VFS overlay та не використовує whisper/.runtime/мікрофон. Модуль скомпільовано системним swiftc, tests із FakeWorkspace не відкривають реальні програми.

Живі AppKit side effects та підключення до голосового UI ще не перевірені. NSWorkspace callback має підтверджувати launched app; activation і quit мають bounded readback. Незбережені зміни можуть залишити програму відкритою — це повертається як помилка, не примусове закриття.

Primary API reference: https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)
