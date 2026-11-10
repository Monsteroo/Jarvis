#!/bin/bash
# Downloads the pinned wake-word runtime into .runtime/ and verifies SHA-256.
# sherpa-onnx v2.0.1 (Apache-2.0) static libs without TTS, its C API header,
# and the English streaming zipformer sherpa-onnx-streaming-zipformer-en-2023-06-26
# (icefall LibriSpeech, ~70M params, int8; model card: Apache-2.0), used as a
# keyword spotter. The 3.3M gigaspeech KWS model heard 1/6 real "Jarvis" from
# the user's voice; this one heard 5/6 (docs/research/2026-11-10-wake-real-voice.md).
set -euo pipefail
cd "$(dirname "$0")/.."
REL=https://github.com/k2-fsa/sherpa-onnx/releases/download
RAW=https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1
DL=.runtime/wake-download
SHERPA=.runtime/sherpa-onnx-v2.0.1
KWS=.runtime/kws/en-2023-06-26
HF=https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/672fbf1b30579d6585301139bb363f42a0ad4a24
mkdir -p "$DL/lib" "$DL/kws" "$DL/src"

fetch() { # url file sha256
  if [[ ! -f "$2" ]] || ! echo "$3  $2" | shasum -a 256 -c --status; then
    curl -fsSL --retry 3 -o "$2" "$1"
  fi
  echo "$3  $2" | shasum -a 256 -c
}

fetch "$REL/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-static-no-tts-lib.tar.bz2" "$DL/lib/lib.tar.bz2" \
  69413605e7d0d1286d40fbf66e898f7abb53f350d6057cbd154ea2e3f1437d2a
fetch "$HF/encoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx" "$DL/kws/encoder.onnx" \
  0d072fd4ef956294ba9db9e9a71a541ac70659095ec4934c8453d8b2fe740187
fetch "$HF/decoder-epoch-99-avg-1-chunk-16-left-64.int8.onnx" "$DL/kws/decoder.onnx" \
  98da299f471e38bb4e1a8df579b8cc9122d6039576a77e357b3c60f17dd83b02
fetch "$HF/joiner-epoch-99-avg-1-chunk-16-left-64.int8.onnx" "$DL/kws/joiner.onnx" \
  d944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297
fetch "$HF/tokens.txt" "$DL/kws/tokens.txt" \
  49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb
fetch "$HF/README.md" "$DL/kws/README.md" \
  c914dd28e23310a6dd345ea10495003d3e4820d2ed987181e4c2d67e501b6b76
fetch "$RAW/sherpa-onnx/c-api/c-api.h" "$DL/src/c-api.h" \
  5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
fetch "$RAW/LICENSE" "$DL/src/LICENSE" \
  cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

rm -rf "$SHERPA" "$KWS" "$DL/x"
mkdir -p "$SHERPA/include/sherpa-onnx/c-api" "$KWS" "$DL/x/lib"
tar -xjf "$DL/lib/lib.tar.bz2" -C "$DL/x/lib"
cp -R "$DL/x/lib/sherpa-onnx-v2.0.1-osx-arm64-static-no-tts-lib/lib" "$SHERPA/lib"
cp "$DL/src/c-api.h" "$SHERPA/include/sherpa-onnx/c-api/c-api.h"
cp "$DL/src/LICENSE" "$SHERPA/LICENSE"
cp "$DL/kws/"{encoder.onnx,decoder.onnx,joiner.onnx,tokens.txt,README.md} "$KWS/"
rm -rf "$DL/x"
echo "wake runtime ready: $SHERPA, $KWS"
