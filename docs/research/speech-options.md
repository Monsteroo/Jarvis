# Local speech recognition options for Jarvis

Research date: 2026-11-07. Target: original Apple M1, 16 GB RAM, macOS 14.5, no assumed OS upgrade; push-to-talk; Ukrainian, Russian, English, including mixed-language commands. Target latency is **end of speech to observable simple action: p50 ≤1 second, p95 ≤2 seconds**. Research only: no software installed and no benchmark run.

## Decision

**Keep whisper.cpp and WhisperKit as the two implementation candidates; do not promise the latency target yet.** I found no primary-source benchmark that establishes the requested end-to-action percentiles on this exact machine/OS and language mix. Benchmark a small multilingual model in a resident process first, then a larger model if command accuracy requires it. My provisional preference is whisper.cpp + Metal for a small, explicitly controlled baseline, with WhisperKit as a serious Swift-native alternative. This preference is engineering judgment, not a demonstrated speed ranking.

Do not choose SpeechAnalyzer for the macOS 14.5 baseline. Treat SFSpeechRecognizer as an optional recognizer for individually verified locales, not the guaranteed offline trilingual path.

Both Whisper implementations use locally executed OpenAI-origin Whisper weights. They do not require an OpenAI API subscription or send audio to OpenAI merely by running inference. If “no OpenAI” means excluding model provenance as well as paid APIs, these candidates are outside scope. [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)

## Comparison

| Candidate | macOS 14.5 position | Ukrainian/Russian/English | Mixed speech | Timing evidence and decision |
|---|---|---|---|---|
| whisper.cpp + Metal | Apple Silicon and macOS supported; no macOS 26 dependency | Language table includes `uk`, `ru`, `en`; choose multilingual weights | Model limitation remains; language detection is not a code-switching guarantee | Candidate; exact action p50/p95 unknown |
| WhisperKit | Library manifest allows macOS 13; current README requires macOS 14 and Xcode 16 for development; model-specific features may require newer OS | Whisper multilingual variants available | Same underlying model caveat; no found UK/RU/EN mixed-command validation | Candidate; published streaming number is not this target metric |
| SFSpeechRecognizer | Existing Speech API; compatible architectural option | Enumerate locales and check on-device capability on the target Mac | Apple documents one language per recognizer | Optional fallback after capability/quality test; no found M1 percentiles |
| SpeechAnalyzer + SpeechTranscriber | **macOS 26+**, unavailable on 14.5 | Query model/device locale support at runtime | No verified guarantee for the requested mix | Future optional adapter only |

Sources and limits for each row follow.

## whisper.cpp

