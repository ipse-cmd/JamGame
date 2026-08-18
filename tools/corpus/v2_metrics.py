#!/usr/bin/env python3
"""V2 lanes experiment metrics (pre-registered in docs/design/v2-lanes-experiment.md).

Runs on any bot decision log. Lanes: 0..6 = diatonic steps R 2 3 4 5 6 7,
7 = O. Color lanes = {1, 3, 5} (2/4/6).

Usage: python3 v2_metrics.py [bot_log.jsonl]   (default: newest bot log)
"""
import glob
import json
import os
import sys

LOGDIR = os.path.expanduser("~/.local/share/godot/app_userdata/JamGame/decision_logs")
LANES = ["R", "2", "3", "4", "5", "6", "7", "O"]
COLOR = {1, 3, 5}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else max(
        glob.glob(os.path.join(LOGDIR, "bot_*.jsonl")), key=os.path.getmtime)
    frames = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "decision":
            frames.append(e)
    edits = [f for f in frames if f["ops"]]
    print(f"{os.path.basename(path)}: {len(frames)} windows, {len(edits)} edits")

    placed = []  # (lane, step, chord_slots, style_flipped, frame_index)
    for i, f in enumerate(edits):
        r = f.get("realization", {})
        flipped = bool(r.get("style_disagreement"))
        for op in f["ops"]:
            if op.get("op") != "place":
                continue
            lane = int(op["args"]["degree"])
            step = int(op["args"]["step"])
            # place-on-same = removal; detect via pre-edit observation
            pre = f["observation"].get("bass_notes", {})
            if str(step) in pre and int(pre[str(step)]) == lane:
                continue  # removal, not a placement
            placed.append((lane, step, f["observation"].get("chord_slots", []), flipped, i))
    if not placed:
        print("no placements")
        return

    # 1. selection rate
    color = [p for p in placed if p[0] in COLOR]
    print(f"\n1. selection: {len(color)}/{len(placed)} placements on 2/4/6 "
          f"({100*len(color)/len(placed):.0f}%; corpus reference ~26% of events)")
    lane_counts = {}
    for l, *_ in placed:
        lane_counts[LANES[l]] = lane_counts.get(LANES[l], 0) + 1
    print(f"   lane distribution: {dict(sorted(lane_counts.items(), key=lambda kv: -kv[1]))}")

    # 2. rhythmic placement
    def offbeat_share(items):
        if not items:
            return float("nan")
        return sum(1 for _, s, *_ in items if s % 4 != 0) / len(items)
    stable = [p for p in placed if p[0] not in COLOR]
    print(f"2. offbeat share: color {100*offbeat_share(color):.0f}% vs stable {100*offbeat_share(stable):.0f}% "
          f"(corpus expectation: color leans offbeat)")

    # 3. harmonic context
    ctx = {}
    for l, _, slots, *_ in color:
        for d in slots:
            if int(d) >= 0:
                ctx[int(d)] = ctx.get(int(d), 0) + 1
    print(f"3. chord degrees active under color placements: {dict(sorted(ctx.items()))}")

    # 4. style attribution
    if color:
        flipped_share = sum(1 for *_, fl, _ in [(p[0], p[1], p[2], p[3], p[4]) for p in color] if p[3]) if False else \
            sum(1 for p in color if p[3])
        print(f"4. style-flipped decisions among color placements: {flipped_share}/{len(color)}")

    # 5. survival: windows until a placed note's step is edited again
    def survival(items):
        out = []
        for lane, step, _, _, idx in items:
            lived = 0
            for later in edits[idx + 1:]:
                touched = any(op.get("op") == "place" and int(op["args"]["step"]) == step
                              for op in later["ops"])
                if touched:
                    break
                lived += 1
            out.append(lived)
        return sum(out) / len(out) if out else float("nan")
    print(f"5. survival (edit-windows before the step is touched again): "
          f"color {survival(color):.1f} vs stable {survival(stable):.1f}")
    reverts = sum(1 for f in edits if f.get("realization", {}).get("intent") == "REVERT")
    print(f"   REVERT windows this session: {reverts}/{len(edits)}")


if __name__ == "__main__":
    main()
