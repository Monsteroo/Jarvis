# Wake word «Jarvis»: check on the user's real voice

Date: 10 November 2026. Machine: MacBook M1, built-in microphone path through the app's 16 kHz converter. sherpa-onnx v2.0.1.

## Why

The user reported that voice activation barely reacts to them. The detector had been tuned only on synthetic macOS voices.

## Data

The user explicitly opted in to one one-shot diagnostic WAV of 14.9 s. It holds 6 short utterances of «Джарвіс»/«Jarvis» and 3 ordinary phrases without the keyword.

- Speech peaks were −7 to −11 dBFS against a −56 dB room floor, so input level is not the problem.
- The audio stays local in `.runtime/diagnostics/` and is not committed. Only the numbers below are kept.

The sample is small: 6 positives from one speaker. These numbers are a direction, not an accuracy claim.

## What the models hear

Each model was run as a plain English recognizer (beam search) to see what tokens it decodes.

**gigaspeech KWS 3.3M (previous):**
- `JO B BER S`, `JA R DI S`, `JO H N IV IST S`, `JO T T O S`, `JA R DI S`, `G AR RI S`.
- The Ukrainian-accented «в» is heard as D/R/B, so the single keyword `▁JA R VI S` matches once.

**streaming zipformer en-2023-06-26, int8 (~70M):**
- `JA R S`, `JA R S`, `JA R V IS`, `JA R V IS`, `JA R S`, `JA R S`. This is consistent.

**streaming zipformer en-20M-2023-02-17:** decoded garbage on these clips, so it was rejected.

## Keyword-spotter results

Keyword `▁JA R V IS`, score 1.0. "User positives" are the 6 utterances; "user negatives" are the 3 phrases. The synthetic sets come from `scripts/wake_fixtures.sh`.

| Model | Threshold | User positives | User negatives fired | Synthetic positives | Synthetic negatives fired |
|---|---|---|---|---|---|
| gigaspeech 3.3M (`▁JA R VI S`) | 0.10–0.15 | 1/6 | 0/3 | 16/17 | 0/25 |
| en-2023-06-26 | 0.05–0.25 | 5/6 | 0/3 | 16/17 | 0/25 |

Adding misheard spellings (`JA R DI S`, `G AR RI S`, …) to the 3.3M model reached 4/6. It was rejected because those spellings were fitted to the same six clips.

## Long listening and cost

Single stream, en-2023-06-26:

- The keyword fires after 600 s of room-like noise.
- In a 205 s file with 60 s of silence and noise between occurrences, it fires 3/3.
- The two staggered streams that the 3.3M model needed are therefore removed. As a precaution, the stream is still renewed every 600 s.

CPU (user time ÷ audio time, one core, M1) and memory:

| Configuration | CPU | Max RSS (test tool) |
|---|---|---|
| 3.3M, two streams | ≈4.3 % | 89 MB |
| en-2023-06-26, two streams | ≈12.8 % | 241 MB |
| en-2023-06-26, one stream | ≈6.7 % | — |

## Follow-up: live misses, held-out check

The user reported that the first switch was much better but still missed sometimes. They then made two more one-shot recordings:

- **Positives:** 7 «Джарвіс» + command utterances, varied in speed and distance. The model mostly decodes the word as `JA R S`.
- **Negatives:** 13 s of ordinary speech with similar words («Ярослава», «Harvard», «Jacques»).

Settings were first explored on the first recording, then checked on these held-out clips. Keyword `▁JA R V IS`, score 1.0.

| Search paths | Threshold | Held-out positives | Held-out negatives fired | First recording | Synthetic positives | Synthetic negatives fired |
|---|---|---|---|---|---|---|
| 4 | 0.15–0.25 | 5/7 | 0/5 | 5/6 | 16/17 | 0/25 |
| 8 | 0.15 | 6/7 | 0/5 | 6/6 | 16/17 | 0/25 |
| 8 | 0.25 | 6/7 | 0/5 | 6/6 | 15/17 | 0/25 |
| 4 + `▁JA R S` | 0.25 | 7/7 | 1/5 | 6/6 | 16/17 | 1/25 |

Notes:
- 16 paths behaves like 8.
- A higher keyword score lowered recall.
- `▁JA R S` was rejected because it fires on ordinary speech.

CPU over 829 s of audio is ≈6.6 % with 4 paths and ≈6.8 % with 8.

