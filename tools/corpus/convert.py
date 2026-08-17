#!/usr/bin/env python3
"""midi -> JamminCorpusExample converter (stage 1: GMD drums + FiloBass bass).

ONE common representation bridges every corpus: bars of 16 steps, chord-relative
bass tones (the game's R/3/5/7/O lanes + explicit out-of-vocabulary color
classes), and feature definitions mirroring the game's JamFeatures/JamAnalysis
(densities, offbeat mass with the same 0/.5/1 placement weights, groove timing
as %-of-a-16th deviations by beat position — AGR-compatible down/e/and/a maps).

Usage:
    python3 convert.py gmd       # ~/JamminCorpus/groove -> gmd.jsonl
    python3 convert.py filobass  # FiloBass note_data.csv -> filobass.jsonl
    python3 convert.py summary   # style-contrast tables from the .jsonl files

Output: JSONL of examples in /media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples/
(example_schema 1). Style values are corpus-provided tags, never invented.
"""
import csv
import json
import math
import os
import sys
from collections import defaultdict
from fractions import Fraction


def num(s: str) -> float:
    """Offsets may be decimals or fractions ('4/3' = triplet positions)."""
    return float(Fraction(s))

GMD_DIR = os.path.expanduser("~/JamminCorpus/groove")
FILOBASS_CSV = os.path.expanduser(
    "~/JamminCorpus/filobass/FiloBass ISMIR Publication/notebooks_and_scripts/note_data.csv")
OUT_DIR = "/media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples"

EXAMPLE_SCHEMA = 1
STEPS_PER_BAR = 16

# GM drum note -> Jammin lane (kick/snare/hat/perc), mirroring the game's 4 voices.
GM_TO_LANE = {}
for n in (35, 36):
    GM_TO_LANE[n] = "kick"
for n in (37, 38, 39, 40):
    GM_TO_LANE[n] = "snare"
for n in (42, 44, 46, 51, 53, 59):  # hats + ride family -> hat lane
    GM_TO_LANE[n] = "hat"
for n in (41, 43, 45, 47, 48, 50, 49, 52, 55, 57):  # toms + crashes -> perc
    GM_TO_LANE[n] = "perc"

# FiloBass note_degree -> Jammin tone token. Diatonic lanes absorb quality
# (the 3rd of a minor chord IS b3); flat-5 is the chord's fifth over
# half-diminished/diminished kinds. Everything else is explicit out-of-vocab
# color: x2/x4/x6 = the planned V2 lanes, in Scaler-style octave-free naming.
FLAT5_CHORD_KINDS = {"m7b5", "dim", "dim7", "7#11", "maj7#11"}


def degree_to_token(degree: str, chord_kind: str) -> str:
    d = degree.strip()
    if d == "R":
        return "R"
    if d in ("3", "b3"):
        return "3"
    if d == "5":
        return "5"
    if d == "b5":
        return "5" if chord_kind in FLAT5_CHORD_KINDS else "x4"
    if d in ("7", "b7"):
        return "7"
    if d in ("9", "b9", "#9", "2"):
        return "x2"
    if d in ("11", "#11", "4"):
        return "x4"
    if d in ("13", "b13", "6"):
        return "x6"
    return "x?"


def offbeat_weight(step: int) -> float:  # same table as JamAnalysis
    if step % 4 == 0:
        return 0.0
    if step % 2 == 0:
        return 0.5
    return 1.0


def quantize(beats_in_bar: float):
    """Beat position within a 4/4 bar -> (step 0..15, deviation in % of a 16th)."""
    sixteenths = beats_in_bar * 4.0
    step = int(round(sixteenths))
    dev = (sixteenths - step) * 100.0
    return step % STEPS_PER_BAR, dev


def pos_class(step: int) -> str:  # AGR-compatible beat-position classes
    return ("down", "e", "and", "a")[step % 4]


