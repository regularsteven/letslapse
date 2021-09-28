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
import time
from time import sleep
import datetime
import argparse
import json
import os.path
from os import path


#extracted utils for broader use and more component oriented approach
import ll_brightness
import ll_utils



#example use:
# python3 ll_timelapse.py --folderName demo
# python3 ll_timelapse.py --folderName testing --raw false --underexposeNights
# python3 ll_timelapse.py --exitAfter 30
# python3 ll_timelapse.py --exitAfter 30 --useThumbnail

parser = argparse.ArgumentParser()
parser.add_argument(
    '--exitAfter', 
    help="Number of seconds to run before quiting, useful for testing (default 0, int)", 
    default=0, type=int)

parser.add_argument(
    '--width', 
    help="Image width in pixels to capture, height is 0.75 of height (default 4096, int)",
    default=4096, type=int)

parser.add_argument(
    '--useThumbnail',
    help="Include thumbnail, can impact performance if included (default FALSE, no value required to set TRUE)",
    action='store_true')

parser.add_argument(
    '--folderName',
    help="Name of folder to use for shoot (default 'default', str",
    default="default")

parser.add_argument(
    '--raw',
    help='Include RAW image in the jpeg (default FALSE, no value required to set TRUE ',
    action='store_true')

parser.add_argument(
    '--disableAWBG',
    help='Stop AWBG color correction. NOT recommend for JPEG ONLY unless RAW color correction is planned (default FLASE, no value required to set TRUE)',
    action='store_true')

parser.add_argument(
    '--underexposeNights',
    help='Can help low light shooting where bright elements are present in shot; will result in darker images',
    action='store_true')

parser.add_argument(
    '--ultraBasic',
    help='Use core raspberry pi timelapse mode with no customisation',
    action='store_true')

args = parser.parse_args()

#this will be the main progress repository which will output to progress.txt in case of restart / crash
progressData = {}



progressData["width"] = args.width
progressData["height"] = progressData["width"] * .75


#for running tests to measure how many pictures are taken in a timeframe
start_time = int(time.time())


#thumbnailConfig
progressData["useThumbnail"] = args.useThumbnail

progressData["folderName"] = args.folderName




progressData["disableAWBG"] = args.disableAWBG

progressData["underexposeNights"] = args.underexposeNights


def storeProgress (progressData):
    #print("storeProgress: folder = "+ folder + ", nightMode="+str(nightMode)+", brightnessTarget="+str(brightnessTarget)+", brightnessScore="+str(brightnessScore) )
    #store log
    #filename = "timelapse_"+folder+".log"
    #if path.isfile(filename) == False:
    #    system("touch "+filename)
    #else:
    #f = open(filename, "a")
    #f.write("image"+str(index)+".jpg,"+str(shutterSpeed)+","+str(DG)+","+str(AG)+","+str(blueGains)+","+str(redGains)+","+str(raw)+","+str(nightMode)+","+str(brightnessTarget)+","+str(brightnessScore)+","+str(postID)+"\n")
    #f.close()

    with open("progress.txt", "w") as outputfile:
        json.dump(progressData, outputfile)




def ultraBasicShoot():
    system("mkdir timelapse_"+progressData["folderName"])
    system("mkdir timelapse_"+progressData["folderName"]+"/group0")
    thumbnailStr = " "
    if progressData["useThumbnail"]:
        thumbnailStr = " --thumb 600:450:30 "

    sysCommand = "nohup raspistill -t 0 -tl 3000 -o timelapse_"+progressData["folderName"]+"/group0/image%04d.jpg"+thumbnailStr+"--latest timelapse_"+progressData["folderName"]+"/latest.jpg &"
    #store progress if required
    progressData["ultraBasic"] = args.ultraBasic

    storeProgress(progressData)
    #system("echo 'ultraBasic\n"+progressData["folderName"]+"' >progress.txt")
    system(sysCommand)
    exit()

if args.ultraBasic == True:
    ultraBasicShoot()



preResetCount = 0 #this is the value that will be overriden in the even there was a crash or bad exit / restart / battery change
maxShutterSpeed = 25000000 #20 seconds in ver low light 
#DG and AG values for virtualisation of ISO - ISO doesn't seem to work with -ex night and adds overhead in processing time,
#so need to implement -dg value (1 > 8) - going above 4 results in very noisy images, requires more testing
maxDG = 4
DGIncrement = .25
maxAG = 3
AGIncrement = .1


#the bigger brightnessTarget, the brighter the image
brightnessTarget = 130
#underexposeNights brightness target
underexposeNightsBrightnessTarget = 80
#the bigger brightnessRange, the less changes will take place
brightnessRange = 10


includeRaw = ""
if args.raw == True:
    includeRaw = " -r "


#print (includeRaw)
#exit()


