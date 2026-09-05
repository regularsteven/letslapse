import struct, sys, shutil
src, dst, variant = sys.argv[1], sys.argv[2], sys.argv[3]
d = bytearray(open(src,'rb').read()); bo='<' if d[:2]==b'II' else '>'
def rd(fmt,o): return struct.unpack(bo+fmt,d[o:o+struct.calcsize(fmt)])
locs={}
def ifd(o):
    n=rd('H',o)[0]; o+=2; subs=[]
    for i in range(n):
        t,typ,cnt=rd('HHI',o); vo=o+8
        sz={1:1,2:1,3:2,4:4,5:8,7:1,10:8,11:4,12:8}.get(typ,1); tot=sz*cnt
        if tot>4: vo=rd('I',o+8)[0]
        if t==330: subs=[rd('I',vo+4*k)[0] for k in range(cnt)]
        if t in (50714,51009,50728,50730,50717): locs.setdefault(t,[]).append((vo,cnt,o))
        o+=12
    for s in subs: ifd(s)
ifd(rd('I',4)[0])
bl=locs[50714][0][0]; op=locs[51009][0][0]
wl_vo,wl_cnt,_=locs[50717][0]; W=float(rd('H',wl_vo)[0]); print('white',W)
def set_black(vals):
    for k,v in enumerate(vals): d[bl+8*k:bl+8*k+8]=struct.pack(bo+'II',int(v),1)
def poly_off(k): return op+4+84*k+16+36
def get_poly(k): return list(struct.unpack('>4d',d[poly_off(k):poly_off(k)+32]))
def set_poly(k,c): d[poly_off(k):poly_off(k)+32]=struct.pack('>4d',*c)
blacks=[rd('II',bl+8*k)[0]/rd('II',bl+8*k)[1] for k in range(3)]
print('orig black',blacks,'polys',[ [round(x,5) for x in get_poly(k)] for k in range(3)])
if variant=='noops': d[op:op+4]=struct.pack('>I',0)
elif variant=='polyident':
    for k in range(3): set_poly(k,[0,1,0,0])
elif variant=='polyall0':
    p=get_poly(0)
    for k in range(3): set_poly(k,p)
elif variant=='polyall2':
    p=get_poly(2)
    for k in range(3): set_poly(k,p)
elif variant=='blackeq':  set_black([blacks[1]]*3)
elif variant=='blackeqB': set_black([blacks[2]]*3)
elif variant=='black0':   set_black([0,0,0])
elif variant=='blackswapRB': set_black([blacks[2],blacks[1],blacks[0]])
elif variant=='blackswapGB': set_black([blacks[0],blacks[2],blacks[1]])
elif variant.startswith('uni:'): set_black([int(variant[4:])]*3)
elif variant=='fold':
    for k in range(3):
        c=get_poly(k); b=blacks[k]/W; s=1/(1-b); t=-b*s
        c0,c1,c2,c3=c
        a0=c0 + c1*t + c2*t*t + c3*t**3
        a1=c1*s + 2*c2*s*t + 3*c3*s*t*t
        a2=c2*s*s + 3*c3*s*s*t
        a3=c3*s**3
        set_poly(k,[a0,a1,a2,a3]); print('  plane',k,'black',blacks[k],'poly',[round(x,6) for x in c],'->',[round(x,6) for x in (a0,a1,a2,a3)])
    set_black([0,0,0])
elif variant.startswith('foldshift:'):
    delta=float(variant.split(':')[1])
    for k in range(3):
        c=get_poly(k); b=blacks[k]/W; s=1/(1-b); t=-b*s
        c0,c1,c2,c3=c
        a0=c0 + c1*t + c2*t*t + c3*t**3
        a1=c1*s + 2*c2*s*t + 3*c3*s*t*t
        a2=c2*s*s + 3*c3*s*s*t
        a3=c3*s**3
        if k==1: a0+=delta
        set_poly(k,[a0,a1,a2,a3])
    set_black([0,0,0])
elif variant.startswith('foldped'):
    # foldped[:mulR,mulG,mulB] -- fold black into the cubic, then lift each plane's constant term so the
    # cubic is >= 0 on [0,1] (its minimum is a0 at u=0); optional multipliers scale that pedestal per plane
    muls=[1.0,1.0,1.0]
    if ':' in variant: muls=[float(x) for x in variant.split(':')[1].split(',')]
    for k in range(3):
        c=get_poly(k); b=blacks[k]/W; s=1/(1-b); t=-b*s
        c0,c1,c2,c3=c
        a0=c0 + c1*t + c2*t*t + c3*t**3
        a1=c1*s + 2*c2*s*t + 3*c3*s*t*t
        a2=c2*s*s + 3*c3*s*s*t
        a3=c3*s**3
        ped=max(0.0,-a0)*muls[k]
        print('  plane',k,'pedestal',round(ped,6))
        set_poly(k,[a0+ped,a1,a2,a3])
    set_black([0,0,0])
elif variant=='orig': pass
else: raise SystemExit('unknown variant')
open(dst,'wb').write(d)
print('wrote',dst,variant)
