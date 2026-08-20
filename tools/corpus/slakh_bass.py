#!/usr/bin/env python3
"""Slakh2100 labeled stems -> chord-relative bass examples for non-jazz styles.

The bass profile is chord-relative by construction (convert.py drops any note
whose chord is unknown), and FiloBass — jazz only — is the sole corpus on disk
with human chord annotations. That made jazz the only style with a bass
profile. Slakh has what's needed to break that: every track carries a labeled
Bass stem, a Drums stem and at least one chordal stem, and 97% of tracks join
to MidiCaps genre labels through UUID (= the Lakh MD5).

So: estimate the chord from the CHORDAL stems, then read the bass against it.

Two things make this honest rather than circular:

  1. The bass stem is EXCLUDED from chord estimation. Including it would let
     the bass root define the chord and then "discover" that bass plays roots.
     Chords come from piano/guitar/organ/strings/pad/brass/reed only.
  2. A window with no confident chord is NC, and its bass notes are dropped —
     the same rule convert.py applies to FiloBass. Coverage is recorded per
     example so a consumer can see how much was actually read.

Estimated chords are weaker evidence than FiloBass's transcribed ones. The
emitted examples carry chord_source="estimated" and the profile builder caps
their confidence accordingly — measured, with the estimation step visible.

Usage: python3 slakh_bass.py [extract|summary]
"""
import json
import os
import sys
from collections import defaultdict

import mido
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from convert import (EXAMPLE_SCHEMA, STEPS_PER_BAR, Agg, _interval_hist,
                     degree_to_token, offbeat_weight, quantize)

SLAKH = "/media/ipsedesktop/ShareDrive1/ModelData/slakh2100_midi"
SPLITS = ("train", "validation", "test", "omitted")
CAPTIONS = os.path.expanduser("~/JamminCorpus/midicaps/train.json")
OUT_DIR = "/media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples"
OUT = os.path.join(OUT_DIR, "slakh_bass.jsonl")

# Harmony-bearing classes only. Synth Lead / Pipe / Sound effects are melodic
# or noisy; Bass and Drums are excluded by construction (see docstring).
CHORDAL = {"Piano", "Guitar", "Organ", "Strings", "Strings (continued)",
           "Synth Pad", "Brass", "Reed"}

WINDOW_BEATS = 2.0        # chords are estimated per half-bar
MIN_CHORD_SCORE = 0.55    # below this the window is NC
MIN_COVERAGE = 0.5        # drop a track if under half its bass notes get a chord
MIN_NOTES = 50
MIN_BARS = 8

# (kind, intervals). Ordered simple-first; ties break toward the simpler chord.
TEMPLATES = [
    ("maj",   (0, 4, 7)),
    ("min",   (0, 3, 7)),
    ("sus4",  (0, 5, 7)),
    ("dim",   (0, 3, 6)),
    ("aug",   (0, 4, 8)),
    ("7",     (0, 4, 7, 10)),
    ("min7",  (0, 3, 7, 10)),
    ("maj7",  (0, 4, 7, 11)),
    ("m7b5",  (0, 3, 6, 10)),
    ("min6",  (0, 3, 7, 9)),
    ("6",     (0, 4, 7, 9)),
]

# Semitone above the root -> FiloBass-style degree name, so the token mapping
# stays in ONE place (convert.degree_to_token).
INTERVAL_DEGREE = {0: "R", 1: "b9", 2: "9", 3: "b3", 4: "3", 5: "11",
                   6: "b5", 7: "5", 8: "b13", 9: "13", 10: "b7", 11: "7"}


def notes_with_duration(path):
    """[(pitch, start_beat, end_beat)] from one stem, in beats."""
    try:
        mid = mido.MidiFile(path)
    except Exception:
        return []
    tpb = mid.ticks_per_beat or 480
    out = []
    for track in mid.tracks:
        t = 0
        open_notes = {}
        for msg in track:
            t += msg.time
            if msg.type == "note_on" and msg.velocity > 0:
                open_notes.setdefault(msg.note, []).append(t)
            elif msg.type in ("note_off",) or (msg.type == "note_on" and msg.velocity == 0):
                starts = open_notes.get(msg.note)
                if starts:
                    s = starts.pop(0)
                    out.append((msg.note, s / tpb, t / tpb))
        for note, starts in open_notes.items():   # unterminated: give one beat
            for s in starts:
                out.append((note, s / tpb, s / tpb + 1.0))
    return out


def is_four_four(path):
    try:
        mid = mido.MidiFile(path)
    except Exception:
        return False
    sigs = [(m.numerator, m.denominator) for tr in mid.tracks for m in tr
            if m.type == "time_signature"]
    return all(s == (4, 4) for s in sigs)  # no meta at all -> assume 4/4


