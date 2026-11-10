#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/agent/toolchain
FLAGS=(-swift-version 5 -target arm64-apple-macosx14.5 -warnings-as-errors -Onone -module-cache-path .build/agent/cache)
MAPDIR="$(xcode-select -p)/usr/include/swift"
if [[ -f "$MAPDIR/module.modulemap" && -f "$MAPDIR/bridging.modulemap" ]]; then
  : > .build/agent/toolchain/empty.modulemap
  python3 - "$MAPDIR/module.modulemap" <<'PY'
import json,os,sys
json.dump({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':os.path.abspath('.build/agent/toolchain/empty.modulemap')}]},open('.build/agent/toolchain/overlay.json','w'))
PY
  FLAGS+=(-vfsoverlay .build/agent/toolchain/overlay.json -Xcc -ivfsoverlay -Xcc .build/agent/toolchain/overlay.json)
fi
typecheck_ui() {
  swiftc "${FLAGS[@]}" -typecheck Sources/Actions/*.swift Sources/Agent/*.swift Sources/Actions/UI/*.swift -framework AppKit -framework ApplicationServices -framework CoreAudio -framework SwiftUI
}
if [[ "${1:-}" == "--typecheck-ui" ]]; then typecheck_ui; exit; fi
swiftc "${FLAGS[@]}" -parse-as-library Sources/Actions/*.swift Sources/Agent/*.swift Sources/Agent/Helper/Main.swift -framework AppKit -framework ApplicationServices -framework CoreAudio -o .build/agent/jarvis-mcp-helper
if [[ "${1:-}" == "--runtime-smoke" ]]; then
  [[ "$#" -eq 2 ]] || { echo "Supply pinned goose-acp executable" >&2; exit 1; }
  swiftc "${FLAGS[@]}" -parse-as-library Sources/Actions/*.swift Sources/Agent/*.swift Tests/Agent/Integration/GooseSmoke.swift -framework AppKit -framework ApplicationServices -framework CoreAudio -o .build/agent/goose-smoke
  exec .build/agent/goose-smoke "$2"
fi
MATCHED=0
for TEST in Tests/Agent/*Tests.swift; do
  NAME="$(basename "$TEST" .swift)"
  if [[ -n "${1:-}" && "$NAME" != "$1" ]]; then continue; fi
  MATCHED=$((MATCHED + 1))
  swiftc "${FLAGS[@]}" -parse-as-library Sources/Actions/*.swift Sources/Agent/*.swift "$TEST" -framework AppKit -framework ApplicationServices -framework CoreAudio -o ".build/agent/$NAME"
  ".build/agent/$NAME"
done

[[ "$MATCHED" -gt 0 ]] || { echo "No matching agent tests" >&2; exit 1; }

typecheck_ui
