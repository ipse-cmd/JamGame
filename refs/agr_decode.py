#!/usr/bin/env python3
"""Decode Ableton .agr (gzipped XML) captures of Stolperbeats triggers into a
per-16th-step timing/swing map.

Usage:  python3 agr_decode.py *.agr
Writes a <name>.agr.json next to each input with full per-hit data.
"""
import gzip, re, sys, json

STEP = 0.25          # one 16th note in beats (quarter-note = 1.0)
CLUSTER = 0.05       # events within this many beats are one physical hit
PPQN = 960           # ticks per quarter for the "ticks" column
BPM = 120.0          # only used for the ms column; swing itself is tempo-free

def load(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":            # gzip magic -> .agr; else plain xml
        raw = gzip.decompress(raw)
    xml = raw.decode("utf-8", "replace")
    evs = []
    for m in re.finditer(r'<MidiNoteEvent Time="([-0-9.eE]+)"[^>]*Velocity="(\d+)"', xml):
        evs.append((float(m.group(1)), int(m.group(2))))
    evs.sort()
    return evs

def cluster(evs):
    """Collapse stacked notes into one hit: (onset, peak_velocity, n)."""
    hits, cur = [], []
    for t, v in evs:
        if t < 0:                          # drop the stray negative-time artifact
            continue
        if cur and t - cur[-1][0] > CLUSTER:
            hits.append(_fold(cur)); cur = []
        cur.append((t, v))
    if cur:
        hits.append(_fold(cur))
    return hits

def _fold(group):
    onset = sum(t for t, _ in group) / len(group)   # centroid stable to <0.1ms
    peak  = max(v for _, v in group)
    return (onset, peak, len(group))

def analyse(path):
    hits = cluster(load(path))
    if not hits:
        return []
    origin = round(hits[0][0])                       # snap grid origin to first hit
    rows = []
    for onset, vel, n in hits:
        idx  = round((onset - origin) / STEP)
        grid = origin + idx * STEP
        dev  = onset - grid
        rows.append({
            "step": idx, "pos_in_beat": idx % 4,
            "onset": round(onset, 5), "grid": round(grid, 5),
            "dev_beats": round(dev, 5), "dev_ticks": round(dev * PPQN, 1),
            "dev_ms@120": round(dev * 60000.0 / BPM, 2),
            "pct_of_16th": round(dev / STEP * 100, 1),
            "vel": vel, "stack": n,
        })
    return rows

def swing_summary(rows):
    buckets = {0: [], 1: [], 2: [], 3: []}
    for r in rows:
        buckets[r["pos_in_beat"]].append(r["dev_beats"])
    return {p: round(sum(xs) / len(xs), 5) for p, xs in buckets.items() if xs}

if __name__ == "__main__":
    label = {0: "downbeat (1)", 1: "e (2nd 16th)", 2: "and (8th)", 3: "a (4th 16th)"}
    for path in sys.argv[1:]:
        rows = analyse(path)
        name = path.split("/")[-1]
        print(f"\n========== {name}  ({len(rows)} hits) ==========")
        print(f"{'step':>4} {'inbeat':>7} {'onset':>9} {'dev_beat':>9} {'ticks':>7} {'%16th':>6} {'vel':>4}")
        for r in rows[:20]:
            print(f"{r['step']:>4} {r['pos_in_beat']:>7} {r['onset']:>9} {r['dev_beats']:>9} "
                  f"{r['dev_ticks']:>7} {r['pct_of_16th']:>6} {r['vel']:>4}")
        if len(rows) > 20:
            print(f"   ... ({len(rows)-20} more)")
        s = swing_summary(rows)
        print("  -- avg deviation by position in beat --")
        for p in sorted(s):
            print(f"     {label[p]:<16}: {s[p]:+.4f} beats  ({s[p]/STEP*100:+.1f}% of 16th, {s[p]*PPQN:+.0f} ticks)")
        out = path + ".json"
        with open(out, "w") as f:
            json.dump({"hits": rows, "swing_by_position": s}, f, indent=2)
        print(f"  -> wrote {out}")
