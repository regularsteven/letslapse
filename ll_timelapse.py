runWithoutCamera = False
updateGainsWithLivePreview = True
import os
instanceCount = 0
for line in os.popen("ps -f -C python3 | grep ll_timelapse.py"):
    instanceCount = instanceCount + 1
    if instanceCount > 1:
        print("ll_timelapse.py: Instance already running - exiting now")
        exit()

from os import system

if runWithoutCamera != True: 
    from picamera import PiCamera
    from PIL import Image, ExifTags, ImageStat
from time import sleep
import datetime
from decimal import Decimal
import argparse
import math
import requests

import os.path
from os import path


#extracted utils for broader use and more component oriented approach
import ll_brightness
import ll_utils



width = 4056
height = int(width * .75)
resolution = " -w "+str(width)+" -h "+str(height)


blueGains = 3.484375
redGains = 1.44921875

awbgSettings = str(blueGains)+","+str(redGains) #for natural light, great in daylight and moonlight - too yellow in street artificial light
    #at a starting point, set the red and blue values to the above, but at the end of every photo, do a test to see how far we are off the white balance
    #in a similar way to exposure, make minor adjustments - but only if there's two or more than 3 white balance readings that are out of range of the default
    #white balance settings
#awbgSettings = "2.0352,2.8945" #for street lights 
#awbgSettings = "3.73828125,1.26951" #for cloud cover at night


parser = argparse.ArgumentParser()
parser.add_argument('--folderName', help="name of folder to use", default="default")
parser.add_argument('--raw', help='setting a value will include a raw image in the jpeg', default="false")
parser.add_argument('--nightMode', help='nature or streets for brightness offset in low light')
parser.add_argument('--ultraBasic', help='nature or streets for brightness offset in low light', default="false")



#example use:
# python3 ll_timelapse.py --folderName demo
# python3 ll_timelapse.py --folderName testing --raw false --nightMode city

args = parser.parse_args()

folderName = args.folderName

if args.ultraBasic == "true":
    system("mkdir timelapse_"+folderName)
    system("mkdir timelapse_"+folderName+"/group0")
    sysCommand = "nohup raspistill -t 0 -tl 3000 -o timelapse_"+folderName+"/group0/image%04d.jpg &"
    system(sysCommand)
    exit()



raw = args.raw
nightMode = args.nightMode
print("args")
print(args)


def storeProgress (index, folder,shutterSpeed, DG, AG, blueGains, redGains, raw, nightMode, brightnessTarget, brightnessScore, postID):
    print("storeProgress: folder = "+ folder + ", nightMode="+str(nightMode)+", brightnessTarget="+str(brightnessTarget)+", brightnessScore="+str(brightnessScore) )
    filename = "timelapse_"+folder+".log"
    if path.isfile(filename) == False:
        system("touch "+filename)
    #else:
    f = open(filename, "a")
    f.write("image"+str(index)+".jpg,"+str(shutterSpeed)+","+str(DG)+","+str(AG)+","+str(blueGains)+","+str(redGains)+","+str(raw)+","+str(nightMode)+","+str(brightnessTarget)+","+str(brightnessScore)+","+str(postID)+"\n")
    f.close()
    
    system("echo '"+str(index)+"\n"+folder+"\n"+str(float(shutterSpeed))+"\n"+str(DG)+"\n"+str(AG)+"\n"+str(blueGains)+"\n"+str(redGains)+"\n"+str(raw)+"\n"+str(nightMode)+"\n"+str(brightnessTarget)+"\n"+str(brightnessScore)+"\n"+str(postID)+"' >progress.txt")



preResetCount = 0 #this is the value that will be overriden in the even there was a crash or bad exit / restart / battery change



shutterSpeed = 1000
maxShutterSpeed = 25000000 #20 seconds in ver low light 
ISO = 6
maxISO = 800
#raspiDefaults = "raspistill -t 1 --ISO "+str(ISO)+" -ex verylong" + resolution

#ISO doesn't seem to work with -ex night, so need to implement -dg value (1 > 8)
DG = 1 #digital gain
maxDG = 4
DGIncrement = .25


AG = 1 #analogue gain
maxAG = 3
AGIncrement = .1


#the bigger brightnessTarget, the brighter the image
brightnessTarget = 130
#nightmode brightness target
nightModeBrightnessTarget = 80
#the bigger brightnessRange, the less changes will take place
brightnessRange = 10




includeRaw = ""
if args.raw == "true":
    includeRaw = " -r "


if args.nightMode == None:
    nightMode = ""
else:
    nightMode = args.nightMode
    


