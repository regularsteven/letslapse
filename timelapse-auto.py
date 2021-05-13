from os import system
from PIL import Image, ExifTags, ImageStat
import argparse
import math
parser = argparse.ArgumentParser()
parser.add_argument('--ss', help='shutter speed help')
args = parser.parse_args()

filename = "auto/reference.jpg"
fileOutput = "-o "+filename
raspiCommand = "raspistill -t 1"

raspiCommand += " " + fileOutput
raspiCommand += " --ISO 100 -ss " +args.ss
raspiCommand += " -ex verylong"

print(raspiCommand)
system(raspiCommand)



img = Image.open(filename)
exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
print("ShutterSpeedValue = "+ str(exif["ShutterSpeedValue"]))
print("ExposureTime = "+ str(exif["ExposureTime"]))
print("ISOSpeedRatings = " + str(exif["ISOSpeedRatings"]))


def brightnessPerceived ( img ):
    stat = ImageStat.Stat(img)
    r,g,b = stat.rms
    return math.sqrt(0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2))

def brightnessRMS  ( img ):
    im = img.convert('L')
    stat = ImageStat.Stat(im)
    return stat.rms[0]



print("brightnessPerceived score: " + str(brightnessPerceived(img)))
print("brightnessRMS score: " + str(brightnessRMS(img)))
#r, g, b = img.split()
#len(r.histogram())
#len(g.histogram())
#len(b.histogram())
### 256 ###

#print(r.histogram())
#print(g.histogram())
#print(b.histogram())

