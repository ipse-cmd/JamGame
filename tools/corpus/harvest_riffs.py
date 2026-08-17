#!/usr/bin/env python3
"""Harvest the player's own bass lines from human session logs into a
motif/variant pattern bank (data/pattern_bank.json).

Provenance: HUMAN logs only (solo sessions — the recorder only opens windows
for seats the local player owns, so every line here is the player's own,
rights-clean). Lines are read as bass-state transitions across decision
windows; DWELL (windows a line survived before being changed) is the implicit
quality signal — a line that held for 6 windows was working, a one-window
casualty was not.

Motifs: consecutive lines in a session sharing >= MOTIF_JACCARD of their
(step, degree) events are variants of one musical identity (A1 A2 A3...);
a bigger change starts a new motif. VARY can then mean "same motif, another
variant" instead of "mutate random cells".
"""
import json
import glob
import os
import sys

LOGDIR = os.path.expanduser("~/.local/share/godot/app_userdata/JamGame/decision_logs")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "data", "pattern_bank.json")

BANK_SCHEMA = 1
MIN_DWELL = 2      # windows a line must survive
MIN_NOTES = 2
MAX_NOTES = 8
MOTIF_JACCARD = 0.5


def jaccard(a, b):
    sa = set(a.items())
    sb = set(b.items())
    if not sa and not sb:
        return 1.0
    return len(sa & sb) / len(sa | sb)


def lines_from_log(path):
    """Ordered (notes, dwell_windows) transitions in one session."""
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
    out = []
    cur, dwell = None, 0
    for f in frames:
        notes = {int(str(k)): int(v) for k, v in f["observation"].get("bass_notes", {}).items()}
        if cur is None or notes != cur:
            if cur is not None:
                out.append((cur, dwell))
            cur, dwell = notes, 1
        else:
            dwell += 1
    if cur is not None:
        out.append((cur, dwell))
    return out


def main():
    motifs = []
    kept = dropped = 0
    for path in sorted(glob.glob(os.path.join(LOGDIR, "human_*.jsonl"))):
        session = os.path.basename(path).replace(".jsonl", "")
        cur_motif = None
        for notes, dwell in lines_from_log(path):
            if not (MIN_NOTES <= len(notes) <= MAX_NOTES) or dwell < MIN_DWELL:
                dropped += 1
                continue
            kept += 1
            variant = {"notes": {str(k): v for k, v in sorted(notes.items())}, "dwell": dwell}
            if cur_motif is not None and jaccard(
                    {int(k): v for k, v in cur_motif["variants"][-1]["notes"].items()}, notes) >= MOTIF_JACCARD:
                if variant["notes"] not in [v["notes"] for v in cur_motif["variants"]]:
                    cur_motif["variants"].append(variant)
            else:
                cur_motif = {"id": f"{session}/m{len(motifs)}", "source": session,
                             "variants": [variant]}
                motifs.append(cur_motif)
    # Global dedup: the same line harvested from several sessions (e.g. the
    # starter groove) collapses into one motif, dwell summed.
    seen = {}
    unique = []
    for m in motifs:
        key = json.dumps([v["notes"] for v in m["variants"]], sort_keys=True)
        if key in seen:
            for i, v in enumerate(m["variants"]):
                seen[key]["variants"][i]["dwell"] += v["dwell"]
        else:
            seen[key] = m
            unique.append(m)
    motifs = unique
    bank = {"bank_schema": BANK_SCHEMA, "source": "human session logs",
            "motifs": motifs}
    n_var = sum(len(m["variants"]) for m in motifs)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(bank, f, indent=1)
    print(f"kept {kept} lines ({dropped} dropped by dwell/density) -> "
          f"{len(motifs)} motifs, {n_var} variants -> {OUT}")
    for m in motifs[:8]:
        print(f"  {m['id']}: {len(m['variants'])} variant(s), e.g. {m['variants'][0]['notes']}")


if __name__ == "__main__":
    main()
