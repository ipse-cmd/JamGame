import json, re
B='Scaler 3.app/Contents/MacOS/Scaler 3'
data=open(B,'rb').read()
# Work the first copy region with some margin
region=data[36_000_000:39_000_000]
chunks=region.split(b'\x00')
found=[]
for c in chunks:
    c=c.strip()
    if len(c)<40: continue
    if not (c[:1] in b'{[' ): continue
    try:
        obj=json.loads(c.decode('utf-8'))
    except Exception:
        continue
    found.append(obj)

def classify(o):
    s=json.dumps(o)[:200]
    if isinstance(o,dict):
        # scales: values have 'parent scale'
        vals=list(o.values())
        if vals and isinstance(vals[0],dict) and 'parent scale' in vals[0]:
            return ('scales',len(o))
        if vals and isinstance(vals[0],dict) and 'superscript' in json.dumps(vals[0]):
            return ('chords?',len(o))
    if isinstance(o,list):
        if o and isinstance(o[0],dict):
            keys=set(o[0].keys())
            if 'superscript' in keys: return ('chords-list',len(o))
            if 'category' in keys: return ('genre-presets',len(o))
            if 'pitch' in keys: return ('notes',len(o))
            return ('list:'+','.join(sorted(keys))[:60],len(o))
    return ('other',len(o) if hasattr(o,'__len__') else 0)

print(f"parsed {len(found)} JSON blobs")
for o in found:
    t,n=classify(o)
    print(f"  {t:40s} items={n}")

# ---- dump everything with sensible names ----
import os
os.makedirs('extracted/clean',exist_ok=True)
named={}
for o in found:
    t,n=classify(o)
    if t=='scales': named['scales']=o
    elif t=='chords?': named['chords']=o
    elif t=='genre-presets': named['genre_presets']=o
    elif t=='notes': named['notes']=o
    elif t.startswith('list:Complexity') or 'Feel/Mood' in t: named['progressions']=o
    elif t=='list:positions,suffix_uuid': named['chord_voicings']=o
    elif t.startswith('list:extension'): named['audio_samples']=o
    else:
        named.setdefault('misc',[]).append(o)

for k,v in named.items():
    open(f'extracted/clean/{k}.json','w').write(json.dumps(v,indent=2,ensure_ascii=False))
    print(f"wrote extracted/clean/{k}.json")

print("\n=== progressions sample (first entry) ===")
print(json.dumps(named['progressions'][0],indent=2,ensure_ascii=False))
print("\n=== chords sample (first 2) ===")
ch=named['chords']
for kk in list(ch)[:2]:
    print(kk,'->',json.dumps(ch[kk],ensure_ascii=False)[:300])