if path.isfile("progress.txt") == False:
    
    print("New shoot, no progress file, making one... ")
    #this is the time to create a new post in the CMS
    #postID = ll_utils.createPost(folderName + "Timelapse")
    
    progressData["index"] = 0
    progressData["shutterSpeed"] = 1000 #random number, should take a test auto shot to be better set from kick-off
    progressData["DG"] = 1 #start low
    progressData["AG"] = 1 #start low
        
    progressData["blueGains"] = 3.484375
    progressData["redGains"] = 1.44921875

    #for natural light, great in daylight and moonlight - too yellow in street artificial light
        #at a starting point, set the red and blue values to the above, but at the end of every photo, do a test to see how far we are off the white balance
        #in a similar way to exposure, make minor adjustments - but only if there's two or more than 3 white balance readings that are out of range of the default
        #white balance settings

    progressData["raw"] = args.raw
    progressData["underexposeNights"] = args.underexposeNights
    progressData["brightnessTarget"] = brightnessTarget
    progressData["brightnessScore"] = -1 #no value
    progressData["posidID"] = -1 #no value

    storeProgress (progressData)

else :
    
    with open('progress.txt') as json_file:
        progressData = json.load(json_file)

    print(progressData)
    if "ultraBasic" not in progressData:
        progressData["ultraBasic"] = False

    if progressData["ultraBasic"] == True:
        print("ultraBasic in place")
        ultraBasicShoot()
    else:
        print("some issue")
        preResetCount = progressData["index"] #index on load to ensure files are not overridden
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
    global redGainsChangeOfSignificance,blueGainsChangeOfSignificance
    print("auto-measured gains: "+str(measuredBlueGains) + ", "+str(measuredRedGains))
    #print("blueGains: " + str(blueGains) +" measuredBlueGains " + str(measuredBlueGains))

    #print("redGains: " + str(redGains) +" measuredRedGains " + str(measuredRedGains))

    if measuredRedGains > (progressData["redGains"]+gainsTolerance) or measuredRedGains < (progressData["redGains"]-gainsTolerance) : 
        print("redGainsChangeOfSignificance = "+str(redGainsChangeOfSignificance))
        redGainsChangeOfSignificance = redGainsChangeOfSignificance + 1
    else :
        #print("red gains in range, no need to change")
        redGainsChangeOfSignificance = 0

    if measuredBlueGains > (progressData["blueGains"]+gainsTolerance) or measuredBlueGains < (progressData["blueGains"]-gainsTolerance) : 
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
        progressData["redGains"] = progressData["redGains"] - ((progressData["redGains"] - measuredRedGains)/5)

    
    if blueGainsChangeOfSignificance > 3 :
        print("blueGain CHANGE from sequential outside of range pictures")
        progressData["blueGains"] = progressData["blueGains"] - ((progressData["blueGains"] - measuredBlueGains)/5)

    

if path.isdir("timelapse_"+progressData["folderName"]) == True :
    print("directory already created")
else :
    system("mkdir timelapse_"+progressData["folderName"])


