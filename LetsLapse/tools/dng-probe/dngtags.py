import struct, sys
TYPES={1:('B',1),2:('c',1),3:('H',2),4:('I',4),5:('II',8),6:('b',1),7:('B',1),8:('h',2),9:('i',4),10:('ii',8),11:('f',4),12:('d',8),13:('I',4),16:('Q',8),17:('q',8),18:('Q',8)}
NAMES={254:'NewSubfileType',256:'ImageWidth',257:'ImageLength',258:'BitsPerSample',259:'Compression',262:'PhotometricInterpretation',271:'Make',272:'Model',274:'Orientation',277:'SamplesPerPixel',278:'RowsPerStrip',284:'PlanarConfiguration',305:'Software',322:'TileWidth',323:'TileLength',330:'SubIFDs',339:'SampleFormat',34665:'ExifIFD',50706:'DNGVersion',50707:'DNGBackwardVersion',50708:'UniqueCameraModel',50709:'LocalizedCameraModel',50710:'CFAPlaneColor',50711:'CFALayout',50712:'LinearizationTable',50713:'BlackLevelRepeatDim',50714:'BlackLevel',50715:'BlackLevelDeltaH',50716:'BlackLevelDeltaV',50717:'WhiteLevel',50718:'DefaultScale',50719:'DefaultCropOrigin',50720:'DefaultCropSize',50721:'ColorMatrix1',50722:'ColorMatrix2',50723:'CameraCalibration1',50724:'CameraCalibration2',50725:'ReductionMatrix1',50726:'ReductionMatrix2',50727:'AnalogBalance',50728:'AsShotNeutral',50729:'AsShotWhiteXY',50730:'BaselineExposure',50731:'BaselineNoise',50732:'BaselineSharpness',50733:'BayerGreenSplit',50734:'LinearResponseLimit',50735:'CameraSerialNumber',50736:'LensInfo',50737:'ChromaBlurRadius',50738:'AntiAliasStrength',50739:'ShadowScale',50740:'DNGPrivateData',50741:'MakerNoteSafety',50778:'CalibrationIlluminant1',50779:'CalibrationIlluminant2',50780:'BestQualityScale',50781:'RawDataUniqueID',50827:'OriginalRawFileName',50829:'ActiveArea',50830:'MaskedAreas',50831:'AsShotICCProfile',50832:'AsShotPreProfileMatrix',50833:'CurrentICCProfile',50834:'CurrentPreProfileMatrix',50879:'ColorimetricReference',50931:'CameraCalibrationSignature',50932:'ProfileCalibrationSignature',50933:'ExtraCameraProfiles',50934:'AsShotProfileName',50935:'NoiseReductionApplied',50936:'ProfileName',50937:'ProfileHueSatMapDims',50938:'ProfileHueSatMapData1',50939:'ProfileHueSatMapData2',50940:'ProfileToneCurve',50941:'ProfileEmbedPolicy',50942:'ProfileCopyright',50964:'ForwardMatrix1',50965:'ForwardMatrix2',50966:'PreviewApplicationName',50967:'PreviewApplicationVersion',50968:'PreviewSettingsName',50969:'PreviewSettingsDigest',50970:'PreviewColorSpace',50971:'PreviewDateTime',50972:'RawImageDigest',50973:'OriginalRawFileDigest',50974:'SubTileBlockSize',50975:'RowInterleaveFactor',50981:'ProfileLookTableDims',50982:'ProfileLookTableData',51008:'OpcodeList1',51009:'OpcodeList2',51022:'OpcodeList3',51041:'NoiseProfile',51089:'OriginalDefaultFinalSize',51090:'OriginalBestQualityFinalSize',51091:'OriginalDefaultCropSize',51107:'ProfileHueSatMapEncoding',51108:'ProfileLookTableEncoding',51109:'BaselineExposureOffset',51110:'DefaultBlackRender',51111:'NewRawImageDigest',51112:'RawToPreviewGain',51125:'DefaultUserCrop',51177:'DepthFormat',52525:'ProfileGainTableMap',52526:'SemanticName',52528:'SemanticInstanceID',52529:'CalibrationIlluminant3',52530:'CameraCalibration3',52531:'ColorMatrix3',52532:'ForwardMatrix3',52533:'IlluminantData1',52534:'IlluminantData2',52535:'IlluminantData3',52536:'MaskSubArea',52537:'ProfileHueSatMapData3',52538:'ReductionMatrix3',52543:'RGBTables',52544:'ProfileGainTableMap2',52548:'ColumnInterleaveFactor',52549:'ImageSequenceInfo',52550:'ImageStats',52551:'ProfileDynamicRange',52552:'ProfileGroupName',52553:'JXLDistance',52554:'JXLEffort',52555:'JXLDecodeSpeed',33434:'ExposureTime',33437:'FNumber',34855:'ISO',36867:'DateTimeOriginal',37386:'FocalLength',42036:'LensModel'}
def parse(path):
    d=open(path,'rb').read()
    bo='<' if d[:2]==b'II' else '>'
    ver=struct.unpack(bo+'H',d[2:4])[0]
    off=struct.unpack(bo+'I',d[4:8])[0]
    def rd(fmt,o): return struct.unpack(bo+fmt,d[o:o+struct.calcsize(fmt)])
    def ifd(o,label,depth=0):
        n=rd('H',o)[0]; o+=2
        print(f"{'  '*depth}--- IFD {label} @{o-2} ({n} entries)")
        subs=[]; exif=None
        for i in range(n):
            tag,typ,cnt=rd('HHI',o); vo=o+8
            fmt,sz=TYPES.get(typ,('B',1)); tot=sz*cnt
            if tot>4: vo=rd('I',o+8)[0]
            name=NAMES.get(tag,f"tag{tag}")
            if typ==2: val=d[vo:vo+cnt].rstrip(b'\0').decode('latin1',errors='replace')[:80]
            elif typ in (5,10):
                vals=[]; 
                for k in range(min(cnt,12)):
                    a,b=rd(fmt,vo+8*k); vals.append(round(a/b,5) if b else float('nan'))
                val=vals
            elif typ==7: val=f"<{cnt} bytes undefined>"+(" "+d[vo:vo+min(cnt,16)].hex() if cnt<=64 else "")
            else:
                vals=[rd(fmt,vo+sz*k)[0] for k in range(min(cnt,12))]
                val=vals if cnt>1 else vals[0]
                if cnt>12: val=f"{vals}... (count {cnt})"
            print(f"{'  '*depth}{name:28s} t{typ:<2d} n{cnt:<6d} {val}")
            if tag==330: subs=[rd('I',vo+4*k)[0] for k in range(cnt)]
            if tag==34665: exif=val
            o+=12
        nxt=rd('I',o)[0]
        for k,s in enumerate(subs): ifd(s,f"{label}/Sub{k}",depth+1)
        if exif: ifd(exif,f"{label}/Exif",depth+1)
        return nxt
    i=0
    while off:
        off=ifd(off,f"IFD{i}"); i+=1
for p in sys.argv[1:]:
    print("=====",p); parse(p)
