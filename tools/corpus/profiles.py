#!/usr/bin/env python3
"""JamStyleProfile estimation + the separability gate.

Profiles are PARTIAL and role-specific with provenance and confidence — a
style only gets a role section when a corpus supplied one (no inventing
"roughly opposite numbers and calling it techno"). Every estimate carries n,
and distributions are stored, not just means: profiles represent "this is
what we measured", never "this is what jazz is".

The gate (run before profiles may influence gameplay): held-out, label-free
classification of GMD performances by nearest-profile likelihood. If styles
stay separable after conversion to Jammin features, the representation isn't
washing everything into generic accompaniment.

Usage:
    python3 profiles.py build      # estimate profiles from train-split examples
    python3 profiles.py validate   # held-out classification report (the gate)
"""
import json
import math
import os
import sys
from collections import defaultdict

EX_DIR = "/media/ipsedesktop/ShareDrive1/ModelData/JamminCorpusExamples"
PROFILE_DIR = os.path.join(EX_DIR, "profiles")
PROFILE_SCHEMA = 1
LANES = ("kick", "snare", "hat", "perc")
POSITIONS = ("down", "e", "and", "a")
MIN_TEST_N = 5  # styles with fewer held-out performances are reported but not scored


def load(name):
    path = os.path.join(EX_DIR, name)
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []


def confidence(n_perf, n_events):
    if n_perf >= 20 and n_events >= 2000:
        return "HIGH"
    if n_perf >= 8:
        return "MEDIUM"
    if n_perf >= 1:
        return "LOW"
    return "UNKNOWN"


def gaussian_stats(values):
    n = len(values)
    mean = sum(values) / n
    var = sum((v - mean) ** 2 for v in values) / n if n > 1 else 0.0
    return {"mean": mean, "std": math.sqrt(var), "n": n}


# ------------------------------------------------------------------ building

def drum_profile(examples):
    """Distributions over a set of performances (train split, beats only)."""
    step_counts = {l: [0] * 16 for l in LANES}
    dev_counts = {p: [0] * 10 for p in POSITIONS}
    scalars = defaultdict(list)
    n_events = 0
    for e in examples:
        for l in LANES:
            for s in range(16):
                step_counts[l][s] += e["step_hist"][l][s]
                n_events += e["step_hist"][l][s]
        for p in POSITIONS:
            for b in range(10):
                dev_counts[p][b] += e["dev_hist"][p][b]
        for l in LANES:
            scalars[f"{l}_density"].append(e["lane_density"][l])
        scalars["offbeat_mass"].append(e["offbeat_mass"])
        for p in POSITIONS:
            g = e["groove"][p]
            if g["n"] > 0:
                scalars[f"dev_{p}"].append(g["dev_mean_pct16"])
                scalars[f"vel_{p}"].append(g["vel_mean"])
    return {
        "n_performances": len(examples),
        "n_events": n_events,
        "step_distribution": step_counts,     # counts; consumers normalize
        "timing_offset_hist": dev_counts,     # 10%-bins of a 16th, -50..+50
        "scalar_distributions": {k: gaussian_stats(v) for k, v in sorted(scalars.items())},
    }


def bass_profile(examples):
    tones = defaultdict(int)
    tone_beat = {"beat": defaultdict(int), "off": defaultdict(int)}
    step_hist = [0] * 16
    interval_hist = [0] * 13
    transitions = defaultdict(lambda: defaultdict(int))
    scalars = defaultdict(list)
    n_events = 0
    for e in examples:
        for t, f in e["tone_fractions"].items():
            tones[t] += round(f * e["notes"])
        for k in ("beat", "off"):
            for t, c in e["tone_given_beat"][k].items():
                tone_beat[k][t] += c
        for s in range(16):
            step_hist[s] += e["step_hist"][s]
        for i in range(13):
            interval_hist[i] += e["interval_hist"][i]
        for a, row in e["tone_transitions"].items():
            for b, c in row.items():
                transitions[a][b] += c
        n_events += e["notes"]
        scalars["bass_density"].append(e["bass_density"])
        scalars["offbeat_mass"].append(e["offbeat_mass"])
        scalars["mean_interval"].append(e["mean_interval_semitones"])
        scalars["in_vocab_fraction"].append(e["in_vocab_fraction"])
    return {
        "n_performances": len(examples),
        "n_events": n_events,
        "tone_distribution": dict(sorted(tones.items())),
        "tone_given_beat": {k: dict(sorted(v.items())) for k, v in tone_beat.items()},
        "onset_step_distribution": step_hist,
        "interval_distribution": interval_hist,
        "tone_transition_counts": {a: dict(sorted(b.items())) for a, b in sorted(transitions.items())},
        "scalar_distributions": {k: gaussian_stats(v) for k, v in sorted(scalars.items())},
    }


