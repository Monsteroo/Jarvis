#!/usr/bin/env python3
"""Reproducible A6 Accessibility UI benchmark suite (axprobe vs agent-desktop).

Privacy & safety invariants:
- Writes raw snapshots ONLY inside .runtime/ax/ (0600 permissions).
- Never prints private window titles, file names, note bodies, or tab titles.
- Performs AXPress/click ONLY on Calculator; Finder, Notes, System Settings,
  and Google Chrome are strictly read-only.
"""

import json
import math
import os
import re
import statistics
import subprocess
import time
from pathlib import Path

import shutil

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_AX = ROOT / ".runtime" / "ax"
AD_STATE = RUNTIME_AX / f"ad-state-{os.getpid()}"
AXPROBE = ROOT / ".build" / "axprobe"
AD_NODE = ROOT / "spikes" / "ax-ui" / "agent-desktop" / "node_modules" / ".bin" / "agent-desktop"
AD_NATIVE = ROOT / "spikes" / "ax-ui" / "agent-desktop" / "node_modules" / "agent-desktop" / "bin" / "agent-desktop-darwin-arm64"
AD_HELPER = ROOT / "spikes" / "ax-ui" / "agent-desktop" / "node_modules" / "agent-desktop" / "bin" / "agent-desktop-macos-helper-darwin-arm64"


def ad_env() -> dict:
    env = os.environ.copy()
    env["AGENT_DESKTOP_HOME"] = str(AD_STATE)
    env["AGENT_DESKTOP_MACOS_HELPER_PATH"] = str(AD_HELPER)
    return env


def write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o600)


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return s[int(k)]
    return s[f] * (c - k) + s[c] * (k - f)


def est_tokens(text: str) -> int:
    return math.ceil(len(text) / 4.0)


def count_ad_nodes(obj) -> int:
    count = 0
    if isinstance(obj, dict):
        if "role" in obj or "ref_id" in obj or "ref" in obj:
            count += 1
        for k, v in obj.items():
            if k in ("children", "roots", "tree", "nodes", "elements", "data"):
                count += count_ad_nodes(v)
    elif isinstance(obj, list):
        for item in obj:
            count += count_ad_nodes(item)
    return count


def run_cmd(cmd: list[str], env: dict | None = None) -> tuple[int, str, str, float]:
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    return proc.returncode, proc.stdout, proc.stderr, elapsed_ms


def resolve_ad_app_name(english_name: str, ukrainian_name: str) -> str:
    rc, out, _, _ = run_cmd([str(AD_NATIVE), "list-apps"], env=ad_env())
    if rc == 0:
        try:
            payload = json.loads(out)
            apps = payload.get("data", {}).get("apps", [])
            names = [a.get("name", "") for a in apps if isinstance(a, dict)]
            for cand in (english_name, ukrainian_name):
                for actual in names:
                    if actual.lower() == cand.lower():
                        return actual
        except Exception:
            pass
    return english_name


def parse_axprobe_refs(snapshot_text: str) -> list[dict]:
    items = []
    pat = re.compile(r'^(e\d+)\s+(\S+)\s+"(.*)"\s+\[(press|read)\]$')
    for line in snapshot_text.splitlines():
        m = pat.match(line.strip())
        if m:
            items.append({
                "ref": m.group(1),
                "role": m.group(2),
                "label": m.group(3),
                "mode": m.group(4),
            })
    return items


def extract_ad_refs(node, acc: list[dict] | None = None) -> list[dict]:
    if acc is None:
        acc = []
    if isinstance(node, dict):
        rid = node.get("ref_id") or node.get("ref")
        if rid or "role" in node:
            acc.append({
                "ref": rid,
                "role": str(node.get("role") or "").lower(),
                "name": node.get("name") or node.get("label") or "",
                "description": node.get("description") or "",
                "value": node.get("value"),
            })
        for v in node.values():
            if isinstance(v, (dict, list)):
                extract_ad_refs(v, acc)
    elif isinstance(node, list):
        for item in node:
            extract_ad_refs(item, acc)
    return acc


def benchmark_calculator_axprobe() -> dict:
    out_file = RUNTIME_AX / "calc-axprobe-init.txt"
    rc, _, err, snap_ms = run_cmd([str(AXPROBE), "snapshot", "--app", "Calculator", "--out", str(out_file)])
    if rc != 0:
        return {"ok": False, "error": err.strip()}
    entries = parse_axprobe_refs(out_file.read_text(encoding="utf-8"))

    # Optional clear first so repeated benchmark runs always start cleanly at 0.
    clear_ref = next(
        (e["ref"] for e in entries if e["mode"] == "press" and e["label"].lower() in ("ac", "c", "clear", "all clear", "очистити все", "очистити")),
        None,
    )
    if clear_ref:
        run_cmd([str(AXPROBE), "press", "--app", "Calculator", "--ref", clear_ref])
        time.sleep(0.08)
        rc, _, _, snap_ms = run_cmd([str(AXPROBE), "snapshot", "--app", "Calculator", "--out", str(out_file)])
        entries = parse_axprobe_refs(out_file.read_text(encoding="utf-8"))

    ref_2 = next((e["ref"] for e in entries if e["mode"] == "press" and e["label"] in ("2", "Two")), None)
    ref_plus = next((e["ref"] for e in entries if e["mode"] == "press" and e["label"] in ("+", "Add", "додати")), None)
    ref_eq = next((e["ref"] for e in entries if e["mode"] == "press" and e["label"] in ("=", "Equals", "дорівнює")), None)

    if not (ref_2 and ref_plus and ref_eq):
        return {"ok": False, "error": f"Missing calculator button refs: 2={ref_2}, +={ref_plus}, =={ref_eq}"}

    step_times = []
    for label, ref in [("2", ref_2), ("+", ref_plus), ("2", ref_2), ("=", ref_eq)]:
        rc, out, err, ms = run_cmd([str(AXPROBE), "press", "--app", "Calculator", "--ref", ref])
        step_times.append({"button": label, "ok": rc == 0, "wall_ms": round(ms, 2), "detail": out.strip() or err.strip()})
        if rc != 0:
            return {"ok": False, "steps": step_times}
        time.sleep(0.05)

    final_file = RUNTIME_AX / "calc-axprobe-final.txt"
    rc, _, _, read_ms = run_cmd([str(AXPROBE), "snapshot", "--app", "Calculator", "--out", str(final_file)])
    final_entries = parse_axprobe_refs(final_file.read_text(encoding="utf-8"))
    displays = [e["label"] for e in final_entries if e["role"] == "AXStaticText"]
    has_four = any(lbl == "4" or lbl.endswith(": 4") for lbl in displays)

    return {
        "ok": has_four,
        "initial_snapshot_ms": round(snap_ms, 2),
        "steps": step_times,
        "readback_snapshot_ms": round(read_ms, 2),
        "displays": displays,
        "verified_four": has_four,
    }


