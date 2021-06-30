runWithoutCamera = False
updateGainsWithLivePreview = True

from os import system

if runWithoutCamera != True: 
    from picamera import PiCamera
    from PIL import Image, ExifTags, ImageStat
from time import sleep
from decimal import Decimal
import argparse
import math

import os.path
from os import path


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
parser.add_argument('--folderName', help="name of folder to use")
parser.add_argument('--imageCount', help='number of images')
parser.add_argument('--startup', help='flag for startup on boot, from reboot.sh')

#example use:
# python3 timelapse-auto --folderName demo

args = parser.parse_args()


def storeProgress (index, folder,shutterSpeed, DG, AG, blueGains, redGains):
    system("echo '"+str(index)+"\n"+folder+"\n"+str(float(shutterSpeed))+"\n"+str(DG)+"\n"+str(AG)+"\n"+str(blueGains)+"\n"+str(redGains)+"' >progress.txt")


print(path.isfile("progress.txt"))

preResetCount = 0 #this is the value that will be overriden in the even there was a crash or bad exit / restart / battery change

if args.startup == None:
    print("normal startup")
else :
    print("starting up from reboot.sh script, should occur on powerup")
    system("touch rebootbreadcrumb.txt")
    exit()




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





folderName = "default"
if args.folderName == None:
    print("No folder name specified for project")
else : 
    folderName = args.folderName
    print("normal operation")
#exit()


if path.isfile("progress.txt") == False:
    storeProgress (0, folderName, shutterSpeed, DG, A, blueGains, redGains)
    print("New shoot, no progress file, making one... ")
    
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

    awbgSettings = str(blueGains)+","+str(redGains)
    #for line in Lines:
        #lineCount += 1
        #print((line.strip()))
    #print("END values")
#exit()



#print(args.imageCount)

#logic from https://stackoverflow.com/a/3498247 (from https://stackoverflow.com/users/64313/cmcginty)
def brightnessPerceived ( img ):
    stat = ImageStat.Stat(img)
    r,g,b = stat.rms
    return math.sqrt( 0.241*(r**2) + 0.691*(g**2) + 0.068*(b**2) )



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

if path.isdir("auto_"+folderName) == True :
    print("directory already created")
else :
    system("mkdir auto_"+folderName)

for i in range(80000):
    actualIndex = i + preResetCount
    #print("")
    print("-----------------------------------------")
    #print("taking a photo")
    raspiDefaults = "raspistill -t 1 -bm -ag 1 -sa -10 -dg "+str(DG)+" -ag "+str(AG)+" -awb off -awbg "+awbgSettings+" -co -15 -ex off" + resolution

    if path.isdir("auto_"+folderName+"/group"+str(int(actualIndex/1000))) == False :
        system("mkdir auto_"+folderName+"/group"+str(int(actualIndex/1000)))
        print("need to create group folder")

    filename = "auto_"+folderName+"/group"+str(int(actualIndex/1000))+"/image"+str(actualIndex)+".jpg"
    

    fileOutput = ""
    #fileOutput = " --latest latest.jpg" #comment this out if we don't want the latest image - might add overhead in terms of IO, so potentially kill it
    fileOutput = fileOutput+ " -o "+filename


    raspiCommand = raspiDefaults + " -ss "+str(shutterSpeed) + fileOutput
    
    if runWithoutCamera == True:
        print(raspiCommand)
    else :
        system(raspiCommand)
        print(raspiCommand)
    

    
    storeProgress (actualIndex, folderName, shutterSpeed, DG, AG, blueGains, redGains)

    if runWithoutCamera == True:
        print("normally, analysis of the image happens here, but in this testing, we don't")
    else :

        img = Image.open(filename)
        exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
        #print("Recorded EXIF ShutterSpeedValue = "+ str(exif["ShutterSpeedValue"]))
        lastShotExposureTime = str(exif["ExposureTime"])

        #print("ExposureTime = "+ str(lastShotExposureTime))
        #print("ISOSpeedRatings = " + str(exif["ISOSpeedRatings"]))
        brightnessScore = brightnessPerceived(img)
        print("brightnessPerceived score: " + str(brightnessScore))

        brightnessTarget = 130
        brightnessRange = 10

        lowBrightness = brightnessTarget - brightnessRange #140
        highBrightness = brightnessTarget + brightnessRange #160
        
        
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
    #print("awbgSettings is: "+ awbgSettings)
    sleep(2)

print("end")