def build():
    os.makedirs(PROFILE_DIR, exist_ok=True)
    gmd = [e for e in load("gmd.jsonl") if e["kind"] == "beat"]
    train = [e for e in gmd if e["split"] == "train"]
    by_style = defaultdict(list)
    for e in train:
        by_style[e["style"]].append(e)

    filo = load("filobass.jsonl")
    styles = sorted(set(by_style) | {"jazz"})
    for style in styles:
        profile = {"profile_schema": PROFILE_SCHEMA, "style_id": style, "roles": {}}
        if by_style.get(style):
            es = by_style[style]
            profile["roles"]["drums"] = {
                "profile": drum_profile(es),
                "source": "GMD (train split, beats only)",
                "confidence": confidence(len(es), sum(sum(sum(e["step_hist"][l]) for l in LANES) for e in es)),
            }
        if style == "jazz" and filo:
            profile["roles"]["bass"] = {
                "profile": bass_profile(filo),
                "source": "FiloBass v1.0.0",
                "confidence": confidence(len(filo), sum(e["notes"] for e in filo)),
            }
        # Roles with no corpus stay absent — absent, not fabricated.
        with open(os.path.join(PROFILE_DIR, f"{style}.json"), "w") as f:
            json.dump(profile, f, indent=1)
        roles = {r: profile["roles"][r]["confidence"] for r in profile["roles"]}
        print(f"{style:>14}: {roles}")


# ---------------------------------------------------------------- validation

def _loglik_drums(example, prof, prior_strength=1.0):
    """Multinomial log-likelihood of the performance's placement vocabulary
    under a style's step distribution + Gaussian terms for timing/velocity."""
    ll = 0.0
    for l in LANES:
        counts = prof["step_distribution"][l]
        total = sum(counts) + 16 * prior_strength
        for s in range(16):
            c = example["step_hist"][l][s]
            if c:
                p = (counts[s] + prior_strength) / total
                ll += c * math.log(p)
    for key in ("offbeat_mass",):
        g = prof["scalar_distributions"][key]
        std = max(0.02, g["std"])
        ll += -0.5 * ((example["offbeat_mass"] - g["mean"]) / std) ** 2 - math.log(std)
    for p in POSITIONS:
        g = prof["scalar_distributions"].get(f"dev_{p}")
        ex = example["groove"][p]
        if g and g["n"] > 3 and ex["n"] > 0:
            std = max(2.0, g["std"])
            ll += -0.5 * ((ex["dev_mean_pct16"] - g["mean"]) / std) ** 2 - math.log(std)
    return ll


def validate():
    gmd = [e for e in load("gmd.jsonl") if e["kind"] == "beat"]
    test = [e for e in gmd if e["split"] in ("test", "validation")]
    profs = {}
    for fn in os.listdir(PROFILE_DIR):
        p = json.load(open(os.path.join(PROFILE_DIR, fn)))
        if "drums" in p["roles"]:
            profs[p["style_id"]] = p["roles"]["drums"]["profile"]

    test_by_style = defaultdict(list)
    for e in test:
        test_by_style[e["style"]].append(e)
    scored_styles = sorted(s for s, es in test_by_style.items()
                           if len(es) >= MIN_TEST_N and s in profs)
    print(f"held-out performances: {len(test)}; scored styles (n>={MIN_TEST_N}): {scored_styles}")

    confusion = defaultdict(lambda: defaultdict(int))
    correct = total = 0
    for true_style in scored_styles:
        for e in test_by_style[true_style]:
            best, best_ll = None, None
            for s in scored_styles:
                ll = _loglik_drums(e, profs[s])
                if best_ll is None or ll > best_ll:
                    best, best_ll = s, ll
            confusion[true_style][best] += 1
            correct += best == true_style
            total += 1
    print(f"\nnearest-profile accuracy: {correct}/{total} = {100*correct/total:.0f}% "
          f"(chance = {100/len(scored_styles):.0f}%)")
    print(f"\n{'true \\ pred':>12} " + " ".join(f"{s[:6]:>6}" for s in scored_styles))
    for t in scored_styles:
        row = " ".join(f"{confusion[t][s]:>6}" for s in scored_styles)
        n = sum(confusion[t].values())
        acc = confusion[t][t] / n if n else 0
        print(f"{t:>12} {row}   ({100*acc:.0f}%)")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("build", "all"):
        build()
    if what in ("validate", "all"):
        print()
        validate()
