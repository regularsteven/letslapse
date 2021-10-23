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

import sqlite3

#extracted utils for broader use and more component oriented approach
import ll_brightness
import ll_utils



#example use:
# python3 ll_timelapse.py --shootName demo
# python3 ll_timelapse.py --shootName testing --raw false --underexposeNights
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
    '--shootName',
    help="Name of folder to use for shoot (default 'default', str",
    default="default")

parser.add_argument(
    '--raw',
    help='Include RAW image in the jpeg (default FALSE, no value required to set TRUE ',
    action='store_true')

parser.add_argument(
    '--startingGains',
    help='Set the kick off gains values for blue and red colour channels (default FLASE, no value required to set TRUE)',
    default="1,1", type=str)

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


#for running tests to measure how many pictures are taken in a timeframe
start_time = int(time.time())



progressData["useThumbnail"] = args.useThumbnail
progressData["shootName"] = args.shootName
progressData["disableAWBG"] = args.disableAWBG
progressData["underexposeNights"] = args.underexposeNights
progressData["includeRAW"] = args.raw

progressData["width"] = args.width
progressData["height"] = progressData["width"] * .75



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


gainsTolerance = .2 #this is how much difference can exist between gains before we change the gains settings 

redGainsChangeOfSignificance = 0
blueGainsChangeOfSignificance = 0
brightnessChangeOfSignificance = 0

includeRaw = ""
if args.raw == True:
    includeRaw = " -r "



#connect to database file
dbconnect = sqlite3.connect("letslapse.db")

def configureDB(progressData):
    #create the core table if it's not there
    cursor = dbconnect.cursor()
    sqlStr = "CREATE TABLE IF NOT EXISTS timelapse_shoots "
    sqlStr += "(id INTEGER PRIMARY KEY, shootName VARCHAR (255), startTime DATETIME, endTime DATETIME, includeRAW BOOLEAN, useThumbnail BOOLEAN, disableAWBG BOOLEAN, underexposeNights BOOLEAN, width INTEGER, height INTEGER);"
    cursor.execute(sqlStr)
    dbconnect.commit()

    #create the table for each individual shoot
    cursor = dbconnect.cursor()
    sqlStr = "CREATE TABLE IF NOT EXISTS timelapse_shots "
    sqlStr += "(id INTEGER PRIMARY KEY, timelapse_shoot_id INTEGER, captureIndex INTEGER, captureTime DATETIME, "
    sqlStr += "shutterSpeed INTEGER, analogueGains DECIMAL, digitalGains DECIMAL, blueGains DECIMAL, redGains DECIMAL, brightnessTarget DECIMAL, brightnessScore DECIMAL);"
    #print(sqlStr)
    cursor.execute(sqlStr)
    dbconnect.commit()


    #to refer to cursor response by name, following is requried
    dbconnect.row_factory = sqlite3.Row

    cursor = dbconnect.cursor()
    sqlStr = "SELECT * FROM timelapse_shoots WHERE shootName = '" + str(progressData["shootName"]) +"';"
    cursor.execute(sqlStr)
    dbconnect.commit()
    
    thisShootId = -1
    for row in cursor:
        thisShootId = row['id']
        progressData['id'] = row['id']
        progressData['shootName'] = row['shootName']
        progressData['startTime'] = row['startTime']
        progressData['includeRAW'] = row['includeRAW']
        progressData['useThumbnail'] = row['useThumbnail']
        progressData['disableAWBG'] = row['disableAWBG']
        progressData['underexposeNights'] = row['underexposeNights']
        progressData['width'] = row['width']
        progressData['height'] = row['height']

        print("shoot in progress")
        

    if thisShootId == -1:
        #add this shoot if it's not there
        cursor = dbconnect.cursor()
        #execute insetr statement
        now = datetime.datetime.now()
        dt_string = now.strftime("%d/%m/%Y %H:%M:%S")
        sqlStr = "INSERT INTO timelapse_shoots "
        sqlStr += "VALUES ("
        sqlStr += "NULL"
        sqlStr += ",'" + str(progressData["shootName"]) + "'"
        sqlStr += ",'" + str(dt_string) + "'"
        sqlStr += ",'" + '' + "'" #endTime
        sqlStr += ",'" + str(progressData["includeRAW"]) + "'"
        sqlStr += ",'" + str(progressData["useThumbnail"]) + "'"
        sqlStr += ",'" + str(progressData["disableAWBG"]) + "'"
        sqlStr += ",'" + str(progressData["underexposeNights"]) + "'"
        sqlStr += ",'" + str(progressData["width"]) + "'"
        sqlStr += ",'" + str(progressData["height"]) + "'"
        sqlStr += ");"
        #print(sqlStr)
        cursor.execute(sqlStr)

        dbconnect.commit()
        
        progressData['id'] = cursor.lastrowid

        #set up default values for use in this new shoot
        progressData["captureIndex"] = 0
        progressData["shutterSpeed"] = 1000 #random number, should take a test auto shot to be better set from kick-off
        progressData["digitalGains"] = 1 #start low
        progressData["analogueGains"] = 1 #start low
            
        progressData["blueGains"] = float(args.startingGains.split(",")[0])
        progressData["redGains"] = float(args.startingGains.split(",")[1])
        
        progressData["underexposeNights"] = args.underexposeNights
        progressData["brightnessTarget"] = brightnessTarget
        progressData["brightnessScore"] = -1 #no value
        #progressData["posidID"] = -1 #no value


    else:
        print("getting most updated data from db")
        dbconnect.row_factory = sqlite3.Row

        cursor = dbconnect.cursor()
        sqlStr = "SELECT * FROM timelapse_shots WHERE timelapse_shoot_id = "+str(thisShootId)+" ORDER BY captureIndex DESC LIMIT 1;"
        cursor.execute(sqlStr)
        dbconnect.commit()
        for row in cursor:
            progressData['captureIndex'] = row['captureIndex']
            progressData['shutterSpeed'] = row['shutterSpeed']
            progressData['analogueGains'] = row['analogueGains']
            progressData['digitalGains'] = row['digitalGains']
            progressData['blueGains'] = row['blueGains']
            progressData['redGains'] = row['redGains']
            progressData['brightnessTarget'] = row['brightnessTarget']
            progressData['brightnessScore'] = row['brightnessScore']



    #print(progressData)
    #exit()

