#!/usr/bin/env python3
"""Read the per-preset *.agr.json files and emit a master swing table (CSV + md)."""
import json, glob, os

HERE = os.path.dirname(os.path.abspath(__file__))
PPQN = 960
rows = []
for path in sorted(glob.glob(os.path.join(HERE, "*.agr.json"))):
    name = os.path.basename(path)[:-len(".agr.json")]
    d = json.load(open(path))
    s = d["swing_by_position"]                 # {0,1,2,3 -> dev_beats}
    nhits = len(d["hits"])
    # ticks per position; None if that position had no captured hits
    t = {p: (round(s[str(p)] * PPQN) if str(p) in s else None) for p in range(4)}
    rows.append((name, nhits, t))

def fam(n):
    for f in ("Base", "Push", "Shake", "Clave", "Trip"):
        if n.startswith("STL_" + f):
            return f
    return "?"

rows.sort(key=lambda r: ("_Base Push Shake Clave Trip".index(" "+fam(r[0]).split()[0]) if False else
                          ["Base","Push","Shake","Clave","Trip"].index(fam(r[0])), r[0]))

hdr = f"{'preset':<12}{'hits':>5}  {'down':>6}{'e':>6}{'and':>6}{'a':>6}   shape"
lines = [hdr, "-"*len(hdr)]
csv = ["preset,hits,down_ticks,e_ticks,and_ticks,a_ticks"]
for name, nh, t in rows:
    def c(p): return "  --" if t[p] is None else f"{t[p]:+d}"
    # crude shape label
    vals = [t[p] for p in range(4)]
    nz = [v for v in vals if v is not None]
    if all(v is not None and abs(v) <= 1 for v in vals):
        shape = "straight"
    elif t[1] is not None and t[3] is not None and (t[2] is None or abs(t[2]) <= 2) \
         and abs((t[0] or 0)) <= 2:
        shape = "16th swing (e+a only)"
    elif t[1] is not None and t[2] is not None and t[3] is not None and \
         abs(t[1]-t[2]) <= 4 and abs(t[2]-t[3]) <= 4 and abs((t[0] or 0)) <= 2:
        shape = "uniform lay-back (e=and=a)"
    elif None in vals:
        shape = "sparse / large-shift (see caveat)"
    else:
        shape = "complex / asymmetric"
    lines.append(f"{name:<12}{nh:>5}  {c(0):>6}{c(1):>6}{c(2):>6}{c(3):>6}   {shape}")
    csv.append(f"{name},{nh}," + ",".join("" if t[p] is None else str(t[p]) for p in range(4)))

table = "\n".join(lines)
print(table)
open(os.path.join(HERE, "SWING_SUMMARY.csv"), "w").write("\n".join(csv) + "\n")
open(os.path.join(HERE, "SWING_SUMMARY.txt"), "w").write(table + "\n")
print("\n-> wrote SWING_SUMMARY.csv and SWING_SUMMARY.txt")
