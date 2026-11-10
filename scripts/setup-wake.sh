#!/bin/bash
# Downloads the pinned wake-word runtime into .runtime/ and verifies SHA-256.
# sherpa-onnx v2.0.1 (Apache-2.0) static libs without TTS, its C API header,
# and the English KWS model sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
# (model README: Apache License 2.0).
set -euo pipefail
cd "$(dirname "$0")/.."
REL=https://github.com/k2-fsa/sherpa-onnx/releases/download
RAW=https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1
DL=.runtime/wake-download
SHERPA=.runtime/sherpa-onnx-v2.0.1
KWS=.runtime/kws/gigaspeech-3.3M
mkdir -p "$DL/lib" "$DL/kws" "$DL/src"

fetch() { # url file sha256
  if [[ ! -f "$2" ]] || ! echo "$3  $2" | shasum -a 256 -c --status; then
    curl -fsSL --retry 3 -o "$2" "$1"
  fi
  echo "$3  $2" | shasum -a 256 -c
}

fetch "$REL/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-static-no-tts-lib.tar.bz2" "$DL/lib/lib.tar.bz2" \
  69413605e7d0d1286d40fbf66e898f7abb53f350d6057cbd154ea2e3f1437d2a
fetch "$REL/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2" "$DL/kws/kws.tar.bz2" \
  f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
fetch "$RAW/sherpa-onnx/c-api/c-api.h" "$DL/src/c-api.h" \
  5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
fetch "$RAW/LICENSE" "$DL/src/LICENSE" \
  cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

rm -rf "$SHERPA" "$KWS" "$DL/x"
mkdir -p "$SHERPA/include/sherpa-onnx/c-api" "$KWS" "$DL/x/lib" "$DL/x/kws"
tar -xjf "$DL/lib/lib.tar.bz2" -C "$DL/x/lib"
tar -xjf "$DL/kws/kws.tar.bz2" -C "$DL/x/kws"
cp -R "$DL/x/lib/sherpa-onnx-v2.0.1-osx-arm64-static-no-tts-lib/lib" "$SHERPA/lib"
cp "$DL/src/c-api.h" "$SHERPA/include/sherpa-onnx/c-api/c-api.h"
cp "$DL/src/LICENSE" "$SHERPA/LICENSE"
cp -R "$DL/x/kws/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01/." "$KWS/"
rm -rf "$DL/x"
echo "wake runtime ready: $SHERPA, $KWS"