if path.isfile("progress.txt") == False:
    
    print("New shoot, no progress file, making one... ")
    #this is the time to create a new post in the CMS
    postID = ll_utils.createPost(folderName + "Timelapse")
    storeProgress (0, folderName, shutterSpeed, DG, AG, blueGains, redGains, raw, nightMode, brightnessTarget, -1, postID)

else :
    print("progress.txt exists - need to get the captureCount from the previous session")
    print("START values:")
    file1 = open('progress.txt', 'r')
    Lines = file1.readlines()
    lineCount = 0
    # Strips the newline character
    preResetCount = int(Lines[0].strip())
    folderName = (Lines[1].strip())
    shutterSpeed = int(float(Lines[2].strip()))
    DG = float(Lines[3].strip())
    AG = float(Lines[4].strip())
    blueGains = float(Lines[5].strip())
    redGains = float(Lines[6].strip())

    raw = str(Lines[7].strip())
    includeRaw = ""
    if raw == "true":
        includeRaw = " -r "

    nightMode = str(Lines[8].strip())
    postID = str(Lines[11].strip())

    awbgSettings = str(blueGains)+","+str(redGains)
    #for line in Lines:
        #lineCount += 1
        #print((line.strip()))
    #print("END values")
#exit()



gainsTolerance = .2 #this is how much difference can exist between gains before we change the gains settings 

redGainsChangeOfSignificance = 0
blueGainsChangeOfSignificance = 0
brightnessChangeOfSignificance = 0

def manageColorGainChanges (measuredBlueGains, measuredRedGains) :
    global redGainsChangeOfSignificance,blueGainsChangeOfSignificance,awbgSettings,blueGains, redGains
    print("auto-measured gains: "+str(measuredBlueGains) + ", "+str(measuredRedGains))
    #print("blueGains: " + str(blueGains) +" measuredBlueGains " + str(measuredBlueGains))

    #print("redGains: " + str(redGains) +" measuredRedGains " + str(measuredRedGains))

    if measuredRedGains > (redGains+gainsTolerance) or measuredRedGains < (redGains-gainsTolerance) : 
        print("redGainsChangeOfSignificance = "+str(redGainsChangeOfSignificance))
        redGainsChangeOfSignificance = redGainsChangeOfSignificance + 1
    else :
        #print("red gains in range, no need to change")
        redGainsChangeOfSignificance = 0

    if measuredBlueGains > (blueGains+gainsTolerance) or measuredBlueGains < (blueGains-gainsTolerance) : 
        print("blueGainsChangeOfSignificance = "+str(blueGainsChangeOfSignificance))
        blueGainsChangeOfSignificance = blueGainsChangeOfSignificance + 1
    else :
        #print("blue gains in range, no need to change")
        blueGainsChangeOfSignificance = 0
    

    if redGainsChangeOfSignificance > 3 :
        print("redGain CHANGE from sequential outside of range pictures")
        #print("red gains have been reading outside of range for 3 photos, time to change")
        #if redGains were 2, and measuredRedGains are 3, then we need to gradually increase red gains until they are correct / as per measured values
        # redGains (was 2) = 2 + ((3-2)/3)  - i.e. becomes 2.333
        redGains = redGains - ((redGains - measuredRedGains)/5)

    
    if blueGainsChangeOfSignificance > 3 :
        print("blueGain CHANGE from sequential outside of range pictures")
        blueGains = blueGains - ((blueGains - measuredBlueGains)/5)

    awbgSettings = str(blueGains) + "," + str(redGains)
    print("awbgSettings: "+awbgSettings)

if path.isdir("timelapse_"+folderName) == True :
    print("directory already created")
else :
    system("mkdir timelapse_"+folderName)





