#!/usr/bin/env python3
"""Interaction axis: drums↔bass coupling measured from aligned multitracks.

Sources:
- BabySlakh (clean per-stem instrument labels; full Slakh swaps in when its
  download lands)
- Lakh full, genre-filtered through MidiCaps captions (jazz / electronic
  lists), capped per genre and LOGGED (no silent caps).

Per pair, on a 16-step 4/4 grid: the joint per-step table of
{kick&bass, kick only, bass only, neither}, per-bar density correlation, and
bass-fills-silence measures. Profiles get an `interaction` role section with
provenance + confidence, consumed by the game's style prior as
drum-CONDITIONED scoring (a candidate is jazz-shaped *against these drums*,
not in a vacuum).

Usage: python3 interaction.py extract | profiles | all
"""
import json
import os
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    yaml = None
import mido

BABY = "/media/ipsedesktop/ShareDrive1/ModelData/babyslakh_16k"
LMD = os.path.expanduser("~/JamminCorpus/lmd_full")
CAPTIONS = os.path.expanduser("~/JamminCorpus/midicaps/train.json")
EX_DIR = "/media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples"
PROFILE_DIR = os.path.join(EX_DIR, "profiles")

LAKH_CAP_PER_GENRE = 400  # scanned files per genre list — logged, not silent
KICK_NOTES = {35, 36}
BASS_PROGRAMS = set(range(32, 40))
GENRES = {
    "jazz": lambda g: "jazz" in g,
    "electronic": lambda g: any(x in g for x in ("electronic", "techno", "house", "trance", "dance")),
}


def onsets_from_track(mid, want_drums, want_bass_program):
    """(drum_kick_beats, drum_all_beats, bass_beats) from one MidiFile."""
    tpb = mid.ticks_per_beat
    kicks, drums, bass = [], [], []
    for track in mid.tracks:
        t = 0
        program = -1
        for msg in track:
            t += msg.time
            if msg.type == "program_change":
                program = msg.program
            elif msg.type == "note_on" and msg.velocity > 0:
                beats = t / tpb
                if getattr(msg, "channel", 0) == 9:
                    if want_drums:
                        drums.append(beats)
                        if msg.note in KICK_NOTES:
                            kicks.append(beats)
                elif want_bass_program and program in BASS_PROGRAMS:
                    bass.append(beats)
    return kicks, drums, bass


def is_44(mid):
    for track in mid.tracks:
        for msg in track:
            if msg.type == "time_signature":
                return msg.numerator == 4 and msg.denominator == 4
    return True  # unspecified = assume 4/4 (MIDI default)


