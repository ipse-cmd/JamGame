# Design notes — chord-progression puzzle game

Planning reference for building a Scaler-inspired progression builder. Language-agnostic
(pseudocode). The point is the *logic*; port it to Unreal/C++ when you're on your dev machine.

---

## 1. The core idea

Scaler's "magic" is three reimplementable systems:

1. **Diatonic generation** — from a *key* (root + scale), produce the chords that "belong".
2. **Suggestion** — given the current chord, rank what should come next (functional harmony).
3. **Mood mapping** — scales (and chord choices) carry an emotional flavour; the player
   targets a mood.

A puzzle game = give the player a **target** (a mood, a partial progression, or a
"famous" shape) and a **limited bank of chords**, and let them assemble a progression that
satisfies a rule set. The suggestion engine powers hints, scoring, and the "feels right" check.

---

## 2. Data model (matches `banks/`)

```
Note        = 0..11                       // pitch class, C=0
ChordType   = { name, semitones[], symbol, isMinor }   // from chords.json
ScaleType   = { name, semitones[], moods[], parent, degree }  // from scales.json
Chord       = { root: Note, type: ChordType }          // a concrete chord
Key         = { tonic: Note, scale: ScaleType }
```

Voicing a chord: `for off in type.semitones: midi = 60 + key-octave + root + off`.

---

## 3. Diatonic chords (the bank for a given key)

Stack thirds on each scale degree, staying inside the scale.

```
function diatonicChords(key, sizes=[triad=3, seventh=4]):
    s = key.scale.semitones                  // e.g. major [0,2,4,5,7,9,11]
    n = len(s)
    chords = []
    for degree in 0..n-1:
        notes = []
        for step in 0..(size-1):
            scaleIdx = (degree + 2*step) % n
            octaveBump = 12 * ((degree + 2*step) // n)
            notes.add( (key.tonic + s[scaleIdx] + octaveBump) )
        chords.add( identify(notes - notes[0], rootPitch=notes[0]) )  // match to chords.json
    return chords
```

`identify()` = subtract the root from every note, sort, and match the resulting
semitone set against `chords.json` (exact match → chord name; near match → closest).
Major key triads come out as: **I ii iii IV V vi vii°** (maj, min, min, maj, maj, min, dim).

---

## 4. Functional harmony — the suggestion brain

Every diatonic degree has a **function**. In major:

| Degree | I | ii | iii | IV | V | vi | vii° |
|---|---|---|---|---|---|---|---|
| Function | **T** | S | T | **S** | **D** | T | D |

(T = Tonic/home/rest, S = Subdominant/motion, D = Dominant/tension.)
Minor key is the same shape rooted differently (i, ii°, III, iv, v/V, VI, VII).

The fundamental "grammar" — what tends to follow what:

```
T → anything            (home can move anywhere)
S → D  (strong)         S → T  (plagal, softer)      S → S
D → T  (resolution!)    D → vi (deceptive)           D ↛ S (avoid)
```

### Transition weights (major key, by degree 0..6 = I..vii°)
A simple, tunable weight matrix. Higher = more "expected/satisfying".

```
            to:  I    ii   iii  IV   V    vi   vii°
from I            -    3    2    4    5    3    1
from ii           2    -    1    1    5    1    2
from iii          2    3    -    3    2    4    1
from IV           3    2    1    -    5    2    3
from V            6    1    1    1    -    4    1     // V→I = strongest, V→vi = deceptive
from vi           2    4    2    4    3    -    1
from vii°         6    1    1    1    2    1    -     // vii°→I like V
```

This is the heart of it. Tune the numbers to taste; they encode "common-practice" feel.

---

## 5. Suggestion algorithm

```
function suggestNext(key, currentChord, options):
    diat   = diatonicChords(key)
    curIdx = indexOf(currentChord in diat)
    out = []
    for cand, candIdx in diat:
        score  = transitionWeight[curIdx][candIdx]          // grammar
        score -= 0.3 * voiceLeadingDistance(currentChord, cand)  // smoother = better
        score += moodBonus(cand, options.targetMood)        // optional
        out.add({ chord: cand, score, reason: explain(curIdx, candIdx) })
    return sortByScoreDesc(out)
```

### Voice-leading distance (smoothness)
Sum of minimal pitch-class movements between the two chords' notes — fewer/smaller
moves sounds smoother and is how good progressions actually connect.

```
function voiceLeadingDistance(a, b):
    total = 0
    for na in a.notes:                 // greedy nearest-note matching is fine to start
        total += min over nb in b.notes of circularDistance(na, nb)  // 0..6 each
    return total
```

### Mood bonus
`scales.json` carries `moods[]`; `mood_to_scales.json` is the reverse index.
For chord-level mood, derive from quality: minor/dim/extended = darker/tense,
major/sus = brighter/open. Add a small bonus when the candidate's flavour matches the target.

---

## 6. Borrowed / spice chords (beyond diatonic)

What makes progressions interesting — keep these as an "advanced bank":
- **Secondary dominants**: V-of-x (a dominant 7 a fifth above any diatonic chord) → tension toward a non-tonic.
- **Modal interchange**: borrow chords from the parallel minor/major (e.g. bVII, iv in major).
- **Tritone sub**: replace V7 with a dom7 a tritone away.
- **Neapolitan / augmented sixths**: classical colour.

Gate these behind difficulty tiers in the puzzle.

---

## 7. Puzzle mechanics (ideas)

| Mechanic | Rule | Powered by |
|---|---|---|
| **Mood match** | Reach a target mood (e.g. "Mysterious") in N chords | `mood_to_scales`, moodBonus |
| **Resolution** | Must end on a satisfying cadence (D→T or S→T) | functional grammar |
| **Limited bank** | Solve using only a given set of chords (like tile/word games) | diatonic + spice banks |
| **Smooth path** | Minimize total voice-leading distance | voiceLeadingDistance |
| **Match the shape** | Recreate a hidden famous progression by ear/hint | suggestion as hint engine |
| **No repeats / constraints** | Sudoku-style harmonic constraints | transition matrix as legal-move graph |

The transition matrix doubles as a **legal-move graph**: a "move" is legal if weight > threshold.
That turns harmony into a pathfinding/constraint puzzle.

---

## 8. Suggested build order

1. **Theory core** (no UI): load `chords.json`/`scales.json`, implement `diatonicChords` +
   `identify`. Verify major key → I ii iii IV V vi vii°.
2. **Suggestion**: transition matrix + voice-leading. Print ranked next-chords for a key.
3. **Audio**: trigger notes (any synth/MIDI). This is where it becomes fun.
4. **One puzzle type** (Mood match or Resolution) end-to-end.
5. **Spice chords + difficulty tiers**, then more puzzle types.

Do steps 1–2 anywhere (even Python on this Mac) to validate the logic, *then* port to Unreal.

---

## 9. Mood & taxonomy reference
- `banks/mood_to_scales.json` — 56 moods → scales (puzzle targets ready to use).
- `banks/taxonomy.json` — Scaler's genre/function/feel vocabulary (45 genres, 12 functions,
  50 feel tags). Inspiration for *your own* tagging — don't ship theirs verbatim.
