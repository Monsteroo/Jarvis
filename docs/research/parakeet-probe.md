# Локальна перевірка українського Parakeet

Дата: 2026-11-10. MacBook Air M1, 16 GB, macOS 14.5, Apple Swift 6.0.3 / Command Line Tools. Застосунок під час цього probe не змінювався.

## Модель та джерела

Перевірена [ihnatov-yuri/parakeet-tdt-0.6b-v3-uk](https://huggingface.co/ihnatov-yuri/parakeet-tdt-0.6b-v3-uk/tree/5c4bcfaca501587beaedfd23b72a678bf7194de1), повна ревізія `5c4bcfaca501587beaedfd23b72a678bf7194de1`, каталог `coreml/int8/parakeet-tdt-0.6b-v3`. Автор — ihnatov-yuri; модельна картка вказує CC BY 4.0, fine-tune NVIDIA Parakeet TDT v3 для української зі збереженням англійської. Це атрибуція моделі; розповсюдження ваг має зберігати її ліцензію.

[Модельна картка цієї ревізії](https://huggingface.co/ihnatov-yuri/parakeet-tdt-0.6b-v3-uk/blob/5c4bcfaca501587beaedfd23b72a678bf7194de1/README.md) описує FluidAudio-сумісні компоненти Preprocessor / Encoder / Decoder / JointDecisionv3. Завантажено 23 файли, близько 613 MiB. Скрипт перевіряє LFS SHA256 та Git blob SHA1 проти зафіксованого дерева і пише `.runtime/parakeet-probe/sha256-manifest.json` з SHA256 усіх файлів.

Декодування звірено з первинним кодом [FluidAudio TdtDecoderV3](https://github.com/FluidInference/FluidAudio/blob/a31f15153a9ee19d2f1b7719dc7458d1cc79de35/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtDecoderV3.swift), pin `a31f15153a9ee19d2f1b7719dc7458d1cc79de35`. FluidAudio має Apache 2.0. Probe — самостійний мінімальний Core ML виклик: blank/SOS 8192, duration bins 0…4, стан predictor змінюється тільки після nonblank. Це обмежений діагностичний greedy decoder, не повний FluidAudio pipeline.

## Фактичний результат

Вхід — вже збережений за дозволом користувача `diagnostic-09A2F1E1-B0E1-4A9E-90BB-76CE1F7C30C5.wav`: mono PCM 16 kHz, 35108 семплів, 2.19425 s. Очікуваний текст користувача: «Перемкнися на термінал».

| Режим | Завантаження | Inference 1 / 2 / 3 | Текст у всіх трьох запусках |
|---|---:|---:|---|
| CPU only | 5.336 s | 1.310 / 0.991 / 0.938 s | Перемкнись на термінал. |
| CPU + Neural Engine | 31.418 s | 2.215 / 0.986 / 0.923 s | Перемкнись на термінал. |

Завантаження ANE включає першу локальну спеціалізацію. У прогрітому стані явної переваги ANE на цьому кліпі немає. Результат семантично правильний, але не точний збіг: «Перемкнись» замість «Перемкнися». Один кліп не є повноцінною оцінкою WER або англійської. Історичні benchmark prompts та результати не змінювалися.

Всі чотири вже скомпільовані `.mlmodelc` реально завантажились на macOS 14.5: Preprocessor 0.139 s, Encoder 6.675 s, Decoder 0.089 s, Joint 0.054 s у першому окремому CPU load probe. Отже припущення, що ця конкретна int8 збірка неодмінно потребує macOS 15, спростовано виконанням.

## Мовний і приватний режим

Probe явно обирає український алфавіт і відсікає інші літери в top-64 кандидатах. Немає unrestricted language autodetection, microphone API, мережевих ASR запитів або завантаження аудіо. Мережа потрібна лише downloader для ваг. [FluidAudio language hint](https://github.com/FluidInference/FluidAudio/blob/a31f15153a9ee19d2f1b7719dc7458d1cc79de35/Sources/FluidAudio/Shared/TokenLanguageFilter.swift) обмежує **письмо**, а не конкретну мову; `.ukrainian` там означає Cyrillic. Тому probe має власний український allowlist. Спільні між мовами слова лексично не відрізнити; ця фільтрація не є доказом мовної ідентичності кожного слова.

## Відтворення

```sh
python3 scripts/parakeet_probe_download.py
scripts/parakeet_probe_run.sh "$PWD/.runtime/diagnostics/diagnostic-09A2F1E1-B0E1-4A9E-90BB-76CE1F7C30C5.wav"
scripts/parakeet_probe_run.sh "$PWD/.runtime/diagnostics/diagnostic-09A2F1E1-B0E1-4A9E-90BB-76CE1F7C30C5.wav" --ane
```

Runner компілює `scripts/parakeet_probe_infer.swift` без сторонніх пакетів, через CoreML / AVFoundation. Використовує існуючий `.build/toolchain-fix/overlay.json` для дубльованого CLT SwiftBridging modulemap. Вхід строго mono 16 kHz та максимум 15 s; довші записи потребують chunking і виходять за межі probe. Вивід містить три окремі таймінги.

Окремий `scripts/parakeet_probe_load.swift` перевіряє лише сумісність компонентів. Логи лежать у `.runtime/parakeet-probe/inference-cpu.log`, `inference-ane.log`, `load.log`.

SwiftPM залежність FluidAudio перевірялась, але цей CLT має mismatch PackageDescription інтерфейсу і dylib: undefined initializer з `swiftLanguageVersions`, а явний `swiftLanguageModes` компілятор не бачить. Локальний override private interface не усунув проблему. Це блокер SwiftPM-збірки в цьому середовищі, не моделей. Виконуваний прямий Core ML probe успішно обходить його без змін системи.