class Agg:
    def __init__(self):
        self.n, self.total, self.sq = 0, 0.0, 0.0

    def add(self, v: float):
        self.n += 1
        self.total += v
        self.sq += v * v

    def mean(self):
        return self.total / self.n if self.n else 0.0

    def std(self):
        if self.n < 2:
            return 0.0
        m = self.mean()
        return math.sqrt(max(0.0, self.sq / self.n - m * m))


# ------------------------------------------------------------------ FiloBass

def convert_filobass():
    songs = defaultdict(list)
    with open(FILOBASS_CSV) as f:
        for r in csv.DictReader(f):
            if r["type"] != "Note" or not r["chord"] or r["chord"] == "NC":
                continue
            songs[(r["title"], r["player"])].append(r)

    examples = []
    for (title, player), rows in sorted(songs.items()):
        bars = defaultdict(dict)   # measure -> {step: token}
        tone_counts = defaultdict(int)
        offbeat = Agg()
        midis = []
        for r in rows:
            step, _dev = quantize(num(r["note_relative_offset"]))
            token = degree_to_token(r["note_degree"], r["chord_kind"])
            bars[int(r["measure_number"])][step] = token
            tone_counts[token] += 1
            offbeat.add(offbeat_weight(step))
            if r["note_midi"]:
                midis.append(int(float(r["note_midi"])))
        n_notes = sum(tone_counts.values())
        n_bars = len(bars)
        in_vocab = sum(c for t, c in tone_counts.items() if not t.startswith("x"))
        intervals = [abs(b - a) for a, b in zip(midis, midis[1:])]
        examples.append({
            "example_schema": EXAMPLE_SCHEMA,
            "source": "filobass",
            "source_id": title,
            "style": "jazz",
            "sub_style": player,
            "role": "bass",
            "bars": n_bars,
            "notes": n_notes,
            "bass_density": n_notes / max(1, n_bars) / STEPS_PER_BAR,
            "tone_fractions": {t: c / n_notes for t, c in sorted(tone_counts.items())},
            "in_vocab_fraction": in_vocab / n_notes,
            "offbeat_mass": offbeat.mean(),
            "mean_interval_semitones": sum(intervals) / len(intervals) if intervals else 0.0,
            "bar_tokens": [{str(s): t for s, t in sorted(bars[m].items())}
                           for m in sorted(bars)],
        })
    return examples


# ----------------------------------------------------------------------- GMD