The upstream README documents Apple Silicon acceleration through Metal, ARM NEON, Accelerate, and optional Core ML. Metal handles GPU inference; Core ML can put the encoder on the Neural Engine. The advertised Core ML speedup is relative to CPU-only execution, so it does **not** establish that Core ML beats Metal on this workload. The README recommends macOS 14+ for Core ML and notes first-device-run compilation can be slow. Its illustrative memory figures are ~388 MB for base and ~852 MB for small; actual app peak use must still be measured. [README](https://github.com/ggml-org/whisper.cpp#readme)

The source language table includes English, Russian, and Ukrainian. The API exposes language autodetection, explicit language selection, initial prompts, decoding limits, callbacks, and VAD controls. These affordances make a controlled PTT pipeline possible; they do not establish accuracy or latency. Use `transcribe`, multilingual weights (not `.en`), and test language autodetection against a user-selected dominant-language hint. [Language table](https://github.com/ggml-org/whisper.cpp/blob/master/src/whisper.cpp), [API](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h)

### What the M1 evidence actually says

* The upstream benchmark issue lists an older original Mac Mini M1 with NEON/BLAS: encoder times of 194 ms (tiny), 380 ms (base), and 1,249 ms (small), commit `fcf515d`, four threads. These are **encoder measurements**, not full transcription, modern Metal results, or action latency. They demonstrate why a model name plus “M1” is insufficient evidence. [Benchmark issue #89](https://github.com/ggml-org/whisper.cpp/issues/89)
* The benchmark implementation initializes synthetic mel/token inputs, warms up, and measures encoder/decoder operations. It does not capture a microphone utterance and execute an action. Do not add or divide its columns to invent PTT p95. [Benchmark source](https://github.com/ggml-org/whisper.cpp/blob/master/examples/bench/bench.cpp)
* A first-person upstream issue reports Apple M1, 8 GB, macOS 26.6.2, `tiny-q5_1`, four 14-second clips after warmup: 1.14 seconds total at default audio context, but 13.79 seconds at context 640. This is useful evidence that backend/context choices can radically change timing. It is an uncontrolled issue report on a different OS/RAM/model workload, with no command accuracy, per-clip percentiles, or action measurement. It cannot establish the target. [Issue #4075](https://github.com/ggml-org/whisper.cpp/issues/4075)
* Another upstream report includes actual 11-second JFK input on M1 with large-v3/Core ML: ~8.63 seconds total and incorrect output. This 2024 failure report is evidence of that configuration's failure, **not** a representative current benchmark or reason to reject all Core ML. [Issue #1901](https://github.com/ggml-org/whisper.cpp/issues/1901)

**Unknown:** current pinned whisper.cpp + Metal base/small/turbo performance, short-command accuracy, and end-to-action p50/p95 on this user's M1/16GB/macOS14.5.

## WhisperKit: separate library, toolchain, and model compatibility

The upstream repository now redirects from `argmaxinc/WhisperKit` to `argmaxinc/argmax-oss-swift`. Its current manifest uses Swift tools 5.10 and macOS 13 as the package deployment floor. Its README lists macOS 14+ and Xcode 16+ as development prerequisites. Those statements describe different things; neither means every downloadable model or optimization runs on macOS 13. [Manifest](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Package.swift), [README](https://github.com/argmaxinc/argmax-oss-swift#readme)

**Xcode 16 is not itself an OS-upgrade blocker here:** Apple's table lists Xcode 16, 16.1, and 16.2 as supported on macOS Sonoma 14.5; Xcode 16.3 requires macOS 15.2. Select an explicitly compatible toolchain, not “latest Xcode.” [Apple Xcode requirements](https://developer.apple.com/xcode/system-requirements)

For a historical compatibility reference, WhisperKit v0.9.0's manifest uses Swift tools 5.9, macOS 13, and exact dependency versions; its README lists Xcode 15/macOS14. This is a known documented baseline, **not** a recommendation to freeze an old version without evaluating fixes and model compatibility. [v0.9.0 manifest](https://github.com/argmaxinc/WhisperKit/blob/v0.9.0/Package.swift), [v0.9.0 README](https://github.com/argmaxinc/WhisperKit/blob/v0.9.0/README.md)

Current source provides selectable compute units; the encoder defaults to CPU/Neural Engine on macOS14+ and CPU/GPU on older versions, while the decoder defaults to CPU/Neural Engine. The enum distinguishes multilingual and English-only models. That is directly useful for implementation comparison. [Model/compute source](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Models.swift)

### The 0.46-second claim is not a latency promise for Jarvis

The Argmax-authored WhisperKit paper reports roughly 0.45–0.46-second **mean per-word hypothesis latency** in streaming TIMIT evaluation; confirmed-text latency is approximately 1.7 seconds. Hypothesis text may be revised. Neither statistic is a post-utterance action p50/p95 or a UK/RU/EN code-switching test. Its optimization discussion explicitly measures some decoder work on M3 ANE, not this M1 target. [WhisperKit paper, sections 2.2 and 3.1](https://arxiv.org/html/2507.10860v1)

The paper also uses Core ML stateful-model optimizations. Apple says that capability starts in macOS15/iOS18. **Inference:** those optimizations cannot simply be assumed on macOS14.5 even though the library has an older deployment target. Choose compatible model artifacts and measure the actual deployed path. [Apple stateful-model documentation](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)

Argmax publishes a reproducible benchmark procedure and links its results dataset/dashboard. The dashboard's dynamic content and dataset were not fully inspectable in this research. I did not find verified original-M1 short mixed-language command percentiles there and do not infer them from throughput. [Benchmark instructions](https://github.com/argmaxinc/argmax-oss-swift/blob/main/BENCHMARKS.md), [dashboard](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks)

## Languages versus code switching

A multilingual model supporting three languages does not guarantee switching among them inside one utterance. Whisper maintainer Jong Wook Kim's answer says the model was intended for monolingual inputs and does not handle code switching well. This is a historical model-family limitation, not a measured verdict on every newer turbo/model variant; it demands a dedicated test. [Maintainer answer](https://github.com/openai/whisper/discussions/1160)

For Jarvis, test both full-language switching between commands and switching within a command, especially English application/project names embedded in Ukrainian or Russian. Examples: “відкрий Chrome”, “найди файл invoice”, and longer mixed clauses. Record exact command/argument success, not just average WER. An apparently minor substitution in an app name or negation can be a failed command even when WER is low. These are proposed acceptance cases, not findings from a published dataset.

## Apple SFSpeechRecognizer

Apple explicitly documents **one language per recognizer**, selected at initialization, and says some languages may need internet. Check supported locales, actual returned locale, availability, and on-device capability for `uk-UA`, `ru-RU`, and an English locale on the user's Mac. Do not assume the supported-locale list means all three work offline, or that running three recognizers automatically solves mixed speech. [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer?changes=_2), [locale initialization](https://developer.apple.com/documentation/speech/sfspeechrecognizer/init(locale:))

A request can honor `requiresOnDeviceRecognition` only when `supportsOnDeviceRecognition` is true. For a local-only implementation, check capability first and fail into an explicit alternate local engine if absent; setting the request flag alone is insufficient evidence of offline support. [Apple on-device capability documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)

No primary-source original-M1/macOS14.5 end-of-command p50/p95 or verified offline Ukrainian/Russian/English code-switching result was found. Advantage: system integration without shipping Whisper models. Limitation: locale/assets/service behavior are not controlled by the app to the same degree as bundled model inference. The advantage/limitation assessment is engineering judgment based on the documented capability model.

## Apple SpeechAnalyzer / SpeechTranscriber

Apple's DocC metadata identifies **macOS26.0** as the introduction version for both APIs. They cannot be the baseline while the user remains on 14.5. [SpeechAnalyzer metadata](https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json), [SpeechTranscriber metadata](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json)

Apple describes the newer on-device model as faster and better suited to long/distant conversational audio than the older recognizer. Its documented API includes runtime device availability, supported/installed locale checks, and managed model assets. Do not confuse the documentation page's `availableLanguages` field (documentation translations) with supported recognition languages. No static UK/RU/EN mixed-language guarantee or target M1 percentile was established. [Apple WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)

## Initial model shortlist (proposed, not benchmarked)

* **Multilingual `base`**: first low-latency baseline; retain only if command/entity accuracy is acceptable.
* **Multilingual `small`**: main accuracy-versus-latency competitor. Compare the same model family across whisper.cpp Metal and WhisperKit to avoid attributing model differences to runtime differences.
* **`large-v3-turbo`**: quality-oriented third candidate after confirming the exact Core ML artifact works on macOS14.5; for whisper.cpp start with a documented quantized artifact if memory is a concern. No claim that turbo will meet the budget.

These are experiment choices, not a measured ranking. Tiny can be a capture/integration smoke-test model, but should not be chosen merely because it is fastest.

## Proposed acceptance experiment (not executed)

1. Pin engine commit/release, model hash, quantization, compute units, OS, and compiler. Compare whisper.cpp Metal and WhisperKit using comparable multilingual base/small models; include a quality-oriented turbo variant only if compatible and resources permit.
2. Keep model/context resident; distinguish first download/compile, cold app start, warmed first command, and sustained warmed use. Model-loading time must not be hidden if it occurs in the actual user path.
3. Use the same prerecorded 1–8-second commands plus live PTT trials: each language, mixed clauses, English entity names, silence/noise, and negations. Include realistic concurrent apps to expose unified-memory/compute contention.
4. Timestamp actual end of speech, key release, final accepted transcript, intent result, action dispatch, and observable action completion. Report speech-to-release delay separately so PTT does not mask the metric. Interim text is useful UI feedback but does not equal safe command commitment.
5. Report p50/p95 across enough repeated trials to characterize tails, by language and mixed-speech group; include errors/timeouts instead of dropping them. Report command/argument success alongside latency. Reserve part of the 1s/2s budget for parsing and action execution.
6. If final-only batch decoding misses the target, evaluate incremental decoding during PTT with finalization on release; measure accuracy regressions and total power. If local recognition cannot achieve both quality and timing, present that measured tradeoff before selecting a cloud fallback.

This experiment is the missing decision evidence. Published encoder speed, long-file real-time factor, and interim-word mean latency cannot replace it.
