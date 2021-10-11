import rawpy
import imageio
import os
import argparse
from pidng.core import RPICAM2DNG


#egtting this going requires a few pi installs
#pip install cython
# see "Installation from source on Linux/macOS" from https://pypi.org/project/rawpy/

#sudo apt-get install imagemagick

curWorkDir = os.getcwd()

def getFiles(path):
    #print(path)
    for file in os.listdir(path):
        if os.path.isfile(os.path.join(path, file)):
            if "_thumb" not in file:
            #print(file.split(".jpg")[1])
                yield os.path.join(file)


def extractToDNG():
    print("extractToDNG() - extracting all DNG images to folder ")
    if os.path.isdir("dng") == True :
        print("dng folder already created")
    else :
        print("dng folder now created")
        os.system("mkdir dng")


    for file in getFiles(curWorkDir+"/"):
        thisFileNoExt = file.split(".jpg")[0]
        print(thisFileNoExt)
        RPICAM2DNG().convert(file)
        os.system("mv " + thisFileNoExt + ".dng dng/")

    print("DNG extraction complete")

def convertFromDNG():
    print("convertFromDNG() - converting all DNG images to JPEG, fixing white balance ")
    if os.path.isdir("converted") == True :
        print("converted folder already created")
    else :
        os.system("mkdir converted")
        print("converted folder now created")

    for file in getFiles(curWorkDir+"/dng"):
        print(file)
        thisFileNoExt = file.split(".dng")[0]

        with rawpy.imread(curWorkDir+"/dng/"+thisFileNoExt+".dng") as raw:
            rgb = raw.postprocess(use_camera_wb=False, use_auto_wb=True, highlight_mode=2)

        imageio.imsave(curWorkDir+"/converted/"+thisFileNoExt+"_render.jpg", rgb)

    print("convertFromDNG() conversion complete")

def stackImages():
    stackStart = 0
    stackEnd = 10

    curStackIndex = stackStart
    thisFormat = ".jpg"
    shellStr = "convert"
    while curStackIndex < stackEnd:
        #print(x+myInt)
        shellStr += " converted/image"+str(curStackIndex)+"_render"+thisFormat
        curStackIndex = curStackIndex+1


    shellStr += " -evaluate-sequence mean output_"+str(stackStart)+"_"+str(stackEnd)+thisFormat
    #exit()

    print(shellStr)
    os.system(shellStr)


extractToDNG()
convertFromDNG()
stackImages()


#convert image10.jpg image11.jpg image12.jpg image13.jpg image14.jpg image15.jpg image16.jpg image17.jpg image18.jpg image19.jpg image20.jpg -evaluate-sequence mean output.jpg

#convert image10.jpg image11.jpg image12.jpg -evaluate-sequence mean output.jpg

#path = 'image25.dng'
#with rawpy.imread(path) as raw:
#    rgb = raw.postprocess()

