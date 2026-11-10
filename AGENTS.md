# Jarvis project instructions

- Communicate with the user in Ukrainian.
- Jarvis supports Ukrainian and English only. Do not add Russian input, output, UI, speech synthesis, recognition modes, or benchmark prompts. This supersedes the original historical research specification mentioning three languages.
- Do not enable unrestricted ASR language autodetection. Recognition adapters must explicitly constrain supported language settings to uk/en.
- Preserve historical measurements; changes to benchmark prompts require a separate versioned log so old prompt indices do not count toward new progress.
- Voice activation by the code word “Jarvis” is an authorized product requirement. Use an explicitly enabled local wake detector, with visible microphone-off control and PTT fallback. This supersedes the original PTT-only requirement.
- Audio persistence is disabled except for explicit one-shot diagnostic opt-in. No cloud audio upload.
- For product scope, voice interaction or UI work, read docs/superpowers/specs/2026-11-10-jarvis-v0.1-design.md. The user approved the 10–11-day schedule and ARC Current visual direction (docs/design/jarvis-arc-current.png): horizontal luminous voice filaments and neural impulses, not a spherical core.
