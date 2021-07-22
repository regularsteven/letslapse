#for SIMPLE METHODs: brightnessPerceived & brightnessFromGreyscale
import math
from PIL import Image,ImageStat

# for COMPLEX METHODS: 

#import numpy as np
#import cv2
#import sys
#from collections import namedtuple


runningStandalone = False
if len(sys.argv) < 2:
    print("For STANDALONE USAGE: ll_brightness.py <image_path>")
    #sys.exit(1)

#imageToTest = sys.argv[1]
#########################################################################################
################################SIMPLE METHODs###########################################
#########################################################################################

#logic from https://stackoverflow.com/a/3498247 (from https://stackoverflow.com/users/64313/cmcginty)
def brightnessPerceived ( img ):
    print("brightnessPerceived(): ")
    imageObj = Image.open(img) 
    stat = ImageStat.Stat(imageObj)
    r,g,b = stat.rms
    return math.sqrt( 0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2) )

def brightnessFromGreyscale( img ):
    print("brightnessFromGreyscale: ")
    imageObj = Image.open(img).convert('L')
    stat = ImageStat.Stat(imageObj)
    return stat.mean[0]


#########################################################################################
################################COMPLEX METHODS##########################################
#########################################################################################

##brange brightness range
##bval brightness value
#BLevel = namedtuple("BLevel", ['brange', 'bval'])

##all possible levels
#_blevels = [
#    BLevel(brange=range(0, 24), bval=0),
#    BLevel(brange=range(23, 47), bval=1),
#    BLevel(brange=range(46, 70), bval=2),
#    BLevel(brange=range(69, 93), bval=3),
#    BLevel(brange=range(92, 116), bval=4),
#    BLevel(brange=range(115, 140), bval=5),
#    BLevel(brange=range(139, 163), bval=6),
#    BLevel(brange=range(162, 186), bval=7),
#    BLevel(brange=range(185, 209), bval=8),
#    BLevel(brange=range(208, 232), bval=9),
#    BLevel(brange=range(231, 256), bval=10),
#]


#def detect_level(h_val):
#    h_val = int(h_val)
#    for blevel in _blevels:
#        if h_val in blevel.brange:
#            return blevel.bval
#    raise ValueError("Brightness Level Out of Range")


#def get_img_avg_brightness(img):
#    #print("get_img_avg_brightness(): ")
#    imgObj = cv2.imread(img)
#    hsv = cv2.cvtColor(imgObj, cv2.COLOR_BGR2HSV)
#    _, _, v = cv2.split(hsv)
#
#    return int(np.average(v.flatten()))
#
#if __name__ == '__main__':
#    print("overall brightness score: "+str(get_img_avg_brightness(imageToTest)))
#    print("the image brightness level is:{0}".format(detect_level(get_img_avg_brightness(imageToTest))))

#########################################################################################

#print(brightnessPerceived(imageToTest))
#print(brightnessFromGreyscale(imageToTest))




#print()
