import rawpy
import imageio
import os
import argparse
from pidng.core import RPICAM2DNG



curWorkDir = os.getcwd()

def getFiles(path):
    for file in os.listdir(path):
        if os.path.isfile(os.path.join(path, file)):
            if ".jpg" in file and "_thumb" not in file:
                #print(file.split(".jpg")[1])
                yield os.path.join(file)




for file in getFiles(curWorkDir+"/"):
    thisFileNoExt = file.split(".jpg")[0]
    print(thisFileNoExt)
    RPICAM2DNG().convert(thisFileNoExt + ".jpg")

    with rawpy.imread(thisFileNoExt+".dng") as raw:
        rgb = raw.postprocess()
    imageio.imsave(thisFileNoExt+".tiff", rgb)



#exit()



#path = 'image25.dng'
#with rawpy.imread(path) as raw:
#    rgb = raw.postprocess()

