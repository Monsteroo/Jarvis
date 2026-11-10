#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/actions/toolchain
FLAGS=(-swift-version 5 -target arm64-apple-macosx14.5 -warnings-as-errors -Onone -module-cache-path .build/actions/cache)
MAPDIR="$(xcode-select -p)/usr/include/swift"
if [[ -f "$MAPDIR/module.modulemap" && -f "$MAPDIR/bridging.modulemap" ]]; then
  : > .build/actions/toolchain/empty.modulemap
  python3 - "$MAPDIR/module.modulemap" <<'PY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':os.path.abspath('.build/actions/toolchain/empty.modulemap')}]},open('.build/actions/toolchain/overlay.json','w'))
PY
  FLAGS+=(-vfsoverlay .build/actions/toolchain/overlay.json -Xcc -ivfsoverlay -Xcc .build/actions/toolchain/overlay.json)
fi
for TEST in Tests/Actions/*Tests.swift; do
  NAME="$(basename "$TEST" .swift)"
  swiftc "${FLAGS[@]}" -parse-as-library Sources/Actions/*.swift "$TEST" -framework AppKit -framework ApplicationServices -framework CoreAudio -o ".build/actions/$NAME"
  ".build/actions/$NAME"
done