def chord_windows(chordal_notes, n_windows):
    """Per window, the best (root_pc, kind) or None when nothing is confident."""
    weights = [[0.0] * 12 for _ in range(n_windows)]
    for pitch, start, end in chordal_notes:
        if end <= start:
            continue
        w0 = int(start // WINDOW_BEATS)
        w1 = int((end - 1e-9) // WINDOW_BEATS)
        for w in range(max(0, w0), min(n_windows - 1, w1) + 1):
            lo = max(start, w * WINDOW_BEATS)
            hi = min(end, (w + 1) * WINDOW_BEATS)
            if hi > lo:
                weights[w][pitch % 12] += hi - lo

    out = []
    for w in range(n_windows):
        total = sum(weights[w])
        if total <= 0:
            out.append(None)
            continue
        best = None
        for root in range(12):
            for kind, tones in TEMPLATES:
                covered = sum(weights[w][(root + t) % 12] for t in tones)
                present = sum(1 for t in tones
                              if weights[w][(root + t) % 12] > 0.02 * total)
                score = (covered / total) * (present / len(tones))
                if best is None or score > best[0] + 1e-9:
                    best = (score, root, kind)
        out.append((best[1], best[2]) if best[0] >= MIN_CHORD_SCORE else None)
    return out


def genre_index():
    """md5 -> [genre tags], from MidiCaps captions."""
    caps = {}
    with open(CAPTIONS) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            md5 = os.path.basename(e["location"]).replace(".mid", "")
            caps[md5] = [str(x).lower() for x in e.get("genre", [])]
    return caps


def primary_genre(tags):
    """The corpus's own first tag, normalized. Never invented: a track with no
    tags is dropped rather than bucketed."""
    for t in tags:
        t = t.strip().lower()
        if t:
            return t
    return None


def track_example(track_dir, style, source_id):
    meta_path = os.path.join(track_dir, "metadata.yaml")
    try:
        meta = yaml.safe_load(open(meta_path))
    except Exception:
        return None
    stems = meta.get("stems") or {}
    bass_stem = None
    chordal = []
    for sid, s in sorted(stems.items()):
        if s.get("is_drum"):
            continue
        if s.get("inst_class") == "Bass":
            if bass_stem is None:
                bass_stem = sid
        elif s.get("inst_class") in CHORDAL:
            chordal.append(sid)
    if not bass_stem or not chordal:
        return None

    mdir = os.path.join(track_dir, "MIDI")
    bass_path = os.path.join(mdir, bass_stem + ".mid")
    if not os.path.exists(bass_path) or not is_four_four(bass_path):
        return None

    bass_notes = notes_with_duration(bass_path)
    if len(bass_notes) < MIN_NOTES:
        return None
    chordal_notes = []
    for sid in chordal:
        p = os.path.join(mdir, sid + ".mid")
        if os.path.exists(p):
            chordal_notes.extend(notes_with_duration(p))
    if not chordal_notes:
        return None

    end_beat = max(max(e for _, _, e in bass_notes),
                   max(e for _, _, e in chordal_notes))
    n_windows = int(end_beat // WINDOW_BEATS) + 1
    if n_windows < 4:
        return None
    chords = chord_windows(chordal_notes, n_windows)

    bars = defaultdict(dict)
    tone_counts = defaultdict(int)
    step_hist = [0] * STEPS_PER_BAR
    tone_given_beat = {"beat": defaultdict(int), "off": defaultdict(int)}
    transitions = defaultdict(lambda: defaultdict(int))
    offbeat = Agg()
    midis = []
    prev_token = None
    n_seen = 0

    for pitch, start, _end in sorted(bass_notes, key=lambda n: n[1]):
        n_seen += 1
        w = int(start // WINDOW_BEATS)
        if w >= n_windows or chords[w] is None:
            continue                      # NC window: dropped, same as FiloBass
        root, kind = chords[w]
        degree = INTERVAL_DEGREE[(pitch - root) % 12]
        token = degree_to_token(degree, kind)
        bar = int(start // 4)
        step, _dev = quantize(start % 4.0)
        bars[bar][step] = token
        tone_counts[token] += 1
        step_hist[step] += 1
        tone_given_beat["beat" if step % 4 == 0 else "off"][token] += 1
        if prev_token is not None:
            transitions[prev_token][token] += 1
        prev_token = token
        offbeat.add(offbeat_weight(step))
        midis.append(pitch)

    n_notes = sum(tone_counts.values())
    n_bars = len(bars)
    if n_notes < MIN_NOTES or n_bars < MIN_BARS:
        return None
    coverage = n_notes / max(1, n_seen)
    if coverage < MIN_COVERAGE:
        return None

    in_vocab = sum(c for t, c in tone_counts.items() if not t.startswith("x"))
    intervals = [abs(b - a) for a, b in zip(midis, midis[1:])]
    n_chorded = sum(1 for c in chords if c is not None)
    return {
        "example_schema": EXAMPLE_SCHEMA,
        "source": "slakh",
        "source_id": source_id,
        "style": style,
        "sub_style": None,
        "role": "bass",
        "chord_source": "estimated",       # NOT a human transcription
        "chord_coverage": coverage,        # share of bass notes that got a chord
        "chord_window_coverage": n_chorded / max(1, n_windows),
        "bars": n_bars,
        "notes": n_notes,
        "bass_density": n_notes / max(1, n_bars) / STEPS_PER_BAR,
        "tone_fractions": {t: c / n_notes for t, c in sorted(tone_counts.items())},
        "in_vocab_fraction": in_vocab / n_notes,
        "offbeat_mass": offbeat.mean(),
        "mean_interval_semitones": sum(intervals) / len(intervals) if intervals else 0.0,
        "step_hist": step_hist,
        "tone_given_beat": {k: dict(v) for k, v in tone_given_beat.items()},
        "interval_hist": _interval_hist(intervals),
        "tone_transitions": {a: dict(b) for a, b in transitions.items()},
        "bar_tokens": [{str(s): t for s, t in sorted(bars[m].items())}
                       for m in sorted(bars)],
    }


def extract():
    caps = genre_index()
    print(f"midicaps index: {len(caps)} files")
    examples = []
    stats = defaultdict(int)
    for split in SPLITS:
        root = os.path.join(SLAKH, split)
        if not os.path.isdir(root):
            continue
        for track in sorted(os.listdir(root)):
            track_dir = os.path.join(root, track)
            meta_path = os.path.join(track_dir, "metadata.yaml")
            if not os.path.exists(meta_path):
                continue
            stats["tracks"] += 1
            try:
                uuid = yaml.safe_load(open(meta_path)).get("UUID")
            except Exception:
                uuid = None
            tags = caps.get(uuid)
            if not tags:
                stats["no_genre"] += 1
                continue
            style = primary_genre(tags)
            if not style:
                stats["no_genre"] += 1
                continue
            ex = track_example(track_dir, style, f"{split}/{track}")
            if ex is None:
                stats["rejected"] += 1
                continue
            examples.append(ex)
            stats["kept"] += 1
            if stats["kept"] % 100 == 0:
                print(f"  ...{stats['kept']} kept / {stats['tracks']} scanned",
                      flush=True)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT, "w") as f:
        for e in examples:
            f.write(json.dumps(e) + "\n")
    by_style = defaultdict(int)
    for e in examples:
        by_style[e["style"]] += 1
    print(f"\nscanned {stats['tracks']} tracks: kept {stats['kept']}, "
          f"rejected {stats['rejected']} (no bass/chordal stem, non-4/4, too "
          f"short, or chord coverage < {MIN_COVERAGE}), "
          f"{stats['no_genre']} without a MidiCaps genre tag")
    print("per style:")
    for s in sorted(by_style, key=lambda s: -by_style[s]):
        print(f"   {s:20s} {by_style[s]}")
    print(f"-> {OUT}")


def summary():
    if not os.path.exists(OUT):
        print("no slakh_bass.jsonl - run extract first")
        return
    ex = [json.loads(l) for l in open(OUT)]
    by_style = defaultdict(list)
    for e in ex:
        by_style[e["style"]].append(e)
    print(f"{'style':<16}{'n':>5}{'notes':>9}{'cover':>7}{'dens':>7}"
          f"{'offbeat':>9}{'in-vocab':>10}  top tones")
    for s in sorted(by_style, key=lambda s: -len(by_style[s])):
        es = by_style[s]
        n = len(es)
        tot = defaultdict(float)
        for e in es:
            for t, f in e["tone_fractions"].items():
                tot[t] += f / n
        top = ", ".join(f"{t}={tot[t]:.2f}" for t in
                        sorted(tot, key=lambda t: -tot[t])[:5])
        print(f"{s:<16}{n:>5}{sum(e['notes'] for e in es):>9}"
              f"{sum(e['chord_coverage'] for e in es)/n:>7.2f}"
              f"{sum(e['bass_density'] for e in es)/n:>7.3f}"
              f"{sum(e['offbeat_mass'] for e in es)/n:>9.3f}"
              f"{sum(e['in_vocab_fraction'] for e in es)/n:>10.3f}  {top}")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "extract"
    if what == "extract":
        extract()
        summary()
    elif what == "summary":
        summary()
