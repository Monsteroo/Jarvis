#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
W="$ROOT/.runtime/whisper.cpp"
mkdir -p .build dist
# Project-local workaround for overlapping CLT Swift module maps; no SDK edits.
SWIFT_FLAGS=(-module-cache-path .build/cache-fixed)
MAPDIR="$(xcode-select -p)/usr/include/swift"
if [[ -f "$MAPDIR/module.modulemap" && -f "$MAPDIR/bridging.modulemap" ]] && grep -q 'module SwiftBridging' "$MAPDIR/module.modulemap"; then
  mkdir -p .build/toolchain-fix
  : > .build/toolchain-fix/empty.modulemap
  python3 - "$MAPDIR/module.modulemap" <<'PYOVERLAY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':os.path.abspath('.build/toolchain-fix/empty.modulemap')}]},open('.build/toolchain-fix/overlay.json','w'))
PYOVERLAY
  SWIFT_FLAGS+=(-vfsoverlay .build/toolchain-fix/overlay.json -Xcc -ivfsoverlay -Xcc .build/toolchain-fix/overlay.json)
fi
cmake -S "$W" -B "$W/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$W/build" --config Release -j 4
LIBS=("$W/build/src/libwhisper.a" "$W/build/ggml/src/libggml.a" "$W/build/ggml/src/libggml-base.a" "$W/build/ggml/src/libggml-cpu.a" "$W/build/ggml/src/ggml-metal/libggml-metal.a" "$W/build/ggml/src/ggml-blas/libggml-blas.a")
# CoreGraphics: without it MTLCreateSystemDefaultDevice() returns nil in plain CLI
# processes and ggml-metal crashes in model init (Swift targets got it via AVFoundation).
FRAMEWORKS=(-framework Accelerate -framework Metal -framework Foundation -framework CoreGraphics)
clang++ -std=c++17 -O2 -mmacosx-version-min=14.0 -I"$W/include" -I"$W/ggml/include" -c Sources/WhisperBridge.cpp -o .build/WhisperBridge.o
clang++ -std=c++17 -ISources Tests/bridge_test.cpp .build/WhisperBridge.o "${LIBS[@]}" "${FRAMEWORKS[@]}" -o .build/bridge-test
.build/bridge-test
if [[ -f "$ROOT/.runtime/models/ggml-base.bin" ]]; then
  .build/bridge-test "$ROOT/.runtime/models/ggml-base.bin"
else
  echo "warning: ggml-base.bin missing; bridge model tests skipped (run scripts/setup.sh)" >&2
fi
# Unoptimised so assert() stays active.
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/Audio.swift Sources/AudioMetrics.swift Sources/WakeSupport.swift Tests/CaptureGateTests.swift -o .build/capture-gate-tests
.build/capture-gate-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/AudioMetrics.swift Tests/AudioMetricsTests.swift -o .build/audio-metrics-tests
.build/audio-metrics-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/VoiceState.swift Tests/VoiceStateTests.swift -o .build/voice-state-tests
.build/voice-state-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/Measurement.swift Tests/MeasurementTests.swift -o .build/measurement-tests
.build/measurement-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/Diagnostic.swift Tests/DiagnosticTests.swift -o .build/diagnostic-tests
.build/diagnostic-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -O -parse-as-library Sources/Parakeet.swift Tests/ParakeetTests.swift -o .build/parakeet-tests
.build/parakeet-tests
python3 -I -m unittest discover -s Tests -p 'test_*.py' -q
# Wake word: pinned sherpa-onnx v2.0.1 static libs + English KWS model (scripts/setup-wake.sh).
SHERPA="$ROOT/.runtime/sherpa-onnx-v2.0.1"
KWS="$ROOT/.runtime/kws/gigaspeech-3.3M"
if [[ ! -f "$SHERPA/lib/libsherpa-onnx-c-api.a" || ! -f "$KWS/tokens.txt" ]]; then
  echo "error: wake-word runtime missing; run scripts/setup-wake.sh" >&2
  exit 1
fi
SL="$SHERPA/lib"
WAKE_LIBS=("$SL/libsherpa-onnx-c-api.a" "$SL/libsherpa-onnx-core.a" "$SL/libkaldi-decoder-core.a" "$SL/libsherpa-onnx-kaldifst-core.a" "$SL/libsherpa-onnx-fstfar.a" "$SL/libsherpa-onnx-fst.a" "$SL/libkaldi-native-fbank-core.a" "$SL/libkissfft-float.a" "$SL/libssentencepiece_core.a" "$SL/libutf8proc.a" "$SL/libonnxruntime.a")
clang -O2 -mmacosx-version-min=14.0 -ISources -I"$SHERPA/include" -c Sources/WakeBridge.c -o .build/WakeBridge.o
clang++ -mmacosx-version-min=14.0 -ISources -I"$SHERPA/include" -x c Tests/wake_bridge_test.c -x none .build/WakeBridge.o "${WAKE_LIBS[@]}" -framework Foundation -o .build/wake-bridge-test
.build/wake-bridge-test 2>/dev/null
[[ -d .runtime/wake-fixtures/pos ]] || bash scripts/wake_fixtures.sh
# Synthetic regression gate only (system voices), not a real-voice accuracy claim.
WAKE_OUT=$(.build/wake-bridge-test "$KWS" <(printf '\xe2\x96\x81JA R VI S @JARVIS\n') 0.15 1.0 .runtime/wake-fixtures/pos/*.wav .runtime/wake-fixtures/neg/*.wav 2>/dev/null)
WAKE_POS_ALL=$(echo "$WAKE_OUT" | grep -c -E '^jarvis' || true)
WAKE_NEG_ALL=$(echo "$WAKE_OUT" | grep -c -v -E '^jarvis' || true)
WAKE_POS=$(echo "$WAKE_OUT" | grep -E '^jarvis' | awk '$2>0' | wc -l | tr -d ' ')
WAKE_NEG=$(echo "$WAKE_OUT" | grep -v -E '^jarvis' | awk '$2>0' | wc -l | tr -d ' ')
WAKE_LONG=$(echo "$WAKE_OUT" | grep -E '^jarvis-after-noise' | awk '$2>0' | wc -l | tr -d ' ')
echo "WakeFixtures: $WAKE_POS/$WAKE_POS_ALL synthetic Jarvis detected ($WAKE_LONG/3 after long noise), $WAKE_NEG/$WAKE_NEG_ALL synthetic negatives fired"
# One old robotic voice (Kathy, single word) is a known miss.
if (( WAKE_POS < WAKE_POS_ALL - 1 || WAKE_LONG < 3 || WAKE_NEG > 0 )); then echo "error: wake fixture regression" >&2; exit 1; fi
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/AudioMetrics.swift Sources/WakeSupport.swift Tests/WakeSupportTests.swift -o .build/wake-support-tests
.build/wake-support-tests
if [[ -f Sources/Benchmark.swift ]]; then
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -O -parse-as-library -import-objc-header Sources/WhisperBridge.h Sources/Benchmark.swift Sources/Parakeet.swift .build/WhisperBridge.o "${LIBS[@]}" "${FRAMEWORKS[@]}" -framework AVFoundation -lc++ -o .build/jarvis-benchmark
fi
if [[ -f Sources/App.swift ]]; then
APP="$ROOT/dist/Jarvis Voice Lab.app"
mkdir -p "$APP/Contents/MacOS"
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -O -parse-as-library -import-objc-header Sources/Bridging.h Sources/App.swift Sources/Audio.swift Sources/AudioMetrics.swift Sources/VoiceState.swift Sources/ArcRenderer.swift Sources/ArcViews.swift Sources/WakeSupport.swift Sources/WakeListener.swift Sources/Measurement.swift Sources/Diagnostic.swift Sources/Parakeet.swift .build/WhisperBridge.o .build/WakeBridge.o "${LIBS[@]}" "${WAKE_LIBS[@]}" "${FRAMEWORKS[@]}" -framework AppKit -framework SwiftUI -framework AVFoundation -framework Carbon -lc++ -o "$APP/Contents/MacOS/JarvisVoiceLab"
python3 - "$APP/Contents/Info.plist" "$ROOT" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump(dict(CFBundleExecutable='JarvisVoiceLab',CFBundleIdentifier='local.jarvis.voicelab',CFBundleName='Jarvis Voice Lab',CFBundleVersion='1',CFBundleShortVersionString='0.1.0',LSMinimumSystemVersion='14.0',NSMicrophoneUsageDescription='Jarvis розпізнає голос локально на цьому Mac: під час утримання ⌃⌥Пробіл, а якщо ви ввімкнули активацію — постійно слухає лише слово «Jarvis». Аудіо не зберігається і не надсилається.',JarvisProjectRoot=sys.argv[2]),f)
PY
mkdir -p "$APP/Contents/Resources"
cp "$W/LICENSE" "$APP/Contents/Resources/whisper-LICENSE"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
cp "$SHERPA/LICENSE" "$APP/Contents/Resources/sherpa-onnx-LICENSE"
cp "$KWS/README.md" "$APP/Contents/Resources/kws-gigaspeech-README.md"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
fi
