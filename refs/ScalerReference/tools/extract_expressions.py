#!/usr/bin/env python3
"""
Extract Scaler 3's performance/expression library.

The chord + scale banks came out of loose JSON blobs in the binary (see extract.py).
The *performance* data does not live there - it's a whole ZIP archive appended into
the binary's data section, holding 1274 JSON pattern files under ExpressionsData/.

Run from the scalerDiscovery folder:
    python3 ScalerReference/tools/extract_expressions.py

Writes:
    ScalerReference/banks/expressions.json    normalized pattern bank
    ScalerReference/banks/expressions.csv     one row per pattern (index / lookup)
    <scratch>/exp/                            raw ExpressionsData tree (optional, --raw)
"""
import json, os, re, struct, sys, zipfile, io, csv, statistics, collections

BIN = 'Scaler 3.app/Contents/MacOS/Scaler 3'
OUT = 'ScalerReference/banks'


def find_zips(data):
    """Locate embedded ZIPs by walking End-Of-Central-Directory records.

    The binary is universal (two arch slices), so the same archive appears twice.
    """
    hits = []
    for m in re.finditer(re.escape(b'PK\x05\x06'), data):
        e = m.start()
        if e + 22 > len(data):
            continue
        _, _, _, _, ntot, cdsize, cdoff, clen = struct.unpack('<IHHHHIIH', data[e:e + 22])
        if not ntot or not cdsize:
            continue
        start = e - cdsize - cdoff
        if start >= 0 and data[start:start + 4] == b'PK\x03\x04':
            hits.append((start, e + 22 + clen, ntot))
    return hits


def load_patterns(data):
    start, end, ntot = find_zips(data)[0]          # both slices are identical
    zf = zipfile.ZipFile(io.BytesIO(data[start:end]))
    pats = []
    for n in zf.namelist():
        if not n.endswith('.json') or n.startswith('__MACOSX'):
            continue
        pats.append(json.loads(zf.read(n)))
    return pats, ntot


# grids we consider "on the beat" - anything else is authored micro-timing
GRIDS = [1.0, 0.5, 1 / 3, 0.25, 1 / 6, 0.125, 1 / 12]


def grid_residual(beats):
    return min((beats - round(beats / g) * g for g in GRIDS), key=abs)


def normalize(p):
    md = p['expressionsData']['metaData']
    tpb = md['ticksPerBeat']
    sig = md['timeSignature']
    beats_per_bar = sig['numerator'] * 4 / sig['denominator']

    events, nudges = [], []
    for e in p['expressionsData']['events']:
        pos = e['position'] / tpb
        events.append([
            round(pos, 6),
            e['noteIndex'],
            e['velocity'],
            round(e['duration'] / tpb, 6),
        ])
        r = grid_residual(pos)
        if abs(r) > 1e-9:
            nudges.append(r)
    events.sort()

    length = md['lastPosition'] / tpb
    vels = [e[2] for e in events]
    return {
        'name': p['name'],
        'id': p['cleanName'],
        'type': p.get('type'),
        'folder': p['folder'],
        'subfolder': p['subfolder'],
        'uuid': p['uuid'],
        'octaveDiff': p['octaveDiff'],
        'timeSignature': [sig['numerator'], sig['denominator']],
        'lengthBeats': round(length, 6),
        'bars': round(length / beats_per_bar, 4),
        'poolSize': len(md['allNotesNumber']),
        'refPitches': md['allNotesNumber'],
        'maxNoteIndex': max((e[1] for e in events), default=-1),
        'noteCount': len(events),
        'velocityMean': round(statistics.mean(vels), 1) if vels else 0,
        'velocitySd': round(statistics.pstdev(vels), 1) if vels else 0,
        'nudgedFraction': round(len(nudges) / len(events), 3) if events else 0,
        'nudgeMeanBeats': round(statistics.mean([abs(x) for x in nudges]), 5) if nudges else 0,
        # [positionBeats, noteIndex, velocity, durationBeats]
        'events': events,
    }


def main():
    if not os.path.exists(BIN):
        sys.exit('run me from the scalerDiscovery folder (Scaler 3.app not found)')
    data = open(BIN, 'rb').read()
    raw, ntot = load_patterns(data)
    print(f'embedded zip: {ntot} entries -> {len(raw)} pattern JSONs')

    pats = sorted((normalize(p) for p in raw), key=lambda x: (x['folder'], x['subfolder'], x['name']))
    os.makedirs(OUT, exist_ok=True)

    with open(f'{OUT}/expressions.json', 'w') as f:
        json.dump(pats, f, ensure_ascii=False, separators=(',', ':'))
    print(f'wrote {OUT}/expressions.json ({len(pats)} patterns, '
          f'{sum(p["noteCount"] for p in pats)} events)')

    cols = ['id', 'name', 'folder', 'subfolder', 'type', 'timeSignature', 'bars',
            'lengthBeats', 'noteCount', 'poolSize', 'maxNoteIndex', 'octaveDiff',
            'velocityMean', 'velocitySd', 'nudgedFraction', 'nudgeMeanBeats', 'uuid']
    with open(f'{OUT}/expressions.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(cols)
        for p in pats:
            row = dict(p, timeSignature='%d/%d' % tuple(p['timeSignature']))
            w.writerow([row[c] for c in cols])
    print(f'wrote {OUT}/expressions.csv')

    by = collections.Counter((p['folder']) for p in pats)
    for k, v in sorted(by.items()):
        print(f'  {k:18s} {v:4d}')

    if '--raw' in sys.argv:
        start, end, _ = find_zips(data)[0]
        open('expressions_raw.zip', 'wb').write(data[start:end])
        print('wrote expressions_raw.zip')


if __name__ == '__main__':
    main()