def benchmark_calculator_agent_desktop() -> dict:
    calc_name = resolve_ad_app_name("Calculator", "Калькулятор")
    rc, out, err, snap_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", calc_name, "--compact"], env=ad_env())
    write_private(RUNTIME_AX / "calc-ad-init.json", out)
    if rc != 0:
        return {"ok": False, "app_query": calc_name, "error": (out or err)[:300]}

    data = json.loads(out)
    nodes = extract_ad_refs(data.get("data", {}))

    def find_btn(src_nodes: list[dict], candidates: tuple[str, ...]):
        lower_cands = {c.lower() for c in candidates}
        for n in src_nodes:
            if n.get("ref") and n.get("role") == "button":
                nm = str(n.get("name") or "").strip().lower()
                desc = str(n.get("description") or "").strip().lower()
                val = str(n.get("value") or "").strip().lower()
                if nm in lower_cands or desc in lower_cands or val in lower_cands:
                    return n["ref"]
        return None

    clear_ref = find_btn(nodes, ("ac", "c", "clear", "all clear", "очистити все", "очистити"))
    if clear_ref:
        run_cmd([str(AD_NATIVE), "click", clear_ref], env=ad_env())
        time.sleep(0.08)
        rc, out, _, snap_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", calc_name, "--compact"], env=ad_env())
        write_private(RUNTIME_AX / "calc-ad-cleared.json", out)
        data = json.loads(out)
        nodes = extract_ad_refs(data.get("data", {}))

    ref_2 = find_btn(nodes, ("2", "two", "два"))
    ref_plus = find_btn(nodes, ("+", "add", "додати"))
    ref_eq = find_btn(nodes, ("=", "equals", "дорівнює"))
    if not (ref_2 and ref_plus and ref_eq):
        return {"ok": False, "error": f"Missing refs in agent-desktop: 2={ref_2}, +={ref_plus}, =={ref_eq}"}

    step_times = []
    reused_all = True
    sequence = [
        ("2", ("2", "two", "два")),
        ("+", ("+", "add", "додати")),
        ("2", ("2", "two", "два")),
        ("=", ("=", "equals", "дорівнює")),
    ]
    current_nodes = nodes

    for label, cands in sequence:
        ref = find_btn(current_nodes, cands)
        rc, click_out, click_err, ms = run_cmd([str(AD_NATIVE), "click", ref], env=ad_env())
        ok_click = rc == 0
        resnap_ms = 0.0
        if not ok_click:
            reused_all = False
            rc_s, s_out, _, resnap_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", calc_name, "--compact"], env=ad_env())
            if rc_s == 0:
                current_nodes = extract_ad_refs(json.loads(s_out).get("data", {}))
                ref = find_btn(current_nodes, cands)
                rc, click_out, click_err, ms2 = run_cmd([str(AD_NATIVE), "click", ref], env=ad_env())
                ms += ms2
                ok_click = rc == 0
        step_times.append({"button": label, "ok": ok_click, "wall_ms": round(ms, 2), "resnap_ms": round(resnap_ms, 2)})
        time.sleep(0.05)

    rc, final_out, _, read_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", calc_name, "--compact"], env=ad_env())
    write_private(RUNTIME_AX / "calc-ad-final.json", final_out)
    final_nodes = extract_ad_refs(json.loads(final_out).get("data", {})) if rc == 0 else []
    text_vals = [
        f"{n.get('description')}:{n.get('value')}:{n.get('name')}"
        for n in final_nodes
        if n.get("role") in ("statictext", "text", "label", "group", "textfield")
    ]
    has_four = any(":4:" in v or v.endswith(":4") or v.startswith("4:") or '"value":"4"' in final_out or '"value": "4"' in final_out for v in (text_vals or [""]))

    # Also measure Node wrapper overhead on 5 status/snapshot calls
    _, _, _, node_snap_ms = run_cmd([str(AD_NODE), "snapshot", "--app", calc_name, "--compact"], env=ad_env())

    return {
        "ok": has_four,
        "app_query": calc_name,
        "initial_snapshot_native_ms": round(snap_ms, 2),
        "initial_snapshot_node_wrapper_ms": round(node_snap_ms, 2),
        "reused_single_snapshot_refs": reused_all,
        "steps": step_times,
        "readback_snapshot_ms": round(read_ms, 2),
        "verified_four": has_four,
    }


