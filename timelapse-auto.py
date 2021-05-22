from os import system
from PIL import Image, ExifTags, ImageStat
from time import sleep
from decimal import Decimal
import argparse
import math


width = 2400
height = width * .75
resolution = " -w "+str(width)+" -h "+str(height)


parser = argparse.ArgumentParser()
parser.add_argument('--imageCount', help='number of images')
args = parser.parse_args()

#print(args.imageCount)

def brightnessPerceived ( img ):
    stat = ImageStat.Stat(img)
    r,g,b = stat.rms
    return math.sqrt(0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2))

shutterSpeed = 0
ISO = 10
raspiDefaults = "raspistill -t 1 --ISO "+str(ISO)+" -ex verylong" + resolution

for i in range(8000):
    #print("")
    print("-----------------------------------------")
    #print("taking a photo")
    raspiDefaults = "raspistill -t 1 --ISO "+str(ISO)+" -ex verylong" + resolution
    filename = "auto/image"+str(i)+".jpg"
    fileOutput = " --latest latest.jpg -o "+filename
    if i == 0:
        raspiCommand = raspiDefaults + fileOutput
    else: 
        raspiCommand = raspiDefaults + " -ss "+str(shutterSpeed) + fileOutput
    print(raspiCommand)
    system(raspiCommand)

    #sleep(4)
    
    img = Image.open(filename)
    exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
    #print("ShutterSpeedValue = "+ str(exif["ShutterSpeedValue"]))
    lastShotExposureTime = str(exif["ExposureTime"])

    #print("ExposureTime = "+ str(lastShotExposureTime))


    #print("ISOSpeedRatings = " + str(exif["ISOSpeedRatings"]))
    brightnessScore = brightnessPerceived(img)
    print("brightnessPerceived score: " + str(brightnessScore))


    if i == 0:

        shutterSpeed = float(lastShotExposureTime) * 1000000
        print("first time shooting - will set shutter speed to this test shot")
        print("shutterSpeed: " + str(shutterSpeed))
    
    brightnessTarget = 100
    brightnessRange = 10

    lowBrightness = brightnessTarget - brightnessRange #140
    highBrightness = brightnessTarget + brightnessRange #160
    
    brightnessTargetAccuracy = 100 #if the light is 
    if brightnessScore < lowBrightness :
        print("low brightness")
        brightnessTargetAccuracy = (brightnessScore/brightnessTarget)
        shutterSpeed = int(shutterSpeed) / (brightnessTargetAccuracy)
        if(shutterSpeed > 8000000): #max shutterspeed of 8 seconds
            shutterSpeed = 8000000
            ISO = ISO + 50
            if ISO > 800 : 
                ISO = 800
            print("too little light, hard coding shutter and making ISO dynamic")
        print("new shutterspeed: " + str(shutterSpeed))
        
    if brightnessScore > highBrightness :
        print("high brightness")
        brightnessTargetAccuracy = (brightnessScore/brightnessTarget)
        if brightnessScore > 200 :
            #case where the shot is very over-exposed, as such double the amount of adjustment
            brightnessTargetAccuracy = brightnessTargetAccuracy*2
        
        shutterSpeed = int(shutterSpeed) / (brightnessTargetAccuracy)

        if shutterSpeed < 2000000: #if we're getting faster than a 2 second exposure
            ISO = ISO - 50
            if ISO < 10 : 
                ISO = 10


        if(shutterSpeed < 100): 
            shutterSpeed = 100
            print("too much light, hard coding shutter")
        print("new shutterspeed: " + str(shutterSpeed))


    
    sleep(1)

print("end")
