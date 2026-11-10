# Jarvis project instructions

- Communicate with the user in Ukrainian.
- Jarvis supports Ukrainian and English only. Do not add Russian input, output, UI, speech synthesis, recognition modes, or benchmark prompts. This supersedes the original historical research specification mentioning three languages.
- Do not enable unrestricted ASR language autodetection. Recognition adapters must explicitly constrain supported language settings to uk/en.
- Preserve historical measurements; changes to benchmark prompts require a separate versioned log so old prompt indices do not count toward new progress.
- Audio recording is push-to-talk only. Audio persistence is disabled except for explicit one-shot diagnostic opt-in. No cloud audio upload.
