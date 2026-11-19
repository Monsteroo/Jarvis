# Strict wake implementation plan

Goal: implement the user-approved leading Jarvis/Джарвіс rule and launch the updated native app.
Architecture: separate strict activation from tolerant cleanup; tag confirmed separate-prefix captures; retain full active speech segment for unconfirmed KWS captures.
Constraints: uk/en only, local unsaved audio, PTT preserved, existing cancellation generations and Claude changes preserved.

- [x] Add failing negative assertions to Tests/WakeSupportTests.swift against the current stripLeadingWakeWord: “Я сказав Jarvis закрий Safari”, “Ну, Джарвіс, стоп”, ordinary first-word lookalikes and missing keyword.
- [x] Implement strict first-word parsing in Sources/WakeSupport.swift; retain old fuzzy cleanup as stripPrerollWakeWord for already confirmed captures. Cover UK/EN, punctuation, keyword alone, no-keyword follow-up cleanup, and preserved full utterance seed.
- [x] Extend WakeListener wake event with confirmed-prefix metadata. Raw KWS seed uses UtteranceSegmenter.activationSamples instead of a fixed clipped lookback; startCommand after confirmed screening marks the new capture confirmed.
- [x] Update main App integration: capture metadata with generation, require strict prefix for unconfirmed KWS before any transcript display/log/execution, preserve PTT and confirmed separate-word flow.
- [x] Run focused WakeSupportTests, full main scripts/build.sh, inspect diff and SHA-guarded integration. Record results, commit owned work, gracefully relaunch the exact rebuilt app and observe its state.
