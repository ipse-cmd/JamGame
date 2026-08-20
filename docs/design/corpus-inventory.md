# Corpus inventory — what genres we can actually measure

Written 2026-08-20, after the Slakh2100 MIDI-only redux landed. Answers one
question: for any given genre and role, is there enough real data to build a
profile, or would we be fabricating?

The standing rule applies throughout: profiles store **measured distributions
with provenance**. A genre with no data gets no profile — not an interpolated
one.

## Sources on disk

| source | size | what it labels | genre labels? | license |
|---|---|---|---|---|
| **GMD** (`~/JamminCorpus/groove`) | 8.9 MB | drums, human timing + velocity | **yes**, 18 styles | CC BY 4.0 |
| **FiloBass** (`~/JamminCorpus/filobass`) | 877 MB | bass + chord changes | jazz only | CC BY 4.0 |
| **POP909** (`~/JamminCorpus/POP909-Dataset`) | 153 MB | melody + piano accompaniment + chords | pop only | MIT |
| **POP909-CL** | 85 MB | as above, cleaned chord annotations | pop only | MIT |
| **Lakh full** (`~/JamminCorpus/lmd_full`) | 6.0 GB | multi-instrument, program numbers | via MidiCaps | research use |
| **MidiCaps** (`~/JamminCorpus/midicaps`) | 2.0 GB | captions: genre, mood, tempo, key | **yes**, 168,385 files | CC BY-NC-SA 4.0 |
| **Slakh2100 MIDI-only** (`ModelData/slakh2100_midi`) | 226 MB | **labeled stems** (inst_class, is_drum) | via UUID→MidiCaps, 97% hit | CC BY-NC 4.0 |
| **BabySlakh** (`ModelData/babyslakh_16k`) | 2.0 GB | as above, 20 tracks | as above | CC BY-NC 4.0 |

Two provenance notes that matter:

- **Slakh's UUID *is* the Lakh MD5.** `metadata.yaml` carries
  `lmd_midi_dir: lmd_matched/G/J/U/TR.../<uuid>.mid`, and MidiCaps is indexed by
  that same hash — so every Slakh track can be genre-labeled by joining on UUID.
  Measured hit rate: **1659/1710 = 97.0%**.
- **NC licensing** (MidiCaps, Slakh) is compatible with how we use it — we ship
  measured distributions, never corpus content — but it is stricter than
  GMD/FiloBass/POP909. Keep the distinction visible in profile `source` strings.

## What's built today

Per-style profile coverage (`ModelData/JamminCorpusExamples/profiles/`).
Confidence is the profile's own gating: **H**igh / **M**edium / **L**ow /
**U**nknown. `~` marks a bass profile whose chords were **estimated** rather
than transcribed (see "Chord estimation" below).

| style | drums (perf/events) | bass (perf/events) | interaction (pairs) |
|---|---|---|---|
| **jazz** | 39 / 30,073 [H] | 48 / 53,072 [H] | **3,127 [H]** |
| **electronic** | — | ~581 / 263,127 [M] | **1,934 [H]** |
| **pop** | 6 / 1,484 [L] | ~692 / 290,819 [M] | 729 [H] |
| **rock** | 167 / 87,850 [H] | ~113 / 57,974 [M] | 121 [H] |
| latin | 36 / 66,138 [H] | — | — |
| funk | 31 / 30,449 [H] | — | — |
| hiphop | 26 / 10,914 [H] | — | — |
| neworleans | 13 / 18,900 [M] | — | — |
| afrobeat | 10 / 16,499 [M] | — | — |
| soul | 10 / 4,303 [M] | — | — |
| afrocuban | 7 / 16,432 [L] | — | — |
| dance | 7 / 8,095 [L] | — | — |
| soundtrack | — | ~34 / 11,318 [M] | 26 [M] |
| classical | — | ~19 / 5,865 [M] | 33 [M] |
| blues / country / punk / reggae / highlife / middleeastern | 1–5 perf [L] | — | — |
| ambient / easylistening / instrumentalpop | — | 1–6 perf [L] | 1–7 [L/U] |
| all (unlabeled) | — | — | 6,030 [H] |

**Four styles now carry the two roles the AI player actually uses** (bass +
interaction), where before only jazz did.

### The measured style axis

The interaction numbers separate the styles rather than converging, which is
the point — a prior that scored every style the same would be worthless:

| style | bass\|kick | bass\|no-kick | density corr | n |
|---|---|---|---|---|
| jazz | 0.668 | 0.201 | +0.21 | 3,127 |
| electronic | 0.696 | 0.204 | +0.30 | 1,934 |
| pop | 0.782 | 0.154 | +0.37 | 729 |
| rock | 0.790 | 0.211 | +0.37 | 121 |

Jazz bass is the least locked to the kick and tracks drum density most loosely;
pop and rock are the most locked. Bass tone vocabulary separates the same way —
jazz spends 33% of its notes on the root, pop 49%, classical 57%.

**The jazz numbers survived a 11.7× increase in sample size** (268 → 3,127
pairs: `bass|kick` 0.670 → 0.668, `bass|no-kick` 0.196 → 0.201, corr +0.23 →
+0.21). That is the strongest evidence available that the original measurement
was real and not an artifact of a thin sample.