configureDB(progressData)



def storeProgress (progressData):
    print("Store Progress")
    print(progressData)
    #store log
    #filename = "timelapse_"+folder+".log"
    #if path.isfile(filename) == False:
    #    system("touch "+filename)
    #else:
    #f = open(filename, "a")
    #f.write("image"+str(index)+".jpg,"+str(shutterSpeed)+","+str(DG)+","+str(AG)+","+str(blueGains)+","+str(redGains)+","+str(raw)+","+str(nightMode)+","+str(brightnessTarget)+","+str(brightnessScore)+","+str(postID)+"\n")
    #f.close()

    
    cursor = dbconnect.cursor()
    #execute insetr statement
    now = datetime.datetime.now()
    dt_string = now.strftime("%d/%m/%Y %H:%M:%S")
    sqlStr = "INSERT INTO timelapse_shots "
    sqlStr += "VALUES ("
    sqlStr += "NULL"
    sqlStr += ",'" + str(progressData["id"]) + "'"
    sqlStr += ",'" + str(progressData["captureIndex"]) + "'"
    sqlStr += ",'" + str(dt_string) + "'"
    sqlStr += ",'" + str(progressData["shutterSpeed"]) + "'"
    sqlStr += ",'" + str(progressData["analogueGains"]) + "'"
    sqlStr += ",'" + str(progressData["digitalGains"]) + "'"
    sqlStr += ",'" + str(progressData["blueGains"]) + "'"
    sqlStr += ",'" + str(progressData["redGains"]) + "'"
    sqlStr += ",'" + str(progressData["brightnessTarget"]) + "'"
    sqlStr += ",'" + str(progressData["brightnessScore"]) + "'"
    
    sqlStr += ");"
    print(sqlStr)
    cursor.execute(sqlStr)

    dbconnect.commit()
    #print(cursor)
    

    #need to kill this off, but it should stay in place until sqlite is fully integrated
    #with open("progress.txt", "w") as outputfile:
    #    json.dump(progressData, outputfile)




def ultraBasicShoot():
    system("mkdir timelapse_"+progressData["shootName"])
    system("mkdir timelapse_"+progressData["shootName"]+"/group0")
    thumbnailStr = " "
    if progressData["useThumbnail"]:
        thumbnailStr = " --thumb 600:450:30 "

    sysCommand = "nohup raspistill -t 0 -tl 3000 -o timelapse_"+progressData["shootName"]+"/group0/image%04d.jpg"+thumbnailStr+"--latest timelapse_"+progressData["shootName"]+"/latest.jpg &"
    #store progress if required
    progressData["ultraBasic"] = args.ultraBasic

    storeProgress(progressData)
    #system("echo 'ultraBasic\n"+progressData["shootName"]+"' >progress.txt")
    system(sysCommand)
    exit()

if args.ultraBasic == True:
    ultraBasicShoot()




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

    

if path.isdir("timelapse_"+progressData["shootName"]) == True :
    print("directory already created")