def convert_gmd():
    import mido
    examples = []
    skipped = 0
    with open(os.path.join(GMD_DIR, "info.csv")) as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        if r["time_signature"] != "4-4":
            skipped += 1
            continue
        path = os.path.join(GMD_DIR, r["midi_filename"])
        try:
            mid = mido.MidiFile(path)
        except Exception:
            skipped += 1
            continue
        tpb = mid.ticks_per_beat
        bars = defaultdict(lambda: defaultdict(set))  # bar -> lane -> steps
        lane_hits = defaultdict(int)
        groove_dev = defaultdict(Agg)   # pos class -> deviation % of 16th
        groove_vel = defaultdict(Agg)
        offbeat = Agg()
        max_bar = -1
        for track in mid.tracks:
            t = 0
            for msg in track:
                t += msg.time
                if msg.type == "note_on" and msg.velocity > 0:
                    lane = GM_TO_LANE.get(msg.note)
                    if lane is None:
                        continue
                    beats = t / tpb
                    bar = int(beats // 4)
                    step, dev = quantize(beats % 4.0)
                    max_bar = max(max_bar, bar)
                    bars[bar][lane].add(step)
                    lane_hits[lane] += 1
                    groove_dev[pos_class(step)].add(dev)
                    groove_vel[pos_class(step)].add(msg.velocity)
                    offbeat.add(offbeat_weight(step))
        n_bars = max_bar + 1
        if n_bars <= 0 or not lane_hits:
            skipped += 1
            continue
        style = r["style"].split("/")[0]
        examples.append({
            "example_schema": EXAMPLE_SCHEMA,
            "source": "gmd",
            "source_id": r["id"],
            "style": style,
            "sub_style": r["style"],
            "role": "drums",
            "kind": r["beat_type"],   # beat | fill — never mix them blindly
            "bpm": float(r["bpm"]),
            "bars": n_bars,
            "lane_density": {k: lane_hits[k] / n_bars / STEPS_PER_BAR
                             for k in ("kick", "snare", "hat", "perc")},
            "offbeat_mass": offbeat.mean(),
            "groove": {p: {"dev_mean_pct16": groove_dev[p].mean(),
                           "dev_std_pct16": groove_dev[p].std(),
                           "vel_mean": groove_vel[p].mean(),
                           "n": groove_dev[p].n}
                       for p in ("down", "e", "and", "a")},
        })
    return examples, skipped


# ------------------------------------------------------------------- summary

def summary():
    def load(name):
        path = os.path.join(OUT_DIR, name)
        return [json.loads(l) for l in open(path)] if os.path.exists(path) else []

    gmd = load("gmd.jsonl")
    beats = [e for e in gmd if e["kind"] == "beat"]
    by_style = defaultdict(list)
    for e in beats:
        by_style[e["style"]].append(e)
    print("GMD drum profile by style (beats only, per-style means):")
    print(f"{'style':>10} {'n':>4} {'kick':>6} {'snare':>6} {'hat':>6} {'offbeat':>8} "
          f"{'dev e%':>7} {'dev &%':>7} {'dev a%':>7} {'vel dn':>7} {'vel &':>6}")
    for s in sorted(by_style, key=lambda s: -len(by_style[s])):
        es = by_style[s]
        n = len(es)
        def m(f):
            return sum(f(e) for e in es) / n
        print(f"{s:>10} {n:>4} {m(lambda e: e['lane_density']['kick']):6.3f} "
              f"{m(lambda e: e['lane_density']['snare']):6.3f} "
              f"{m(lambda e: e['lane_density']['hat']):6.3f} "
              f"{m(lambda e: e['offbeat_mass']):8.3f} "
              f"{m(lambda e: e['groove']['e']['dev_mean_pct16']):7.1f} "
              f"{m(lambda e: e['groove']['and']['dev_mean_pct16']):7.1f} "
              f"{m(lambda e: e['groove']['a']['dev_mean_pct16']):7.1f} "
              f"{m(lambda e: e['groove']['down']['vel_mean']):7.1f} "
              f"{m(lambda e: e['groove']['and']['vel_mean']):6.1f}")

    filo = load("filobass.jsonl")
    if filo:
        n = len(filo)
        print(f"\nFiloBass jazz bass ({n} performances):")
        allf = defaultdict(float)
        for e in filo:
            for t, f in e["tone_fractions"].items():
                allf[t] += f / n
        print("  mean tone fractions:", {t: round(v, 3) for t, v in sorted(allf.items(), key=lambda kv: -kv[1])})
        print(f"  mean in-vocab (R/3/5/7): {sum(e['in_vocab_fraction'] for e in filo)/n:.3f}")
        print(f"  mean density: {sum(e['bass_density'] for e in filo)/n:.3f}  "
              f"offbeat mass: {sum(e['offbeat_mass'] for e in filo)/n:.3f}  "
              f"mean interval: {sum(e['mean_interval_semitones'] for e in filo)/n:.2f} st")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("filobass", "all"):
        ex = convert_filobass()
        with open(os.path.join(OUT_DIR, "filobass.jsonl"), "w") as f:
            for e in ex:
                f.write(json.dumps(e) + "\n")
        print(f"filobass: {len(ex)} examples")
    if what in ("gmd", "all"):
        ex, skipped = convert_gmd()
        with open(os.path.join(OUT_DIR, "gmd.jsonl"), "w") as f:
            for e in ex:
                f.write(json.dumps(e) + "\n")
        print(f"gmd: {len(ex)} examples ({skipped} skipped: non-4/4 or unreadable)")
    if what in ("summary", "all"):
        summary()


if __name__ == "__main__":
    main()
