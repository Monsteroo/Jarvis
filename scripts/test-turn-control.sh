#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/turn-control/toolchain
FLAGS=(-swift-version 5 -Onone -warnings-as-errors -module-cache-path .build/actions/cache)
MAPDIR="$(xcode-select -p)/usr/include/swift"
if [[ -f "$MAPDIR/module.modulemap" && -f "$MAPDIR/bridging.modulemap" ]]; then
  : > .build/turn-control/toolchain/empty.modulemap
  python3 - "$MAPDIR/module.modulemap" <<'PY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':os.path.abspath('.build/turn-control/toolchain/empty.modulemap')}]},open('.build/turn-control/toolchain/overlay.json','w'))
PY
  FLAGS+=(-vfsoverlay .build/turn-control/toolchain/overlay.json -Xcc -ivfsoverlay -Xcc .build/turn-control/toolchain/overlay.json)
fi
swiftc "${FLAGS[@]}" -parse-as-library Sources/TurnControl.swift Tests/TurnControl/TurnControlTests.swift -o .build/turn-control/tests
.build/turn-control/tests
