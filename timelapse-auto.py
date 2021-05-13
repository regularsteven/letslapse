from os import system
from PIL import Image, ExifTags, ImageStat
from time import sleep
from decimal import Decimal
import argparse
import math

parser = argparse.ArgumentParser()
parser.add_argument('--ss', help='shutter speed help')
args = parser.parse_args()






def brightnessPerceived ( img ):
    stat = ImageStat.Stat(img)
    r,g,b = stat.rms
    return math.sqrt(0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2))




shutterSpeed = 0

raspiDefaults = "raspistill -t 1 --ISO 100 -ex verylong"



for i in range(500):
    print("taking a photo")
    filename = "auto/image"+str(i)+".jpg"
    fileOutput = " --latest latest.jpg -o "+filename
    if i == 0:
        raspiCommand = raspiDefaults + fileOutput
    else: 
        raspiCommand = raspiDefaults + " -ss "+str(shutterSpeed) + fileOutput
    print(raspiCommand)
    system(raspiCommand)

    sleep(4)
    
    img = Image.open(filename)
    exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
    print("ShutterSpeedValue = "+ str(exif["ShutterSpeedValue"]))
    lastShotExposureTime = str(exif["ExposureTime"])

    print("ExposureTime = "+ str(lastShotExposureTime))


    print("ISOSpeedRatings = " + str(exif["ISOSpeedRatings"]))
    brightnessScore = brightnessPerceived(img)
    print("brightnessPerceived score: " + str(brightnessScore))


    if i == 0:

        shutterSpeed = float(lastShotExposureTime) * 1000000
        print("first time shooting - will set shutter speed to this test shot")
        print(float(lastShotExposureTime) * 1000000)
    else:
        if brightnessScore < 140 :
            print("low brightness")
            shutterSpeed = int(shutterSpeed) + (int(shutterSpeed)/2)
        if brightnessScore > 160 :
            print("high brightness")
            shutterSpeed = int(shutterSpeed) - (int(shutterSpeed)/2)
    sleep(7)

print("end")