## Chord estimation (`slakh_bass.py`)

The bass profile is chord-relative by construction, and FiloBass — jazz only —
was the only corpus on disk with human chord annotations. Slakh breaks that
open: every track has a labeled Bass stem, a Drums stem, and chordal stems.
Chords are estimated per half-bar by template-matching pitch-class mass from
the **chordal stems only**.

Two properties keep it honest:

- **The bass stem is excluded from chord estimation.** Including it would let
  the bass root define the chord and then "discover" that bass plays roots.
- **A window with no confident chord is NC and its bass notes are dropped** —
  the same rule `convert.py` applies to FiloBass. Per-example coverage is
  recorded; the kept set runs 0.95–1.00.

Result: 1,454 examples from 2,100 tracks (582 rejected for missing stems,
non-4/4, length, or coverage < 0.5; 64 untagged). Sanity check: the estimated
tone distribution is root-dominant (R ≈ 0.45–0.57 by style) where random chord
assignment would give ≈ 0.08.

Estimated chords are weaker evidence than transcribed ones, so these profiles
carry `chord_source: "estimated"` and their confidence is **capped at MEDIUM**
regardless of n.

## Ceilings — what each role could reach

### Drums: GMD, already fully mined
1,150 performances / 18 styles (503 beats, 647 fills; 1,138 of them 4/4).
The drum table above **is** the ceiling — there is no unmined GMD left. More
drum styles means a new corpus, not a bigger scan.

### Bass: jazz transcribed, four more styles estimated
FiloBass is 48 tunes × 6 representations = 288 files; the 48 in the profile is
**full coverage**, not a cap — jazz bass is done and cannot grow without a new
corpus. Everything non-jazz now comes from Slakh's labeled `Bass` stems with
estimated chords, which is capped by Slakh's own size (2,100 tracks) rather
than by a scan setting.

### Interaction (drums↔bass): jazz uncapped, the rest still capped
Genre-tagged file counts in MidiCaps against what is now scanned:

| genre | MidiCaps files | scanned | Slakh tracks | interaction pairs |
|---|---|---|---|---|
| electronic | 94,482 | 4,000 (cap) | 979 | 1,934 |
| pop | 92,790 | 0 | 1,212 | 729 |
| classical | 43,251 | 0 | 143 | 33 |
| rock | 33,755 | 0 | 508 | 121 |
| soundtrack | 31,943 | 0 | 166 | 26 |
| ambient | 18,152 | 0 | 178 | 7 |
| **jazz** | **4,563** | **4,563 (all)** | 3 | **3,127** |
| easylistening | 3,711 | 0 | — | 4 |
| instrumentalpop | 3,313 | 0 | 28 | 1 |
| dance | 2,949 | 0 | 2 | — |
| experimental | 1,657 | 0 | — | — |
| folk | 1,615 | 0 | — | — |

Jazz is now **exhaustive** — every jazz-tagged file in MidiCaps is read, so
that number cannot grow either. The remaining headroom is entirely in
electronic (4,000 of 94,482 scanned) and in genres with no scan at all: pop,
classical, rock, soundtrack, ambient. Those are `GENRES` entries in
`interaction.py`, not new machinery.

The original cap of 400/genre was set when Slakh was assumed to be the
heavyweight and Lakh the stopgap. It was the other way round: Slakh holds
**3** jazz tracks, because it inherits Lakh's pop/rock/electronic distribution.
The 104 GB audio tarball would not have changed this — same 2,100 tracks.

### Comping (chords): unmined
POP909's 909 songs carry melody + piano accompaniment + chord annotations —
the measured source that would replace the five hand-authored comp patterns in
`chord_comp.gd`. Pop only. Nothing built yet.

## Gaps, ranked by what they'd unlock

1. **POP909 → comping profiles.** The largest unmined corpus on disk, and the
   only role still running entirely on hand-authored patterns.
2. **Add `GENRES` entries for pop / rock / classical** in `interaction.py`.
   Their interaction pairs currently come only from Slakh; tens of thousands of
   tagged Lakh files are unscanned. Pure CPU.
3. **A style selector in-game.** Four styles now have bass + interaction, but
   `intent_bass_policy.gd` hard-codes `res://data/style_profiles/jazz.json`.
   The data for the EDM-vs-jazz vibe axis exists; the wiring does not.
4. **Validate estimated chords against a transcribed reference.** POP909 has
   both chord annotations and MIDI — running `slakh_bass.py`'s estimator over
   it and scoring against its labels would put a real error bar on the four
   `~` bass profiles, replacing the blanket MEDIUM cap with a measured one.
5. **Drums beyond GMD's 18 styles** needs a new corpus. Lowest priority; GMD's
   coverage of the styles we care about is already High-confidence.

## Filesystem note

`slakh2100_midi` is 226 MB of content but occupies **30 GB** on ShareDrive1:
26,293 small files (8.6 KB average) against exfat's **512 KB allocation unit**
wastes ~13 GB in slack, and directories cost the same 512 KB each.
exfat also has no sparse-file support and rewrites its metadata poorly under
concurrent writers — both bit us during the Slakh download. Any future
many-small-files corpus belongs on the ext4 root disk.