startTime = datetime.datetime.now().timestamp()
print("start time: "+str(startTime))
for i in range(80000):

    #for testing how many images can be taken in a timeframe 
    if args.exitAfter > 0:
        cur_time = int(time.time())
        if cur_time - start_time >= args.exitAfter:
            print(str(i) + " images captured in "+ str(cur_time - start_time) + " seconds")
            exit()

    actualIndex = i + preResetCount
    progressData["index"] = actualIndex
    
    print("-----------------------------------------")
    #print("taking a photo")
    awbgSettings = str(progressData["blueGains"])+","+str(progressData["redGains"]) 
    thumbnailStr = " "
    if progressData["useThumbnail"]:
        thumbnailStr = " --thumb 600:450:30 "
        
    raspiDefaults = "raspistill -t 1 "+includeRaw+"-bm"+thumbnailStr+"-ag 1 -sa -10 -dg "+str(progressData["DG"])+" -ag "+str(progressData["AG"])+" -awb off -awbg "+awbgSettings+" -co -15 -ex off" + " -w "+str(progressData["width"])+" -h "+str(progressData["height"])
    #--
    if path.isdir("timelapse_"+progressData["folderName"]+"/group"+str(int(actualIndex/1000))) == False :
        system("mkdir timelapse_"+progressData["folderName"]+"/group"+str(int(actualIndex/1000)))
        print("need to create group folder")

    filename = "timelapse_"+progressData["folderName"]+"/group"+str(int(actualIndex/1000))+"/image"+str(actualIndex)+".jpg"
    

    fileOutput = ""
    #fileOutput = " --latest latest.jpg" #comment this out if we don't want the latest image - might add overhead in terms of IO, so potentially kill it
    fileOutput = fileOutput+ " -o "+filename


    raspiCommand = raspiDefaults + " -ss "+str(progressData["shutterSpeed"]) + fileOutput
    
    if runWithoutCamera == True:
        print(raspiCommand)
    else :
        system(raspiCommand)
        print(raspiCommand)
        
        if progressData["useThumbnail"] == True:
            #if actualIndex%100 == 0: #only extract the thumbnail for every 100 images
            exifCommand = "exiftool -b -ThumbnailImage "+filename+" > "+filename.replace(".jpg", "_thumb.jpg")
            system(exifCommand)

        #upload the image to the server
        #fileToUpload = filename.replace(".jpg", "_thumb.jpg")

        #ll_utils.uploadMedia(fileToUpload, postID)

    

    if runWithoutCamera == True:
        print("normally, analysis of the image happens here, but in this testing, we don't")
    else :

        #analyse the thumbnail as this is a smaller file, should be faster - however, we need to now make a thumbnail for every image - which might make things slower
        if progressData["useThumbnail"] == True:
            img = filename.replace(".jpg", "_thumb.jpg")
        else: 
            img = filename
        

        progressData["brightnessScore"] = ll_brightness.brightnessPerceived(img)
        if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
            print("brightnessPerceived score: " + str(progressData["brightnessScore"]))

        storeProgress (progressData)

        #if we're at night, we want he pictures to be a bit darker if shooting in the city
        if progressData["underexposeNights"] == True:
            if progressData["shutterSpeed"] > 1000000:
                brightnessTarget = brightnessTarget-2
                if brightnessTarget < underexposeNightsBrightnessTarget:
                    brightnessTarget = underexposeNightsBrightnessTarget
            else:
                brightnessTarget = brightnessTarget+2
                if brightnessTarget > 130:
                    brightnessTarget = 130


        lowBrightness = brightnessTarget - brightnessRange #140
        highBrightness = brightnessTarget + brightnessRange #160
        
        if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
            print("brightness target: " + str(brightnessTarget))
        if progressData["brightnessScore"] < 50 or progressData["brightnessScore"] > 200:
            if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
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
        if progressData["brightnessScore"] < lowBrightness and brightnessChangeOfSignificance == 0:
            if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                print("low brightness")
            brightnessTargetAccuracy = (progressData["brightnessScore"]/brightnessTarget)
            progressData["shutterSpeed"] = int(progressData["shutterSpeed"]) / (brightnessTargetAccuracy)
            if(progressData["shutterSpeed"] > maxShutterSpeed): #max shutterspeed of 8 seconds
                progressData["shutterSpeed"] = maxShutterSpeed
            if progressData["shutterSpeed"] > 2000000 :
                #print("too little light, hard coding shutter and making ISO dynamic with virtualization of ag and dg")
                if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                    print("increasing digital gain, shutter over 2 seconds")
                progressData["DG"] = progressData["DG"] + DGIncrement
                if progressData["DG"] > maxDG : 
                    progressData["DG"] = maxDG

            if progressData["shutterSpeed"] > 6000000 :
                progressData["AG"] = progressData["AG"] + AGIncrement
                if progressData["AG"] > maxAG : 
                    progressData["AG"] = maxAG
                if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                    print("getting very dark, increment AG: "+str(progressData["AG"]))

            if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                print("new shutterspeed: " + str(progressData["shutterSpeed"]))


        if progressData["brightnessScore"] > highBrightness and brightnessChangeOfSignificance == 0:
            brightnessChangeOfSignificance = brightnessChangeOfSignificance+1
            if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                print("high brightness")
            brightnessTargetAccuracy = (progressData["brightnessScore"]/brightnessTarget)
            if progressData["brightnessScore"] > 200 :
                #case where the shot is very over-exposed, as such double the amount of adjustment
                brightnessTargetAccuracy = brightnessTargetAccuracy*2
            
            progressData["shutterSpeed"] = int(progressData["shutterSpeed"]) / (brightnessTargetAccuracy)

            if progressData["shutterSpeed"] < 2000000: #if we're getting faster than a 2 second exposure
                progressData["DG"] = progressData["DG"] - DGIncrement
                if progressData["DG"] < 1 : 
                    progressData["DG"] = 1

            if progressData["shutterSpeed"] < 6000000 :
                progressData["AG"] = progressData["AG"] - AGIncrement
                if progressData["AG"] < 1 : 
                    progressData["AG"] = 1

            if(progressData["shutterSpeed"] < 100): 
                progressData["shutterSpeed"] = 100
                if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                    print("too much light, hard coding shutter")
            
            if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                print("new shutterspeed: " + str(progressData["shutterSpeed"]))
        
        #END of brightness checks - first if it's too low, then if too high

    #here we test the auto-white balance using the camera auto settings
    #the reliablity of this isnt great so at first we just log it to compare how close it is from the pre-defined awbg settings above
    #in the event the readings of the auto values are off for 3 photos in a row, we can be confident that there's a real changed required
    #note: ideally we would just analyse the captured image and measure how far off the blues and reds are - this would allow us to amplify or reduce the 
    # reds and blues ()
    
    

    #we only want to run this every 10 images, it takes a lot of time and we don't need to do this every image - or when we first start
    if progressData["disableAWBG"] == False:

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