else :
    system("mkdir timelapse_"+progressData["shootName"])
    os.chmod("timelapse_"+progressData["shootName"], 0o777)



startTime = datetime.datetime.now().timestamp()
print("start time: "+str(startTime))
captureTimelapse = True
while captureTimelapse is True:




    
    #for testing how many images can be taken in a timeframe 
    if args.exitAfter > 0:
        cur_time = int(time.time())
        if cur_time - start_time >= args.exitAfter:
            print(str(progressData["captureIndex"]) + " images captured in "+ str(cur_time - start_time) + " seconds")
            captureTimelapse = False

    print("-----------------------------------------")
    #print("taking a photo")
    awbgSettings = str(progressData["blueGains"])+","+str(progressData["redGains"]) 
    thumbnailStr = " "
    if progressData["useThumbnail"] == True:
        print(bool(progressData["useThumbnail"]))
        thumbnailStr = " --thumb 600:450:30 "

    

 
    raspiDefaults = "raspistill -t 1 "+includeRaw+"-bm"+thumbnailStr+"-ag 1 -sa -10 -dg "+str(progressData["digitalGains"])+" -ag "+str(progressData["analogueGains"])+" -awb off -awbg "+awbgSettings+" -co -15 -ex off" + " -w "+str(progressData["width"])+" -h "+str(progressData["height"])
    #--
    if path.isdir("timelapse_"+progressData["shootName"]+"/group"+str(int(progressData["captureIndex"]/1000))) == False :
        system("mkdir timelapse_"+progressData["shootName"]+"/group"+str(int(progressData["captureIndex"]/1000)))
        os.chmod("timelapse_"+progressData["shootName"]+"/group"+str(int(progressData["captureIndex"]/1000)), 0o777)
        print("need to create group folder")

    filename = "timelapse_"+progressData["shootName"]+"/group"+str(int(progressData["captureIndex"]/1000))+"/image"+str(progressData["captureIndex"])+".jpg"
    

    fileOutput = ""
    #fileOutput = " --latest latest.jpg" #comment this out if we don't want the latest image - might add overhead in terms of IO, so potentially kill it
    fileOutput = fileOutput+ " -o "+filename


    raspiCommand = raspiDefaults + " -ss "+str(progressData["shutterSpeed"]) + fileOutput
    
    if runWithoutCamera == True:
        print(raspiCommand)
    else :
        system(raspiCommand)
        os.chmod(filename, 0o777)
        print(raspiCommand)
        
        if progressData["useThumbnail"] == True:
            #if progressData["captureIndex"]%100 == 0: #only extract the thumbnail for every 100 images
            exifCommand = "exiftool -b -ThumbnailImage "+filename+" > "+filename.replace(".jpg", "_thumb.jpg")
            system(exifCommand)

        #upload the image to the server
        #fileToUpload = filename.replace(".jpg", "_thumb.jpg")

        #ll_utils.uploadMedia(fileToUpload, postID)

    progressData["captureIndex"] = progressData["captureIndex"] + 1
    



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
                progressData["digitalGains"] = progressData["digitalGains"] + DGIncrement
                if progressData["digitalGains"] > maxDG : 
                    progressData["digitalGains"] = maxDG

            if progressData["shutterSpeed"] > 6000000 :
                progressData["analogueGains"] = progressData["analogueGains"] + AGIncrement
                if progressData["analogueGains"] > maxAG : 
                    progressData["analogueGains"] = maxAG
                if args.exitAfter > 0: #only run this in normal mode, no need for exitAfter tests
                    print("getting very dark, increment AG: "+str(progressData["analogueGains"]))

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
                progressData["digitalGains"] = progressData["digitalGains"] - DGIncrement
                if progressData["digitalGains"] < 1 : 
                    progressData["digitalGains"] = 1

            if progressData["shutterSpeed"] < 6000000 :
                progressData["analogueGains"] = progressData["analogueGains"] - AGIncrement
                if progressData["analogueGains"] < 1 : 
                    progressData["analogueGains"] = 1

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
        if progressData["captureIndex"]%10 == 0:
            timeToUpdateGains = True

        if timeToUpdateGains:
            if updateGainsWithLivePreview == True :
                if runWithoutCamera == True:
                    print("faking white balance changes, as we don't have the camera available")
                    measuredBlueGains = 1.91015625
                    measuredRedGains = 3.02734375
                    sleep(5)
                else :
                    print("detectAWBG - calculate captured gains from camera")
                    measuredGains = ll_utils.detectAWBG()
                    print(measuredGains)
                    
            
            manageColorGainChanges(float(measuredGains[0]), float(measuredGains[1]))
    
totalTime = datetime.datetime.now().timestamp() - startTime
print("EXIT - END time: "+str(totalTime))
