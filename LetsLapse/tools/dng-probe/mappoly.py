import struct, sys, glob, os
def scan(path):
    d=open(path,'rb').read(); bo='<' if d[:2]==b'II' else '>'
    def rd(fmt,o): return struct.unpack(bo+fmt,d[o:o+struct.calcsize(fmt)])
    out={}
    def ifd(o):
        n=rd('H',o)[0]; o+=2; subs=[]
        for i in range(n):
            t,typ,cnt=rd('HHI',o); vo=o+8
            sz={1:1,2:1,3:2,4:4,5:8,7:1,10:8,11:4,12:8}.get(typ,1); tot=sz*cnt
            if tot>4: vo=rd('I',o+8)[0]
            if t==330: subs=[rd('I',vo+4*k)[0] for k in range(cnt)]
            if t==50714: out['black']=[rd('II',vo+8*k)[0]/max(1,rd('II',vo+8*k)[1]) for k in range(cnt)]
            if t==51009: out['op2']=d[vo:vo+tot]
            if t==50730: a,b=rd('ii',vo); out['baseline']=a/b
            if t==33434: a,b=rd('II',vo); out['exp']=a/b
            if t==34855: out['iso']=rd('H',vo)[0]
            if t==50728: out['neutral']=[round(rd('II',vo+8*k)[0]/rd('II',vo+8*k)[1],4) for k in range(cnt)]
            o+=12
        for s in subs: ifd(s)
    ifd(rd('I',4)[0])
    polys=[]
    if 'op2' in out:
        blob=out['op2']; n=struct.unpack('>I',blob[:4])[0]; o=4
        for k in range(n):
            oid,ver,flags,size=struct.unpack('>IIII',blob[o:o+16]); o+=16; data=blob[o:o+size]; o+=size
            if oid==8:
                top,left,bottom,right,plane,planes,rp,cp,deg=struct.unpack('>9I',data[:36])
                co=struct.unpack(f'>{deg+1}d',data[36:36+8*(deg+1)])
                polys.append((plane,planes,deg,[round(c,6) for c in co],(top,left,bottom,right)))
    return out,polys
if sys.argv[1]=='one':
    for p in sys.argv[2:]:
        out,polys=scan(p); print(p); print(' black',out.get('black'),'baseline',out.get('baseline'),'exp',out.get('exp'),'iso',out.get('iso'),'neutral',out.get('neutral'))
        for pl in polys: print('  MapPolynomial plane %d/%d deg %d coeffs %s area %s'%pl)
else:
    files=sorted(glob.glob(os.path.join(sys.argv[2],'*.dng')))
    print('n files',len(files))
    for p in files[::int(sys.argv[3]) if len(sys.argv)>3 else 1]:
        out,polys=scan(p)
        print(os.path.basename(p),'exp',out.get('exp'),'iso',out.get('iso'),'black',out.get('black'),'neutral',out.get('neutral'),'poly',[pl[3] for pl in polys][:1], 'planes', len(polys))
