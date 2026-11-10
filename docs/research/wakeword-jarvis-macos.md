# Точне wake word «Jarvis» у native macOS Jarvis

Дата перевірки: 2026-11-10. Ціль: M1, 16 GB, macOS 14.5, Swift 6.0.3/CLT; реліз за 10–11 днів. Це дослідження, інтеграцію та мікрофон не запускали. Поточна явна вимога користувача дозволяє opt-in голосову активацію; вона має бути зафіксована як виняток до старого PTT-only правила перед реалізацією. Аудіо лишається в RAM локально, без запису/хмарного upload за замовчуванням; команди та UI — лише uk/en.

## Рішення

**Основний кандидат — sherpa-onnx English KWS Zipformer 3.3M, int8, точний keyword `JARVIS`, native Swift/C.** Це найкоротший незалежний від акаунтів шлях до потрібного слова: open-vocabulary KWS приймає нове слово через keyword-файл без нового навчання. Це спеціалізований маленький streaming transducer з обмеженим декодером, а не постійний запуск ParakeetUK. Точність саме «Jarvis» та українського акценту треба виміряти, а не вважати доведеною. [Механізм KWS](https://k2-fsa.github.io/sherpa/onnx/kws/index.html).

**Porcupine — технічно швидкий запасний кандидат, якщо вже є придатний AccessKey/договір і допустима мережева перевірка ліцензії.** Готове слово `jarvis_mac.ppn` є в офіційному дереві, отже custom training для англійського Jarvis не потрібен. Однак це не безумовно offline-продукт і не готовий macOS Swift package. **openWakeWord не брати основою цього релізу:** офіційний preset — «hey jarvis», а exact «jarvis» потребує окремого навчання/валідації й додаткового native port. [Модель Porcupine](https://github.com/Picovoice/porcupine/blob/master/resources/keyword_files/mac/jarvis_mac.ppn), [картка openWakeWord](https://github.com/dscripka/openWakeWord/blob/main/docs/models/hey_jarvis.md).

## Порівняння

| Критерій | sherpa-onnx | Porcupine | openWakeWord |
|---|---|---|---|
| Точне «Jarvis» | Новий `JARVIS` keyword, без training | Готовий `jarvis_mac.ppn` | Preset `hey_jarvis`; автор попереджає про більші пропуски для самого jarvis |
| macOS ARM | Офіційна підтримка; native xcframework/Swift/C | Офіційний macOS arm64 native engine; C API | Python pipeline, ONNX можливий; Swift inference pipeline треба переносити |
| Ключ/мережа | Не потрібні для локального inference | AccessKey обов’язковий; licensing validation залежить від мережі/плану | Локальний inference без ключа |
| Ризик строку | Пакування binary + threshold tuning | Ключ, trial/договір, native C bridge | Exact-word training, packaging Python або перенос feature pipeline |

Підтвердження платформ: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), [Porcupine](https://picovoice.ai/docs/porcupine/). Таблиця оцінює інтеграційний ризик, не доведену перевагу точності.

## sherpa-onnx: конкретний шлях

- Поточний офіційний `Package.swift`: Swift tools 5.9, `.macOS(.v10_15)`, native macOS static/shared xcframework v2.0.1; ONNX Runtime dependency exact 1.28.2. Swift 6.0.3 достатній для manifest, але deployment metadata самих binary slices і реальне linking на macOS14.5 треба перевірити smoke build. Зафіксувати tag/commit і checksum, не залежати від рухомого `master`. [Manifest](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift), [ORT manifest](https://github.com/csukuangfj/onnxruntime-libs/blob/master/Package.swift).
- Взяти **English-only** `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01`, не zh/en варіант. Офіційна документація містить fp32/int8 encoder/decoder/joiner, `tokens.txt`, `bpe.model`; int8 neural files сумарно приблизно 5 MB за наведеним listing, без runtime. Це розмір файлів, не RAM/CPU. [Артефакти й BPE інструкція](https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html#sherpa-onnx-kws-zipformer-gigaspeech-3-3m-2024-01-01-english).
- Згенерувати keyword-файл з `JARVIS` через офіційний text2token і **той самий** bpe.model; не вгадувати BPE токени вручну. Пакувати готовий keyword-файл, Python не потрібен у застосунку. Підібрати boosting score, acoustic threshold, trailing blanks на окремій calibration вибірці. [Формат](https://k2-fsa.github.io/sherpa/onnx/kws/index.html).
- Swift приклад використовує `SherpaOnnxKeywordSpotterWrapper`, 16kHz mono Float32, `acceptWaveform`, `isReady/decode`, `getResult().keyword`, негайний `reset()` після спрацювання. Замінити читання файлу на власний AVAudioEngine pipeline; декодування не виконувати на realtime audio callback. Почати з CPU одного потоку. [Офіційний Swift приклад](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/keyword-spotting-from-file.swift).
- Код sherpa-onnx має Apache-2.0. Для **конкретних weights** треба зберегти README/license з офіційного tarball і notices. Є відкритий upstream запит щодо ліцензій KWS; коментар повідомляє `license: Apache License 2.0` у GigaSpeech README, але коментар стороннього користувача не замінює прямого огляду артефакту. Локальне завантаження в цій сесії зупинилося на DNS; redistribution weights наразі **не перевірено**. Це packaging gate перед публічним bundle, не причина блокувати локальний технічний spike. [Ліцензія коду](https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE), [upstream issue #3802](https://github.com/k2-fsa/sherpa-onnx/issues/3802).

## Porcupine: важливі обмеження

Native macOS arm64 підтримується; готовий `jarvis_mac.ppn` означає точний preset без «Hey». Custom `.ppn` моделі генеруються в Console, platform-specific, зазвичай за секунди; для української вимови саме цього англійського імені немає перевірених метрик. [Платформи/custom models](https://picovoice.ai/docs/porcupine/).

Офіційний Swift SPM package названий `Porcupine-iOS`, має тільки iOS16 та iOS xcframework; його не можна представляти як готову native macOS Swift інтеграцію. Для Mac використати arm64 native library через modulemap/C wrapper. C API приймає mono PCM Int16, `pv_sample_rate()` і `pv_porcupine_frame_length()` визначають формат/розмір кадру; `pv_porcupine_process` повертає keyword index. Не хардкодити ABI: поточний init має також аргумент `device`. Мінімальну macOS версію binary не підтверджено документацією; потрібен `vtool/otool` та linking smoke test. [SPM manifest](https://github.com/Picovoice/porcupine/blob/master/Package.swift), [C header](https://github.com/Picovoice/porcupine/blob/master/include/pv_porcupine.h).

Не використовувати старі твердження про безкоштовний personal tier: актуальний FAQ каже enterprise Free Trial, без personal/noncommercial планів; trial одноразовий, не подовжується автоматично; Porcupine обліковується за monthly active users. Публічний pricing page не надав читабельної ціни; конкретні суми/ліміти/право розповсюдження уточнюються в Console/договорі, тому **$0 для релізу не підтверджено**. Apache LICENSE репозиторію не доводить відсутність умов для proprietary engine/AccessKey. [Поточний FAQ](https://picovoice.ai/docs/faq/general/), [pricing](https://picovoice.ai/pricing/).

Офіційний Picovoice cookbook, включно з macOS wake-word recipe, прямо вказує потребу мережі для AccessKey validation при локальному inference. Аудіо може лишатися локальним, проте це не гарантія запуску на чистому offline Mac. Частота перевірки, кеш/grace period та поведінка після завершення trial не доведені; для вимоги повної незалежності від мережі це blocker до письмового підтвердження offline ліцензії. [Офіційний wake-word recipe](https://github.com/Picovoice/pico-cookbook/tree/main/recipes/personalized-wake-word/python).

## openWakeWord: чому не основний шлях

Автор прямо описує модель як «hey jarvis» і попереджає про підвищені пропуски самого jarvis. Навчання custom model можливе, але демонстраційне «менше години» не гарантує якість exact Jarvis, українського акценту чи готовність до shipping. Вбудовані pretrained weights — CC BY-NC-SA4.0, код Apache2.0; нова classifier head не автоматично усуває ліцензійні умови успадкованих pretrained feature models. [README](https://github.com/dscripka/openWakeWord), [картка](https://github.com/dscripka/openWakeWord/blob/main/docs/models/hey_jarvis.md).

Пайплайн має mel-spectrogram → embeddings → classifier, стандартні кадри кратні 80ms. Поточний `setup.py` уже згадує ai-edge-litert для Darwin, ORT, Python>=3.10; тому твердження «на macOS ARM завжди неможливо встановити tflite» застаріле як універсальна теза. Водночас історичний v0.6.0 і рухомий main можуть мати різні dependency sets; wheel compatibility без встановлення не перевірена. Для native Swift доведеться відтворити feature/window/buffer state та ORT/CPU inference. [Dependency source](https://github.com/dscripka/openWakeWord/blob/main/setup.py).

## Запропонований контракт застосунку

Це проєктна рекомендація: один AVAudioEngine після явного opt-in і microphone permission → downsample mono16k → короткий bounded RAM ring buffer → small KWS. Стан `armed` показується в меню; toggle повністю припиняє microphone capture. Trigger → chime/індикатор → bounded command capture/VAD → локальний ParakeetUK → виконання; після відповіді reset і повернення в armed. PTT зберігається як доступний режим. Під час власного TTS wake detector призупиняється, щоб не активувати себе; barge-in не входить у перший реліз. До Parakeet передавати невеликий RAM overlap після keyword boundary, щоб не зрізати перший склад команди. Жодних auto-start, audio files, transcript logs або cloud ASR за замовчуванням; дозволені мови ASR явно uk/en без unrestricted autodetection.

## Gate вимірювань: `wake-jarvis-v1`

Новий окремий versioned log, не змішувати з історичними ASR prompt indices. Нижче **цілі**, а не результати. Реальний mic capture тут не виконувався; файлова діагностика можлива лише з окремим одноразовим opt-in.

1. Smoke build/launch на M1/macOS14.5/Swift6.0.3, потім cold offline launch; зафіксувати версії, hashes, binary minOS/arch, load errors, RAM/CPU. Запустити потім 2h без витоку пам’яті; бажані приріст RSS <150MB, середня CPU <5% одного ядра, p95 callback work <5ms (декодування поза callback).
2. Calibration і held-out test окремо. 200 positive live attempts мінімум: 5 людей × 40, український/англійський акцент, 0.5/1/3m, quiet/fan/keyboard/music; лише «Jarvis», також immediate command та паузи 0/150/500ms. Тест «Hey Jarvis» окремий, не зараховувати замість exact word. Цілі recall ≥95% quiet/near, ≥90% combined; публікувати кожну умову та n, без узагальнення на всіх мовців.
3. Негативна вибірка ≥10h: UK/EN розмови, музика/відео, клавіатура, тиша, схожі слова «service», «harvest», «джаз», власний TTS. Логувати лише час/score/стан/лічильники. Ціль ≤0.1 false wakes/hour; 0/10h дає лише приблизну 95% верхню межу 0.3/h за правилом 3/T, тому це screening, не доказ FAR≤0.1/h. Для такого доказу потрібно приблизно 30h без false wakes.
4. Latency від кінця вимовленого слова до chime/command-ready: median≤250ms, p95≤500ms; окремо виміряти command-start clipping, false duplicates (cooldown2s як стартова policy), end-to-end ASR delay. Для часової розмітки використовувати synthetic/local fixture або окремий opt-in, а не прихований запис.
5. Відмова доступу до mic, sleep/wake, bluetooth/device switch, toggle off, quit, модель відсутня/зіпсована; engine не повинен залишати невидимий capture. Не виконувати дію лише від wake word: помилкове спрацювання з порожньою командою закривається тайм-аутом.

Timebox: 1 день на sherpa native file-fixture smoke і exact keyword; ще 1 день на live quality gate після дозволеної інтеграції. Якщо exact Jarvis не проходить, показати виміри й вибір: tuning/цільове навчання або Porcupine з придатною ліцензією. Не підміняти непомітно вимогу «Jarvis» на «Hey Jarvis».
