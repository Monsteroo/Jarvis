#!/bin/bash
# Synthetic wake-word fixtures from macOS system voices. No microphone audio.
# Output: .runtime/wake-fixtures/{pos,neg}/*.wav (16 kHz mono 16-bit).
# These are a smoke/regression set, not evidence of accuracy on real voices.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.runtime/wake-fixtures
rm -rf "$OUT"
mkdir -p "$OUT/pos" "$OUT/neg" "$OUT/tmp"
make() { # dir name voice text
  local aiff="$OUT/tmp/$2.aiff"
  say -v "$3" -o "$aiff" "[[slnc 700]] $4 [[slnc 900]]"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$OUT/$1/$2.wav"
}
for v in Samantha Daniel Fred Kathy Ralph Junior; do
  make pos "jarvis-$v" "$v" "Jarvis."
  make pos "jarvis-cmd-$v" "$v" "Jarvis, open the browser."
  make neg "service-$v" "$v" "Please call the service desk."
  make neg "harvest-$v" "$v" "The harvest was good this year."
  make neg "chat-$v" "$v" "Open the browser and show me the weather for tomorrow."
done
make pos "jarvis-Lesya" Lesya "Джарвіс."
make pos "jarvis-cmd-Lesya" Lesya "Джарвіс, відкрий браузер."
make neg "uk-1-Lesya" Lesya "Перемкнись на термінал."
make neg "uk-2-Lesya" Lesya "Відкрий налаштування звуку і покажи погоду на завтра."
make neg "uk-3-Lesya" Lesya "Джаз звучить у сервісі для харчування."
make neg "uk-4-Lesya" Lesya "Ярмарок, ярус, жарко, джерело."
# Long-running listening: room-like noise (≈ −47 dBFS) for 12/30/60 s before
# the keyword. A single sherpa stream missed these; the bridge must not.
python3 -I - "$OUT" <<'PY'
import os, random, struct, sys, wave
out = sys.argv[1]
src = os.path.join(out, "pos", "jarvis-cmd-Samantha.wav")
with wave.open(src) as w:
    params, frames = w.getparams(), w.readframes(w.getnframes())
random.seed(7)
for seconds in (12, 30, 60):
    noise = b"".join(struct.pack("<h", int(random.gauss(0, 150))) for _ in range(16000 * seconds))
    with wave.open(os.path.join(out, "pos", f"jarvis-after-noise{seconds}.wav"), "wb") as o:
        o.setparams(params)
        o.writeframes(noise + frames)
    with wave.open(os.path.join(out, "neg", f"noise-only{seconds}.wav"), "wb") as o:
        o.setparams(params)
        o.writeframes(noise)
PY
rm -rf "$OUT/tmp"
echo "fixtures: $(ls "$OUT/pos" | wc -l | tr -d ' ') positive, $(ls "$OUT/neg" | wc -l | tr -d ' ') negative"
