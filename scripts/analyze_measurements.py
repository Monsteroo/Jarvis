#!/usr/bin/env python3
"""Summarise .runtime/measurements/measurements.jsonl per model + language setting.

Accuracy counts every attempt: errors, empty results, timeouts and skips are failures,
never dropped. Latency is reported separately for text responses and all completed attempts.
Correct-within-2s uses every attempt, including skips and timeouts.
Prints aggregates only, not transcripts, so the output is safe to share.
"""
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent.parent / ".runtime/measurements/measurements.jsonl"


def normalize(text: str) -> list[str]:
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"[’ʼ`´]", "'", text)
    text = re.sub(r"[^\w\s']", " ", text)
    text = text.replace("_", " ")
    return [w.strip("'") for w in text.split() if w.strip("'")]


def edit_distance(a, b) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def error_rate(expected, actual) -> float:
    return edit_distance(expected, actual) / max(1, len(expected))


def percentile(values, q):
    if not values:
        return None
    values = sorted(values)
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def summarise(records):
    groups = defaultdict(list)
    for r in records:
        groups[(r["model"], r["language_setting"])].append(r)
    out = []
    for (model, lang), rows in sorted(groups.items()):
        by_prompt_lang = defaultdict(lambda: [0, 0])
        exact = wer = cer = 0.0
        correct_within_2s = 0
        for r in rows:
            successful = r["status"] == "ok" and not r.get("timed_out", False)
            exp_w, got_w = normalize(r["expected"]), normalize(r["transcript"] if successful else "")
            ok = successful and exp_w == got_w
            correct_within_2s += ok and 0 <= r["response_s"] <= 2
            exact += ok
            wer += error_rate(exp_w, got_w)
            cer += error_rate(" ".join(exp_w), " ".join(got_w))
            by_prompt_lang[r["prompt_language"]][0] += ok
            by_prompt_lang[r["prompt_language"]][1] += 1
        n = len(rows)
        timed = [r for r in rows if r["status"] == "ok" and not r.get("timed_out", False)]
        completed = [r for r in rows if r["status"] != "skipped"]
        status = defaultdict(int)
        for r in rows:
            status[r["status"]] += 1
            status["timed_out"] += bool(r.get("timed_out"))
        out.append({
            "model": model, "language_setting": lang, "attempts": n,
            "correct_within_2s": correct_within_2s / n,
            "completed_response_s": {"p50": percentile([r["response_s"] for r in completed], .5),
                                     "p95": percentile([r["response_s"] for r in completed], .95), "n": len(completed)},
            "passes": sorted({r["pass"] for r in rows}),
            "exact_match": exact / n, "mean_wer": wer / n, "mean_cer": cer / n,
            "exact_by_prompt_language": {k: f"{v[0]}/{v[1]}" for k, v in sorted(by_prompt_lang.items())},
            "status_counts": dict(sorted(status.items())),
            "response_s": {"p50": percentile([r["response_s"] for r in timed], .5),
                           "p95": percentile([r["response_s"] for r in timed], .95), "n": len(timed)},
            "whisper_s": {"p50": percentile([r["whisper_s"] for r in timed], .5),
                          "p95": percentile([r["whisper_s"] for r in timed], .95)},
        })
    return out


def fmt(x):
    return "—" if x is None else f"{x:.2f}"


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT
    if not path.exists():
        print(f"No measurements at {path}", file=sys.stderr)
        return 1
    records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    for s in summarise(records):
        print(f"\n== {s['model']} / language={s['language_setting']} · {s['attempts']} attempts · passes {s['passes']}")
        print(f"exact {s['exact_match']:.0%} · WER {s['mean_wer']:.1%} · CER {s['mean_cer']:.1%}")
        print("exact by prompt language:", s["exact_by_prompt_language"])
        print("statuses:", s["status_counts"])
        r, w = s["response_s"], s["whisper_s"]
        print(f"text responses (no timeout): p50 {fmt(r['p50'])} s · p95 {fmt(r['p95'])} s (n={r['n']}) · whisper p50 {fmt(w['p50'])} s · p95 {fmt(w['p95'])} s")
        c = s["completed_response_s"]
        print(f"all completed (including failures/timeouts): p50 {fmt(c['p50'])} s · p95 {fmt(c['p95'])} s (n={c['n']})")
        print(f"correct within 2 s: {s['correct_within_2s']:.0%} of ALL attempts, including skips/timeouts")
    print("\nTimeout response starts at the recording limit, not speech end. Esc cancellations are not logged.\nResponse = key-up → text. Not speech-end-to-action. Exact match ignores case and punctuation;"
          " names, numbers and negations still need a manual check.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