def measure(kicks, drums, bass):
    """Joint per-step stats over shared bars."""
    def grid(beats):
        out = defaultdict(set)
        for b in beats:
            bar = int(b // 4)
            step = int(round((b % 4) * 4)) % 16
            out[bar].add(step)
        return out
    gk, gd, gb = grid(kicks), grid(drums), grid(bass)
    bars = sorted(set(gk) | set(gb) | set(gd))
    if len(bars) < 4:
        return None
    table = [[0, 0, 0, 0] for _ in range(16)]  # per step: kb, k, b, neither
    dens = []
    for bar in bars:
        ks, ds, bs = gk.get(bar, set()), gd.get(bar, set()), gb.get(bar, set())
        dens.append((len(ds), len(bs)))
        for s in range(16):
            k, b = s in ks, s in bs
            table[s][0 if (k and b) else (1 if k else (2 if b else 3))] += 1
    n = len(bars)
    kb = sum(t[0] for t in table)
    k_only = sum(t[1] for t in table)
    b_only = sum(t[2] for t in table)
    neither = sum(t[3] for t in table)
    silent_bass = 0
    drum_silent_steps = 0
    for bar in bars:
        ds, bs = gd.get(bar, set()), gb.get(bar, set())
        for s in range(16):
            if s not in ds:
                drum_silent_steps += 1
                if s in bs:
                    silent_bass += 1
    # Pearson over per-bar densities.
    dx = [d for d, _ in dens]
    dy = [b for _, b in dens]
    mx, my = sum(dx) / n, sum(dy) / n
    cov = sum((a - mx) * (b - my) for a, b in zip(dx, dy))
    vx = sum((a - mx) ** 2 for a in dx)
    vy = sum((b - my) ** 2 for b in dy)
    corr = cov / ((vx * vy) ** 0.5) if vx > 0 and vy > 0 else 0.0
    return {
        "bars": n,
        "step_table": table,
        "bass_given_kick": kb / max(1, kb + k_only),
        "bass_given_nokick": b_only / max(1, b_only + neither),
        "bass_in_drum_silence": silent_bass / max(1, drum_silent_steps),
        "density_corr": corr,
    }


def extract():
    examples = []
    # --- BabySlakh: labeled stems ---
    if yaml is not None and os.path.isdir(BABY):
        for track in sorted(os.listdir(BABY)):
            meta_path = os.path.join(BABY, track, "metadata.yaml")
            if not os.path.exists(meta_path):
                continue
            meta = yaml.safe_load(open(meta_path))
            drum_stem = bass_stem = None
            for sid, s in meta.get("stems", {}).items():
                if s.get("is_drum") and drum_stem is None:
                    drum_stem = sid
                if s.get("inst_class") == "Bass" and bass_stem is None:
                    bass_stem = sid
            if not (drum_stem and bass_stem):
                continue
            try:
                dmid = mido.MidiFile(os.path.join(BABY, track, "MIDI", drum_stem + ".mid"))
                bmid = mido.MidiFile(os.path.join(BABY, track, "MIDI", bass_stem + ".mid"))
            except Exception:
                continue
            # Slakh stems keep drums on channel 9? Some render on ch0 — treat the
            # whole drum stem as drums and the whole bass stem as bass.
            kicks, drums, _ = onsets_from_track(dmid, True, False)
            if not drums:  # drum stem not on ch9: take every note as a drum, kick = low notes
                tpb = dmid.ticks_per_beat
                for tr in dmid.tracks:
                    t = 0
                    for msg in tr:
                        t += msg.time
                        if msg.type == "note_on" and msg.velocity > 0:
                            drums.append(t / tpb)
                            if msg.note in KICK_NOTES:
                                kicks.append(t / tpb)
            bass = []
            tpb = bmid.ticks_per_beat
            for tr in bmid.tracks:
                t = 0
                for msg in tr:
                    t += msg.time
                    if msg.type == "note_on" and msg.velocity > 0:
                        bass.append(t / tpb)
            m = measure(kicks, drums, bass)
            if m:
                m.update({"source": "babyslakh", "source_id": track, "genre": "all"})
                examples.append(m)
        print(f"babyslakh: {len(examples)} pairs")

    # --- Lakh via MidiCaps genre lists ---
    lists = {g: [] for g in GENRES}
    with open(CAPTIONS) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            genres = [str(x).lower() for x in e.get("genre", [])]
            for gname, pred in GENRES.items():
                if pred(" ".join(genres)) and len(lists[gname]) < LAKH_CAP_PER_GENRE:
                    lists[gname].append(e["location"])
    for gname, locs in lists.items():
        kept = scanned = 0
        for loc in locs:
            path = os.path.join(os.path.dirname(LMD), loc)
            if not os.path.exists(path):
                continue
            scanned += 1
            try:
                mid = mido.MidiFile(path)
            except Exception:
                continue
            if not is_44(mid):
                continue
            kicks, drums, bass = onsets_from_track(mid, True, True)
            if len(bass) < 32 or len(drums) < 32:
                continue
            m = measure(kicks, drums, bass)
            if m:
                m.update({"source": "lakh", "source_id": loc, "genre": gname})
                examples.append(m)
                kept += 1
        print(f"lakh/{gname}: scanned {scanned}/{len(locs)} listed "
              f"(cap {LAKH_CAP_PER_GENRE} of the full corpus — capped, not exhaustive), kept {kept} pairs")

    with open(os.path.join(EX_DIR, "interaction.jsonl"), "w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")
    print(f"total interaction pairs: {len(examples)}")


def confidence(n):
    return "HIGH" if n >= 100 else ("MEDIUM" if n >= 25 else ("LOW" if n >= 5 else "UNKNOWN"))


def profiles():
    examples = [json.loads(l) for l in open(os.path.join(EX_DIR, "interaction.jsonl"))]
    groups = defaultdict(list)
    for e in examples:
        groups[e["genre"]].append(e)
        groups["all"].append(e)
    for genre, es in sorted(groups.items()):
        n = len(es)
        table = [[0, 0, 0, 0] for _ in range(16)]
        for e in es:
            for s in range(16):
                for j in range(4):
                    table[s][j] += e["step_table"][s][j]
        def wmean(key):
            tot = sum(e["bars"] for e in es)
            return sum(e[key] * e["bars"] for e in es) / tot
        total_cells = sum(sum(t) for t in table)
        bass_cells = sum(t[0] + t[2] for t in table)
        prof = {
            "n_pairs": n,
            "n_bars": sum(e["bars"] for e in es),
            "step_table": table,
            "bass_marginal": bass_cells / max(1, total_cells),
            "bass_given_kick": wmean("bass_given_kick"),
            "bass_given_nokick": wmean("bass_given_nokick"),
            "bass_in_drum_silence": wmean("bass_in_drum_silence"),
            "density_corr_mean": sum(e["density_corr"] for e in es) / n,
            "source": "BabySlakh + Lakh(MidiCaps-filtered, capped)",
            "confidence": confidence(n),
        }
        print(f"{genre:>12}: n={n} bass|kick={prof['bass_given_kick']:.3f} "
              f"bass|nokick={prof['bass_given_nokick']:.3f} "
              f"fills-silence={prof['bass_in_drum_silence']:.3f} "
              f"density_corr={prof['density_corr_mean']:+.2f} [{prof['confidence']}]")
        # Inject into the matching style profile file if it exists; else write standalone.
        pf = os.path.join(PROFILE_DIR, f"{genre}.json")
        if os.path.exists(pf):
            data = json.load(open(pf))
        else:
            data = {"profile_schema": 1, "style_id": genre, "roles": {}}
        data["roles"]["interaction"] = {"profile": prof, "source": prof["source"],
                                        "confidence": prof["confidence"]}
        with open(pf, "w") as f:
            json.dump(data, f, indent=1)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("extract", "all"):
        extract()
    if what in ("profiles", "all"):
        profiles()
