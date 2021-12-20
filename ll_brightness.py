#for SIMPLE METHODs: brightnessPerceived & brightnessFromGreyscale
import math
from PIL import Image,ImageStat
import sys

runningStandalone = False
if len(sys.argv) < 2:
    print("For STANDALONE USAGE: ll_brightness.py <image_path>")
    #sys.exit(1)

#########################################################################################
################################SIMPLE METHODs###########################################
#########################################################################################

#logic from https://stackoverflow.com/a/3498247 (from https://stackoverflow.com/users/64313/cmcginty)
def brightnessPerceived ( img ):
    #print("brightnessPerceived(): ")
    imageObj = Image.open(img) 
    stat = ImageStat.Stat(imageObj)
    r,g,b = stat.rms
    return math.sqrt( 0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2) )

def brightnessFromGreyscale( img ):
    #print("brightnessFromGreyscale: ")
    imageObj = Image.open(img).convert('L')
    stat = ImageStat.Stat(imageObj)
    return stat.mean[0]

