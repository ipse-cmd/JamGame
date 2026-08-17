import json,re
DEG={1:0,2:2,3:4,4:5,5:7,6:9,7:11,8:12,9:14,10:16,11:17,12:19,13:21}
def tok2semi(t):
    t=t.strip()
    m=re.match(r'^([b#x]*)(\d+)$',t)
    if not m: raise ValueError(t)
    acc,deg=m.group(1),int(m.group(2))
    base=DEG[deg]
    for ch in acc:
        base += -1 if ch=='b' else (2 if ch=='x' else 1)
    return base%12 if deg<=7 else base  # keep extensions extended
def formula2semis(f): 
    return [tok2semi(t) for t in f]

ch=json.load(open('extracted/clean/chords.json'))
out_ch={}
for name,c in ch.items():
    out_ch[name]={'name':name,'semitones':formula2semis(c['formula']),
                  'formula':c['formula'],'isMinor':c.get('notation',{}).get('isMinor',False),
                  'symbol':c.get('notation',{}).get('superscript','')}
# sanity checks
def show(n): print(f"  {n:6s} -> {out_ch[n]['semitones']}")
print("=== chord sanity ===")
for n in ['maj','min','maj7','7','min7','dim','aug','sus4','9','min7b5']:
    if n in out_ch: show(n)

sc=json.load(open('extracted/clean/scales.json'))
out_sc={}
for name,s in sc.items():
    semis=[tok2semi(t)%12 for t in s['formula']]
    moods=[m.strip() for m in (s.get('style') or '').split(',') if m.strip()]
    out_sc[name]={'name':s.get('name',name),'display':s.get('modDisplayName','').replace('\n',' '),
                  'semitones':semis,'formula':s['formula'],'parent':s.get('parent scale'),
                  'degree':s.get('degree'),'moods':moods,'altNames':s.get('alt names',[])}
print("\n=== scale sanity ===")
for n in ['Major scale','Dorian scale','Phrygian scale']:
    k=[x for x in out_sc if x==n or out_sc[x]['name']==n]
    if k: print(f"  {n:16s} -> {out_sc[k[0]]['semitones']}  moods={out_sc[k[0]]['moods'][:3]}")

json.dump(out_ch,open('extracted/clean/chords_normalized.json','w'),indent=2,ensure_ascii=False)
json.dump(out_sc,open('extracted/clean/scales_normalized.json','w'),indent=2,ensure_ascii=False)
# mood vocabulary
allmoods={}
for s in out_sc.values():
    for m in s['moods']: allmoods[m]=allmoods.get(m,0)+1
print("\n=== mood vocabulary (top) ===")
for m,c in sorted(allmoods.items(),key=lambda x:-x[1])[:25]: print(f"  {c:3d}  {m}")
print(f"\nwrote chords_normalized.json ({len(out_ch)}), scales_normalized.json ({len(out_sc)})")
