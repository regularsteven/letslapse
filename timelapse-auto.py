noCameraTesting = True

from os import system
from PIL import Image, ExifTags, ImageStat
if noCameraTesting != True: 
    from picamera import PiCamera
from time import sleep
from decimal import Decimal
import argparse
import math

import os.path
from os import path






width = 4056
height = int(width * .75)
resolution = " -w "+str(width)+" -h "+str(height)

awbgSettings = "3.484375,1.44921875"

parser = argparse.ArgumentParser()
parser.add_argument('--folderName', help="name of folder to use")
parser.add_argument('--imageCount', help='number of images')

#example use:
# python3 timelapse-auto --folderName demo

args = parser.parse_args()


def storeProgress (index, folder,shutterSpeed, DG, AG):
    system("echo '"+str(index)+"\n"+folder+"\n"+str(shutterSpeed)+"\n"+str(DG)+"\n"+str(AG)+"' >progress.txt")


print(path.isfile("progress.txt"))

preResetCount = 0 #this is the value that will be overriden in the even there was a crash or bad exit / restart / battery change



shutterSpeed = 1000
maxShutterSpeed = 25000000 #20 seconds in ver low light 
ISO = 6
maxISO = 800
#raspiDefaults = "raspistill -t 1 --ISO "+str(ISO)+" -ex verylong" + resolution

#ISO doesn't seem to work with -ex night, so need to implement -dg value (1 > 8)
DG = 1 #digital gain
maxDG = 8
DGIncrement = .5


AG = 1 #analogue gain
maxAG = 1.8
AGIncrement = .1




if path.isfile("progress.txt") == False:
    storeProgress (0, args.folderName, shutterSpeed, DG, AG)
    print("no progress file, making one... ")
else :
    print("progress.txt exists - need to get the captureCount from the previous session")
    print("START values:")
    file1 = open('progress.txt', 'r')
    Lines = file1.readlines()
    lineCount = 0
    # Strips the newline character
    preResetCount = int(Lines[0].strip())
    folderName = (Lines[2].strip())
    DG = int(Lines[3].strip())
    AG = int(Lines[4].strip())
    #for line in Lines:
        #lineCount += 1
        #print((line.strip()))
    print("END values")
#exit()



#print(args.imageCount)

#logic from https://stackoverflow.com/a/3498247 (from https://stackoverflow.com/users/64313/cmcginty)
def brightnessPerceived ( img ):
    stat = ImageStat.Stat(img)
    r,g,b = stat.rms
    return math.sqrt( 0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2) )


if path.isdir("auto_"+args.folderName) == True :
    print("directory already created")
else :
    system("mkdir auto_"+args.folderName)

for i in range(80000):
    actualIndex = i + preResetCount
    #print("")
    print("-----------------------------------------")
    #print("taking a photo")
    raspiDefaults = "raspistill -t 1 -bm -ag 1 -sa -10 -dg "+str(DG)+" -ag "+str(AG)+" -awb off -awbg "+awbgSettings+" -co -15 -ex off" + resolution

    if path.isdir("auto_"+args.folderName+"/group"+str(int(actualIndex/1000))) == False :
        system("mkdir auto_"+args.folderName+"/group"+str(int(actualIndex/1000)))
        print("need to create group folder")

    filename = "auto_"+args.folderName+"/group"+str(int(actualIndex/1000))+"/image"+str(actualIndex)+".jpg"
    

    fileOutput = ""
    #fileOutput = " --latest latest.jpg" #comment this out if we don't want the latest image - might add overhead in terms of IO, so potentially kill it
    fileOutput = fileOutput+ " -o "+filename


    raspiCommand = raspiDefaults + " -ss "+str(shutterSpeed) + fileOutput
    print("ShutterSpeed val:" + str(shutterSpeed))
    
    if noCameraTesting == True:
        print(raspiCommand)
    else :
        system(raspiCommand)

    
    storeProgress (actualIndex, args.folderName, shutterSpeed, DG, AG)

    if noCameraTesting == True:
        print("normally, analysis of the image happens here, but in this testing, we don't")
    else :

        img = Image.open(filename)
        exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
        print("Recorded EXIF ShutterSpeedValue = "+ str(exif["ShutterSpeedValue"]))
        lastShotExposureTime = str(exif["ExposureTime"])

        #print("ExposureTime = "+ str(lastShotExposureTime))
        #print("ISOSpeedRatings = " + str(exif["ISOSpeedRatings"]))
        brightnessScore = brightnessPerceived(img)
        print("brightnessPerceived score: " + str(brightnessScore))

        brightnessTarget = 130
        brightnessRange = 10

        lowBrightness = brightnessTarget - brightnessRange #140
        highBrightness = brightnessTarget + brightnessRange #160
        
        #brightnessTargetAccuracy = 100 #if the light is 
        if brightnessScore < lowBrightness :
            print("low brightness")
            brightnessTargetAccuracy = (brightnessScore/brightnessTarget)
            shutterSpeed = int(shutterSpeed) / (brightnessTargetAccuracy)
            if(shutterSpeed > maxShutterSpeed): #max shutterspeed of 8 seconds
                shutterSpeed = maxShutterSpeed
            if shutterSpeed > 2000000 :
                #ISO = ISO + 50
                #if ISO > maxISO : 
                #    ISO = maxISO
                #print("too little light, hard coding shutter and making ISO dynamic")
                print("increasing digital gain, shutter over 2 seconds")
                DG = DG + DGIncrement
                if DG > maxDG : 
                    DG = maxDG

            if shutterSpeed > 6000000 :
                AG = AG + AGIncrement
                if AG > maxAG : 
                    AG = maxAG
                print("getting very dark, increment AG: "+str(AG))

            print("new shutterspeed: " + str(shutterSpeed))
            
        if brightnessScore > highBrightness :
            print("high brightness")
            brightnessTargetAccuracy = (brightnessScore/brightnessTarget)
            if brightnessScore > 200 :
                #case where the shot is very over-exposed, as such double the amount of adjustment
                brightnessTargetAccuracy = brightnessTargetAccuracy*2
            
            shutterSpeed = int(shutterSpeed) / (brightnessTargetAccuracy)

            if shutterSpeed < 2000000: #if we're getting faster than a 2 second exposure
                #ISO = ISO - 50
                #if ISO < 10 : 
                #    ISO = 6
                DG = DG - DGIncrement
                if DG < 1 : 
                    DG = 1

            if shutterSpeed < 6000000 :
                AG = AG - AGIncrement
                if AG < 1 : 
                    AG = 1

            if(shutterSpeed < 100): 
                shutterSpeed = 100
                print("too much light, hard coding shutter")
            print("new shutterspeed: " + str(shutterSpeed))


    #if noCameraTesting != True:
    sleep(2)

print("end")
