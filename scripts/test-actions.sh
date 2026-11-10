#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/actions/toolchain
FLAGS=(-swift-version 5 -Onone -module-cache-path .build/actions/cache)
MAPDIR="$(xcode-select -p)/usr/include/swift"
if [[ -f "$MAPDIR/module.modulemap" && -f "$MAPDIR/bridging.modulemap" ]]; then
  : > .build/actions/toolchain/empty.modulemap
  python3 - "$MAPDIR/module.modulemap" <<'PY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':os.path.abspath('.build/actions/toolchain/empty.modulemap')}]},open('.build/actions/toolchain/overlay.json','w'))
PY
  FLAGS+=(-vfsoverlay .build/actions/toolchain/overlay.json -Xcc -ivfsoverlay -Xcc .build/actions/toolchain/overlay.json)
fi
swiftc "${FLAGS[@]}" -parse-as-library Sources/Actions/*.swift Tests/Actions/ActionTests.swift -framework AppKit -o .build/actions/tests
.build/actions/tests
