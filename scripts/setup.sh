#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .runtime/models
REV=2eeeba56e9edd762b4b38467bab96c2517163158
if [[ ! -d .runtime/whisper.cpp/.git ]]; then
  git clone --depth 1 --branch v1.8.3 https://github.com/ggml-org/whisper.cpp.git .runtime/whisper.cpp
fi
[[ "$(git -C .runtime/whisper.cpp rev-parse HEAD)" == "$REV" ]] || { echo 'Unexpected whisper revision'; exit 1; }
for model in base small; do
  case "$model" in
    base) expected=465707469ff3a37a2b9b8d8f89f2f99de7299dac ;;
    small) expected=55356645c2b361a969dfd0ef2c5a50d530afd8d5 ;;
  esac
  target=".runtime/models/ggml-$model.bin"
  if [[ ! -f "$target" ]] || [[ "$(shasum "$target" | cut -d' ' -f1)" != "$expected" ]]; then
    curl --fail -L --retry 2 -o "$target.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin"
    [[ "$(shasum "$target.part" | cut -d' ' -f1)" == "$expected" ]] || { echo 'Model checksum mismatch'; exit 1; }
    mv "$target.part" "$target"
  fi
done
python3 scripts/parakeet_probe_download.py
scripts/build.sh
