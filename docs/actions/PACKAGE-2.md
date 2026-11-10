# Пакет 2: вікна та вихідний звук

Дата: 10 листопада 2026. Гілка codex/actions. Цей пакет продовжує aa99ea8.

## Реалізовано

- WindowActions: minimize, maximize до робочої області екрана, ліва/права половина. Accessibility permission перевіряється без автоматичного prompt. Перед дією перевіряються settable attributes. Після — readback з допуском 3 px і bounded wait. Часткові зміни/скасування після запису не позначаються успіхом.
- MacWindowAccess: одне конкретне focused AX window утримується протягом дії; target не змінюється після await. Jarvis не керує власним вікном. Повноекранне вікно відхиляється. Вибір екрана за найбільшим перетином, AppKit→AX координати враховують primary origin і visibleFrame (Dock/menu bar).
- AudioOutputActions: відсоток, крок гучності зі збереженням різниці каналів, mute/unmute. Підтримка CoreAudio master або всіх доступних output channels після preflight. Відмова, якщо пристрій не підтримує програмне керування. Поточний default output перевіряється перед кожним записом і після дії; readback tolerance 0.015.
- ActionExecutor.live() підключає обидва адаптери. Раніше створені ActionExecutor(workspace:) лишаються сумісними; за потреби тести передають windows/audioOutput явно.

Brightness/Focus не реалізовані, приватні API й shell не використовуються. Зміна рівня гучності не знімає mute автоматично. Dictate ще не підключено.

## Підключення Claude

1. Перенести коміт цього пакета після aa99ea8. Додати нові WindowActions.swift і AudioOutputActions.swift до swiftc invocation, якщо не використовується glob Sources/Actions/*.swift.
2. Додати `-framework ApplicationServices -framework CoreAudio` до загального app build. AppKit/Foundation уже потрібні пакету 1.
3. Використовувати наявний ActionExecutor.live(); голосові файли цей пакет не змінює.
4. Потрібно, щоб цільова програма була frontmost при handle: HUD не повинен забирати фокус. Якщо головне вікно Jarvis активне, керування чужим вікном відхиляється, а не вгадує попередню ціль. Майбутній FocusTarget поліпшить це для диктування.

## Перевірено

`bash scripts/test-actions.sh`: 70 перевірок попереднього пакета + 30 перевірок пристроїв/вікон. Тести збираються під arm64 macOS 14.5, Swift 5 mode, warnings-as-errors, з локальним overlay.

Нові тести: кілька екранів, робоча область, відсутній AX-дозвіл, preflight без побічних ефектів, constrained resize, збій другого запису, зміна audio device, partial channel write, readback mismatch, clamping, mute, precancel і routing через executor.

НЕ перевірено наживо: реальне AX-вікно, built-in/Bluetooth/HDMI output, зміна route під час дії, затримка readback CoreAudio. Fake backend тести не доводять поведінку цих пристроїв. Без узгодженого вікна тестування не запускав застосунок, не відкривав permission prompt і не змінював гучність.

## Джерела API

- https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
- https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertymute
- https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyvolumescalar
