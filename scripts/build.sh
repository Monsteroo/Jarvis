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
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/Audio.swift Tests/CaptureGateTests.swift -o .build/capture-gate-tests
.build/capture-gate-tests
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -Onone -parse-as-library Sources/Measurement.swift Tests/MeasurementTests.swift -o .build/measurement-tests
.build/measurement-tests
python3 -I -m unittest discover -s Tests -p 'test_*.py' -q
if [[ -f Sources/Benchmark.swift ]]; then
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -O -parse-as-library -import-objc-header Sources/WhisperBridge.h Sources/Benchmark.swift .build/WhisperBridge.o "${LIBS[@]}" "${FRAMEWORKS[@]}" -framework AVFoundation -lc++ -o .build/jarvis-benchmark
fi
if [[ -f Sources/App.swift ]]; then
APP="$ROOT/dist/Jarvis Voice Lab.app"
mkdir -p "$APP/Contents/MacOS"
swiftc "${SWIFT_FLAGS[@]}" -swift-version 5 -O -parse-as-library -import-objc-header Sources/WhisperBridge.h Sources/App.swift Sources/Audio.swift Sources/Measurement.swift .build/WhisperBridge.o "${LIBS[@]}" "${FRAMEWORKS[@]}" -framework AppKit -framework AVFoundation -framework Carbon -lc++ -o "$APP/Contents/MacOS/JarvisVoiceLab"
python3 - "$APP/Contents/Info.plist" "$ROOT" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump(dict(CFBundleExecutable='JarvisVoiceLab',CFBundleIdentifier='local.jarvis.voicelab',CFBundleName='Jarvis Voice Lab',CFBundleVersion='1',CFBundleShortVersionString='0.1.0',LSMinimumSystemVersion='14.0',NSMicrophoneUsageDescription='Jarvis розпізнає голос локально лише під час утримання гарячої клавіші.',JarvisProjectRoot=sys.argv[2]),f)
PY
mkdir -p "$APP/Contents/Resources"
cp "$W/LICENSE" "$APP/Contents/Resources/whisper-LICENSE"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
fi
