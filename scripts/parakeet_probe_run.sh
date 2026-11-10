#!/bin/zsh
set -eu
cd "${0:A:h:h}"
root="$PWD/.runtime/parakeet-probe"
mkdir -p "$root/module-cache"
# Existing project overlay hides the duplicate CLT SwiftBridging module map.
swiftc -O -module-cache-path "$root/module-cache" \
 -vfsoverlay "$PWD/.build/toolchain-fix/overlay.json" \
 -Xcc -ivfsoverlay -Xcc "$PWD/.build/toolchain-fix/overlay.json" \
 scripts/parakeet_probe_infer.swift -o "$root/infer"
"$root/infer" "$root/model/parakeet-tdt-0.6b-v3" "$@"
