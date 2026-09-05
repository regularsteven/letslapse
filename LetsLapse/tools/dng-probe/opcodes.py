import struct, sys, re
OPS={1:'WarpRectilinear',2:'WarpFisheye',3:'FixVignetteRadial',4:'FixBadPixelsConstant',5:'FixBadPixelsList',6:'TrimBounds',7:'MapTable',8:'MapPolynomial',9:'GainMap',10:'DeltaPerRow',11:'DeltaPerColumn',12:'ScalePerRow',13:'ScalePerColumn',14:'WarpRectilinear2'}
def find_tag(d, tag):
    bo='<' if d[:2]==b'II' else '>'
    def rd(fmt,o): return struct.unpack(bo+fmt,d[o:o+struct.calcsize(fmt)])
    res=[]; xmp=None
    def ifd(o):
        nonlocal xmp
        n=rd('H',o)[0]; o+=2; subs=[]
        for i in range(n):
            t,typ,cnt=rd('HHI',o); vo=o+8
            sz={1:1,2:1,3:2,4:4,5:8,7:1,10:8,11:4,12:8}.get(typ,1); tot=sz*cnt
            if tot>4: vo=rd('I',o+8)[0]
            if t==330: subs=[rd('I',vo+4*k)[0] for k in range(cnt)]
            if t in tag: res.append((t,d[vo:vo+tot]))
            if t==700: xmp=d[vo:vo+cnt]
            o+=12
        for s in subs: ifd(s)
    ifd(rd('I',4)[0]); return res, xmp
for path in sys.argv[1:]:
    d=open(path,'rb').read()
    res,xmp=find_tag(d,(51008,51009,51022))
    print("=====",path)
    for t,blob in res:
        n=struct.unpack('>I',blob[:4])[0]; o=4
        print(f" OpcodeList{ {51008:1,51009:2,51022:3}[t] }: {n} opcodes")
        for k in range(n):
            oid,ver,flags,size=struct.unpack('>IIII',blob[o:o+16]); o+=16
            data=blob[o:o+size]; o+=size
            desc=''
            if oid==1:
                np=struct.unpack('>I',data[:4])[0]
                coeffs=struct.unpack(f'>{np*6}d',data[4:4+np*48]); cx,cy=struct.unpack('>dd',data[4+np*48:4+np*48+16])
                desc=f"planes={np} center=({cx:.4f},{cy:.4f}) coeffs=" + ' | '.join(str([round(c,5) for c in coeffs[i*6:i*6+6]]) for i in range(np))
            elif oid==3:
                k=struct.unpack('>7d',data[:56]); desc=f"k={[round(x,5) for x in k[:5]]} center=({k[5]:.4f},{k[6]:.4f})"
            elif oid==9:
                top,left,bottom,right,plane,planes,rowpitch,colpitch,mapr,mapc,planesm=struct.unpack('>11I',data[:44])
                desc=f"area=({top},{left},{bottom},{right}) plane {plane}/{planes} pitch {rowpitch}x{colpitch} map {mapr}x{mapc}x{planesm}"
            print(f"  [{k}] {OPS.get(oid,oid)} v{ver} flags={flags} size={size} {desc}")
    if xmp: 
        x=xmp.decode('utf8','replace')
        print(" XMP:", re.sub(r'\s+',' ',x)[:3000])
