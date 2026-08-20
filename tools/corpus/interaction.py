#!/usr/bin/env python3
"""Interaction axis: drums↔bass coupling measured from aligned multitracks.

Sources:
- Slakh2100 (clean per-stem instrument labels): BabySlakh plus the full
  MIDI-only redux. The 104GB FLAC tarball holds the same MIDI and audio we
  never read, so the 226MB MIDI-only distribution is the source. CC-BY-NC-4.0
  - measured distributions only, no content ships.
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
SLAKH = "/media/ipsedesktop/ShareDrive1/ModelData/slakh2100_midi"
SLAKH_SPLITS = ("train", "validation", "test", "omitted")
LMD = os.path.expanduser("~/JamminCorpus/lmd_full")
CAPTIONS = os.path.expanduser("~/JamminCorpus/midicaps/train.json")
EX_DIR = "/media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples"
PROFILE_DIR = os.path.join(EX_DIR, "profiles")

# Per-genre scan caps. Jazz is UNCAPPED: Slakh contributes 3 jazz tracks (it
# inherits Lakh's pop/rock/electronic distribution), so Lakh's 4,563 jazz-tagged
# files are the entire jazz supply, not a stopgap. The old flat 400 was set when
# Slakh was assumed to be the heavyweight — backwards. Caps stay LOGGED.
LAKH_CAP_PER_GENRE = 4000
LAKH_CAP_OVERRIDE = {"jazz": None}  # None = no cap
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


def slakh_pair(track_dir):
    """(kicks, drums, bass) onsets from one Slakh track's labeled stems.

    Same layout in BabySlakh and the full MIDI-only redux: metadata.yaml names
    each stem's inst_class / is_drum, MIDI/<stem>.mid holds that stem alone.
    """
    meta_path = os.path.join(track_dir, "metadata.yaml")
    if not os.path.exists(meta_path):
        return None
    try:
        meta = yaml.safe_load(open(meta_path))
    except Exception:
        return None
    drum_stem = bass_stem = None
    for sid, s in (meta.get("stems") or {}).items():
        if s.get("is_drum") and drum_stem is None:
            drum_stem = sid
        if s.get("inst_class") == "Bass" and bass_stem is None:
            bass_stem = sid
    if not (drum_stem and bass_stem):
        return None
    try:
        dmid = mido.MidiFile(os.path.join(track_dir, "MIDI", drum_stem + ".mid"))
        bmid = mido.MidiFile(os.path.join(track_dir, "MIDI", bass_stem + ".mid"))
    except Exception:
        return None
    kicks, drums, _ = onsets_from_track(dmid, True, False)
    if not drums:  # drum stem not on ch9: every note is a drum, kick = low notes
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
    return measure(kicks, drums, bass)


def slakh_roots():
    """(source_name, track_dir) for every Slakh track available locally.

    BabySlakh is flat (20 tracks); the full MIDI-only redux nests tracks under
    train/validation/test/omitted. The 104GB FLAC tarball carries the same MIDI
    and nothing else we read, so the MIDI-only distribution is the source.
    """
    if os.path.isdir(BABY):
        for track in sorted(os.listdir(BABY)):
            d = os.path.join(BABY, track)
            if os.path.isdir(d):
                yield "babyslakh", d
    for split in SLAKH_SPLITS:
        root = os.path.join(SLAKH, split)
        if not os.path.isdir(root):
            continue
        for track in sorted(os.listdir(root)):
            d = os.path.join(root, track)
            if os.path.isdir(d):
                yield f"slakh/{split}", d


def extract():
    examples = []
    # --- Slakh: labeled stems (BabySlakh + full MIDI-only redux) ---
    if yaml is not None:
        # Slakh ships no genre labels, but its UUID IS the Lakh MD5, so
        # MidiCaps supplies them (97% hit). Without this every Slakh pair lands
        # in the unlabeled "all" bucket and improves no style in particular.
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from slakh_bass import genre_index, primary_genre
        caps = genre_index()
        per_source = defaultdict(int)
        untagged = 0
        seen_uuid = set()
        for source, track_dir in slakh_roots():
            m = slakh_pair(track_dir)
            if not m:
                continue
            # BabySlakh tracks are a subset of the full set - dedup by UUID so
            # the same performance is not counted twice.
            try:
                uuid = yaml.safe_load(open(os.path.join(track_dir, "metadata.yaml"))).get("UUID")
            except Exception:
                uuid = None
            if uuid and uuid in seen_uuid:
                continue
            if uuid:
                seen_uuid.add(uuid)
            genre = primary_genre(caps.get(uuid) or [])
            if genre is None:
                genre = "all"          # untagged: unlabeled bucket, not guessed
                untagged += 1
            m.update({"source": source, "source_id": os.path.basename(track_dir),
                      "genre": genre})
            examples.append(m)
            per_source[source] += 1
        for s in sorted(per_source):
            print(f"{s}: {per_source[s]} pairs")
        print(f"slakh genre labels: {untagged} pairs had no MidiCaps tag "
              f"-> unlabeled 'all' bucket")

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
                if not pred(" ".join(genres)):
                    continue
                cap = LAKH_CAP_OVERRIDE.get(gname, LAKH_CAP_PER_GENRE)
                if cap is None or len(lists[gname]) < cap:
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
        cap = LAKH_CAP_OVERRIDE.get(gname, LAKH_CAP_PER_GENRE)
        note = "UNCAPPED - every tagged file listed" if cap is None else \
               f"cap {cap} of the full corpus - capped, not exhaustive"
        print(f"lakh/{gname}: scanned {scanned}/{len(locs)} listed "
              f"({note}), kept {kept} pairs")

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
        if e["genre"] != "all":
            groups["all"].append(e)  # genre "all" IS the bucket - don't count it twice
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
            "source": "Slakh2100 MIDI-only redux + Lakh(MidiCaps-filtered, capped)",
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