**Applied:** 8 paths, threshold 0.15. That is 12/13 real-voice hits and 0 false fires on the user's ordinary speech. It is still a small sample from one speaker.

## Decision

Switch to en-2023-06-26:

- one stream;
- keyword `▁JA R V IS`;
- threshold 0.25 at first, then 0.15 with 8 search paths (see Follow-up);
- downloads pinned to the Hugging Face commit `672fbf1b` with SHA-256 in `scripts/setup-wake.sh`.

Open:
- a live in-app test by the user;
- a real-voice false-trigger check over normal room speech and media;
- a larger and more varied positive sample.

## Follow-up 2: natural speech, Parakeet screening (user decision)

On «Джарвіс відкрий термінал» spoken in one breath, the keyword spotter fired on few phrases. A fourth one-shot recording (5 commands, no pause after the keyword) showed why: the English model decodes the word as `JA R S`, `JO T TER`, `JO H N`, `THE JA H` or `JU D AS`. On the same clips the spotter fired 1/5.

Parakeet (uk) on the same segments heard the keyword 5/5: «Джарельс», «Джарві», «Джаррі», «Джарвіс» ×2. On 8 phrases without it there were 0 false matches.

The user accepted the privacy trade-off: every speech segment near the mic is transcribed locally and discarded unless it starts with the wake word. Implementation:

- `UtteranceSegmenter`: segments close after 0.7 s of silence, 12 s maximum, 0.4 s preroll.
- `LocalSpeech.screen`: does not touch turn generations.
- `WakeText` fuzzy match on the first three words.
- If the keyword is said alone, the next phrase is recorded as the command.
- The keyword spotter stays as an early hint and is de-duplicated against screened segments.

Offline, on the full recordings through segmenter → Parakeet → decision:

| Input | Result |
|---|---|
| Natural commands | 5/5 became commands |
| Keyword alone | 10/10 waited for a command |
| Negative segments (ordinary speech, similar words) | 0 fired |

Known limit: two commands with almost no pause between them merge into one segment.

Live, 10 November 2026: 6/6 phrases reached a command (4 by screening, 2 by the spotter first). Warm screening ASR took 0.36–0.48 s; the first cold run took 3.5 s. The user confirmed: «Тепер працює».

## Follow-up 3: acknowledgment cue, cold start, continuous speech

**Acknowledgment cue.** A 0.16 s two-tone cue (G6 → C7, sin² envelope) is synthesised in memory and played when a command starts. It can be switched off in «Діагностика». The cue was mixed into recorded commands at offsets of 0.3 and 0.9 s, at up to 0.9× the speech peak:
- 2 synthetic English commands were unchanged;
- 4 of the user's commands: 3 were unchanged. In one, a cue overlapping the keyword itself changed «Джаррі» to «Джарю», which is still matched as the keyword.

In the app the cue plays only after the keyword was recognised, so it does not overlap the keyword.

**Cold first recognition.** The earlier warm-up used silence. Parakeet's energy check returns early on silence, so the models never ran. With pages evicted, the first real pass took 5.7 s and the second 1.8 s (synthetic 3.4 s command, one process). The app now runs one throwaway pass on a quiet 1 s tone right after the model loads. In the app that pass took 4.2 s at launch. The user then tested live: the first command after launch was recognised with ASR 0.32 s.

**Continuous speech near the mic (live, built-in speakers at full volume, activation on).** Measured with `say`: Lesya (uk) and Samantha (en), news-style text with similar words such as «Ярослава», «Гарвард», «Джексон», Harvard, Harvey, Travis.

| Condition | Jarvis CPU (one core) | False activations |
|---|---|---|
| Quiet room, 20 s | ≈13 % | — |
| Continuous speech, 93 s | ≈16 % | 0 |

Resident memory was 1.3 GB with Parakeet loaded on CPU.

The app had no trace during this run, so the same audio was replayed offline through `UtteranceSegmenter` and Parakeet:
- continuous synthetic speech closes segments only at the 12 s limit, giving 5 segments for 56 s;
- 0/5 segments matched the keyword;
- warm screening took 3.4 s CPU in total, ≈6 % of one core.

Known limit: a keyword said in the middle of a long screened segment is not a command for screening, because only the first three words count. The keyword spotter is still the fallback for that case.

Not measured yet:
- real TV or video audio over a longer period;
- several speakers in the room.