startTime = datetime.datetime.now().timestamp()
print("start time: "+str(startTime))
for i in range(80000):
    actualIndex = i + preResetCount
    #print("")
    print("-----------------------------------------")
    #print("taking a photo")
    raspiDefaults = "raspistill -t 1 "+includeRaw+"-bm --thumb 600:450:30 -ag 1 -sa -10 -dg "+str(DG)+" -ag "+str(AG)+" -awb off -awbg "+awbgSettings+" -co -15 -ex off" + resolution
    #--
    if path.isdir("timelapse_"+folderName+"/group"+str(int(actualIndex/1000))) == False :
        system("mkdir timelapse_"+folderName+"/group"+str(int(actualIndex/1000)))
        print("need to create group folder")

    filename = "timelapse_"+folderName+"/group"+str(int(actualIndex/1000))+"/image"+str(actualIndex)+".jpg"
    

    fileOutput = ""
    #fileOutput = " --latest latest.jpg" #comment this out if we don't want the latest image - might add overhead in terms of IO, so potentially kill it
    fileOutput = fileOutput+ " -o "+filename


    raspiCommand = raspiDefaults + " -ss "+str(shutterSpeed) + fileOutput
    
    if runWithoutCamera == True:
        print(raspiCommand)
    else :
        system(raspiCommand)
        print(raspiCommand)
        #if actualIndex%100 == 0: #only extract the thumbnail for every 100 images
        exifCommand = "exiftool -b -ThumbnailImage "+filename+" > "+filename.replace(".jpg", "_thumb.jpg")
        system(exifCommand)

        #upload the image to the server
        fileToUpload = filename.replace(".jpg", "_thumb.jpg")

        ll_utils.uploadMedia(fileToUpload, postID)
        
        

    
    

    if runWithoutCamera == True:
        print("normally, analysis of the image happens here, but in this testing, we don't")
    else :

        #analyse the thumbnail as this is a smaller file, should be faster - however, we need to now make a thumbnail for every image - which might make things slower
        img = filename.replace(".jpg", "_thumb.jpg")

        brightnessScore = ll_brightness.brightnessPerceived(img)
        print("brightnessPerceived score: " + str(brightnessScore))

        storeProgress (actualIndex, folderName, shutterSpeed, DG, AG, blueGains, redGains, raw, nightMode, brightnessTarget, brightnessScore, postID)

        #if we're at night, we want he pictures to be a bit darker if shooting in the city
        if nightMode == "city":
            if shutterSpeed > 1000000:
                brightnessTarget = brightnessTarget-2
                if brightnessTarget < nightModeBrightnessTarget:
                    brightnessTarget = nightModeBrightnessTarget
            else:
                brightnessTarget = brightnessTarget+2
                if brightnessTarget > 130:
                    brightnessTarget = 130


        lowBrightness = brightnessTarget - brightnessRange #140
        highBrightness = brightnessTarget + brightnessRange #160
        
        print("brightness target: " + str(brightnessTarget))
        if brightnessScore < 50 or brightnessScore > 200:
            print("extreme low brightness, something")
            brightnessChangeOfSignificance = brightnessChangeOfSignificance + 1
            if brightnessChangeOfSignificance > 2 :
                #we reset this counter, as there's been more than 2 images taken outside of the range, so changes should be made below
                brightnessChangeOfSignificance = 0

        else:
            #we're back to normal
            brightnessChangeOfSignificance = 0
        #brightnessTargetAccuracy = 100 #if the light is 
        #start of brightness checks - first if it's too low, then if too high
        # we only want to make changes when brightnessChangeOfSignificance == 0 as this indicates we haven't had an unexpected flash or dim
        # we don't want to blow out photos, for example, after a lightning photo
        # equally the camera can have misfires and capture black - if this happens, we don't want horrible overexposed shots
        if brightnessScore < lowBrightness and brightnessChangeOfSignificance == 0:
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


        if brightnessScore > highBrightness and brightnessChangeOfSignificance == 0:
            brightnessChangeOfSignificance = brightnessChangeOfSignificance+1
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
        
        #END of brightness checks - first if it's too low, then if too high

    #here we test the auto-white balance using the camera auto settings
    #the reliablity of this isnt great so at first we just log it to compare how close it is from the pre-defined awbg settings above
    #in the event the readings of the auto values are off for 3 photos in a row, we can be confident that there's a real changed required
    #note: ideally we would just analyse the captured image and measure how far off the blues and reds are - this would allow us to amplify or reduce the 
    # reds and blues ()
    #print("awbgSettings was: "+ awbgSettings)
    

    #we only want to run this every 10 images, it takes a lot of time and we don't need to do this every image - or when we first start
    timeToUpdateGains = False
    if actualIndex%10 == 0 or i == 0:
        timeToUpdateGains = True


    if timeToUpdateGains:
        if updateGainsWithLivePreview == True :
            if runWithoutCamera == True:
                print("faking white balance changes, as we don't have the camera available")
                measuredBlueGains = 1.91015625
                measuredRedGains = 3.02734375
                sleep(5)
            else :
                camera = PiCamera(resolution=(1280, 720), framerate=30)
                camera.iso = 400
                camera.meter_mode = 'backlit'
                sleep(1)
                camera.shutter_speed = camera.exposure_speed
                camera.exposure_mode = 'off'
                g = camera.awb_gains
                camera.awb_mode = 'off'
                camera.awb_gains = g
                measuredBlueGains = float(g[0])
                measuredRedGains = float(g[1])
                camera.close()
        
    manageColorGainChanges(measuredBlueGains, measuredRedGains)
    
totalTime = datetime.datetime.now().timestamp() - startTime
print("END time: "+str(totalTime))