def benchmark_window_snapshots(runs: int = 10) -> dict:
    targets = [
        ("Finder", "Finder"),
        ("Notes", "Нотатки"),
        ("System Settings", "Системні параметри"),
    ]
    results = {}
    for eng, ukr in targets:
        slug = eng.lower().replace(" ", "-")
        ad_app = resolve_ad_app_name(eng, ukr)

        # 1. axprobe (10 runs)
        ax_times, ax_internal_times, ax_tree_times = [], [], []
        ax_nodes = ax_visited = ax_chars = ax_tokens = 0
        for i in range(runs):
            out_file = RUNTIME_AX / f"snap-axprobe-{slug}.txt"
            rc, _, err, wall_ms = run_cmd([str(AXPROBE), "snapshot", "--app", eng, "--out", str(out_file), "--stats"])
            if rc == 0:
                ax_times.append(wall_ms)
                txt = out_file.read_text(encoding="utf-8")
                ax_chars = len(txt)
                ax_tokens = est_tokens(txt)
                m_el = re.search(r"elapsed_ms=([0-9.]+)\s+tree_ms=([0-9.]+)\s+emitted_nodes=(\d+)\s+visited_nodes=(\d+)", err)
                if m_el:
                    ax_internal_times.append(float(m_el.group(1)))
                    ax_tree_times.append(float(m_el.group(2)))
                    ax_nodes = int(m_el.group(3))
                    ax_visited = int(m_el.group(4))

        # 2. agent-desktop native interactive compact (10 runs)
        ad_i_times = []
        ad_i_nodes = ad_i_chars = ad_i_tokens = 0
        for i in range(runs):
            rc, out, _, wall_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", ad_app, "-i", "--compact"], env=ad_env())
            if i == 0:
                write_private(RUNTIME_AX / f"snap-ad-interactive-{slug}.json", out)
            if rc == 0:
                ad_i_times.append(wall_ms)
                ad_i_chars = len(out)
                ad_i_tokens = est_tokens(out)
                try:
                    ad_i_nodes = count_ad_nodes(json.loads(out).get("data", {}))
                except Exception:
                    pass

        # 3. agent-desktop native skeleton compact (10 runs) - tests Vercel's "~273 tokens" claim!
        ad_sk_times = []
        ad_sk_nodes = ad_sk_chars = ad_sk_tokens = 0
        for i in range(runs):
            rc, out, _, wall_ms = run_cmd([str(AD_NATIVE), "snapshot", "--app", ad_app, "--skeleton", "-i", "--compact"], env=ad_env())
            if i == 0:
                write_private(RUNTIME_AX / f"snap-ad-skeleton-{slug}.json", out)
            if rc == 0:
                ad_sk_times.append(wall_ms)
                ad_sk_chars = len(out)
                ad_sk_tokens = est_tokens(out)
                try:
                    ad_sk_nodes = count_ad_nodes(json.loads(out).get("data", {}))
                except Exception:
                    pass

        # 4. agent-desktop via Node wrapper (3 runs just to record Node wrapper overhead)
        ad_node_times = []
        for _ in range(3):
            rc, out, _, wall_ms = run_cmd([str(AD_NODE), "snapshot", "--app", ad_app, "-i", "--compact"], env=ad_env())
            if rc == 0:
                ad_node_times.append(wall_ms)

        results[eng] = {
            "axprobe": {
                "runs": len(ax_times),
                "wall_p50_ms": round(percentile(ax_times, 0.50), 2),
                "wall_p95_ms": round(percentile(ax_times, 0.95), 2),
                "inproc_p50_ms": round(percentile(ax_internal_times, 0.50), 2),
                "tree_only_p50_ms": round(percentile(ax_tree_times, 0.50), 2),
                "emitted_nodes": ax_nodes,
                "visited_nodes": ax_visited,
                "chars": ax_chars,
                "est_tokens": ax_tokens,
            },
            "agent_desktop_interactive": {
                "runs": len(ad_i_times),
                "native_p50_ms": round(percentile(ad_i_times, 0.50), 2),
                "native_p95_ms": round(percentile(ad_i_times, 0.95), 2),
                "node_wrapper_p50_ms": round(percentile(ad_node_times, 0.50), 2),
                "nodes": ad_i_nodes,
                "chars": ad_i_chars,
                "est_tokens": ad_i_tokens,
            },
            "agent_desktop_skeleton": {
                "runs": len(ad_sk_times),
                "native_p50_ms": round(percentile(ad_sk_times, 0.50), 2),
                "nodes": ad_sk_nodes,
                "chars": ad_sk_chars,
                "est_tokens": ad_sk_tokens,
            },
        }
    return results


def benchmark_chrome_readonly() -> dict:
    ad_chrome = resolve_ad_app_name("Google Chrome", "Google Chrome")

    # 1. Read-only snapshot without setting AXEnhancedUserInterface first
    out_120 = RUNTIME_AX / "chrome-axprobe-120.txt"
    rc1, _, err1, ms1 = run_cmd([str(AXPROBE), "snapshot", "--app", "Google Chrome", "--max-nodes", "120", "--out", str(out_120), "--stats"])
    txt_120 = out_120.read_text(encoding="utf-8") if rc1 == 0 else ""
    entries_120 = parse_axprobe_refs(txt_120)

    out_400 = RUNTIME_AX / "chrome-axprobe-400.txt"
    rc2, _, err2, ms2 = run_cmd([str(AXPROBE), "snapshot", "--app", "Google Chrome", "--max-nodes", "400", "--max-depth", "22", "--out", str(out_400), "--stats"])
    txt_400 = out_400.read_text(encoding="utf-8") if rc2 == 0 else ""
    entries_400 = parse_axprobe_refs(txt_400)

    has_youtube_header = "youtube" in (txt_400.splitlines()[0].lower() if txt_400 else "")
    link_count_400 = sum(1 for e in entries_400 if "AXLink" in e["role"])
    heading_count_400 = sum(1 for e in entries_400 if "AXHeading" in e["role"])
    button_count_400 = sum(1 for e in entries_400 if "AXButton" in e["role"])

    # Check deterministic find of close-tab button without LLM (read-only!)
    find_results = {}
    for q_label, args in [
        ("role=AXCloseButton", ["--role", "AXCloseButton"]),
        ("role=AXButton name=Close", ["--role", "AXButton", "--name", "Close"]),
        ("role=AXButton name=Закрити", ["--role", "AXButton", "--name", "Закрити"]),
    ]:
        rc_f, out_f, _, ms_f = run_cmd([str(AXPROBE), "find", "--app", "Google Chrome", *args])
        write_private(RUNTIME_AX / f"chrome-find-{len(find_results)}.txt", out_f)
        lines_f = [ln for ln in out_f.splitlines() if ln.startswith("m")]
        # Anonymize labels: keep only generic words like Close/Закрити/Tab/вкладк or role
        roles_found = list({ln.split()[1] for ln in lines_f if len(ln.split()) >= 2})
        find_results[q_label] = {
            "matches": len(lines_f),
            "wall_ms": round(ms_f, 2),
            "roles": roles_found,
        }

    # agent-desktop read-only snapshot & find on Chrome (note: agent-desktop may activate Chromium enhanced a11y on snapshot!)
    rc_ad, out_ad, err_ad, ms_ad = run_cmd([str(AD_NATIVE), "snapshot", "--app", ad_chrome, "-i", "--compact"], env=ad_env())
    write_private(RUNTIME_AX / "chrome-ad-interactive.json", out_ad)
    ad_nodes = count_ad_nodes(json.loads(out_ad).get("data", {})) if rc_ad == 0 else 0

    rc_ad_sk, out_ad_sk, _, ms_ad_sk = run_cmd([str(AD_NATIVE), "snapshot", "--app", ad_chrome, "--skeleton", "-i", "--compact"], env=ad_env())
    write_private(RUNTIME_AX / "chrome-ad-skeleton.json", out_ad_sk)
    ad_sk_nodes = count_ad_nodes(json.loads(out_ad_sk).get("data", {})) if rc_ad_sk == 0 else 0

    # Re-test axprobe after agent-desktop (or with --enable-enhanced-ax) to see if AXEnhancedUserInterface changed visibility!
    out_after = RUNTIME_AX / "chrome-axprobe-after-enhanced.txt"
    rc3, _, err3, ms3 = run_cmd([str(AXPROBE), "snapshot", "--app", "Google Chrome", "--max-nodes", "400", "--max-depth", "22", "--enable-enhanced-ax", "--out", str(out_after), "--stats"])
    txt_after = out_after.read_text(encoding="utf-8") if rc3 == 0 else ""
    entries_after = parse_axprobe_refs(txt_after)
    link_count_after = sum(1 for e in entries_after if "AXLink" in e["role"])
    heading_count_after = sum(1 for e in entries_after if "AXHeading" in e["role"])

    # agent-desktop find close tab button
    ad_find = {}
    for q_label, name_arg in [("button Close", "Close"), ("button Закрити", "Закрити")]:
        rc_af, out_af, _, ms_af = run_cmd([str(AD_NATIVE), "find", "--app", ad_chrome, "--role", "button", "--name", name_arg], env=ad_env())
        write_private(RUNTIME_AX / f"chrome-ad-find-{name_arg}.json", out_af)
        cnt = 0
        if rc_af == 0:
            try:
                d = json.loads(out_af).get("data", {})
                cnt = len(d.get("matches", d.get("elements", [])))
            except Exception:
                pass
        ad_find[q_label] = {"rc": rc_af, "matches": cnt, "wall_ms": round(ms_af, 2)}

    return {
        "active_window_is_youtube": has_youtube_header,
        "axprobe_default_120": {
            "wall_ms": round(ms1, 2),
            "stats": err1.strip(),
            "chars": len(txt_120),
            "est_tokens": est_tokens(txt_120),
        },
        "axprobe_deep_400_before_enhanced": {
            "wall_ms": round(ms2, 2),
            "stats": err2.strip(),
            "chars": len(txt_400),
            "est_tokens": est_tokens(txt_400),
            "ax_links": link_count_400,
            "ax_headings": heading_count_400,
            "ax_buttons": button_count_400,
        },
        "axprobe_deep_400_with_enhanced": {
            "wall_ms": round(ms3, 2),
            "stats": err3.strip(),
            "chars": len(txt_after),
            "est_tokens": est_tokens(txt_after),
            "ax_links": link_count_after,
            "ax_headings": heading_count_after,
        },
        "axprobe_find_close_tab": find_results,
        "agent_desktop_interactive": {
            "rc": rc_ad,
            "wall_ms": round(ms_ad, 2),
            "nodes": ad_nodes,
            "chars": len(out_ad),
            "est_tokens": est_tokens(out_ad),
        },
        "agent_desktop_skeleton": {
            "rc": rc_ad_sk,
            "wall_ms": round(ms_ad_sk, 2),
            "nodes": ad_sk_nodes,
            "chars": len(out_ad_sk),
            "est_tokens": est_tokens(out_ad_sk),
        },
        "agent_desktop_find_close_tab": ad_find,
    }


def main() -> None:
    RUNTIME_AX.mkdir(parents=True, exist_ok=True)
    AD_STATE.mkdir(parents=True, exist_ok=True)
    os.chmod(RUNTIME_AX.parent, 0o700)
    os.chmod(RUNTIME_AX, 0o700)
    os.chmod(AD_STATE, 0o700)

    summary = {
        "calculator_axprobe": benchmark_calculator_axprobe(),
        "calculator_agent_desktop": benchmark_calculator_agent_desktop(),
        "window_snapshots_10_runs": benchmark_window_snapshots(10),
        "chrome_readonly": benchmark_chrome_readonly(),
    }
    summary_path = RUNTIME_AX / "benchmark-summary.json"
    write_private(summary_path, json.dumps(summary, ensure_ascii=False, indent=2))
    shutil.rmtree(AD_STATE, ignore_errors=True)
    shutil.rmtree(RUNTIME_AX / "agent-desktop-state", ignore_errors=True)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
