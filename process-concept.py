import rawpy
import imageio
import os
import argparse
import datetime
from time import sleep
from pidng.core import RPICAM2DNG

import sqlite3

#egtting this going requires a few pi installs
#pip install cython
# see "Installation from source on Linux/macOS" from https://pypi.org/project/rawpy/

#sudo apt-get install imagemagick

cwd = os.getcwd()

parser = argparse.ArgumentParser()

parser.add_argument('--shootName', help='name of shootName to process', default="default")
parser.add_argument('--groupBy', help='number to group batching by with --type images or seconds', default="30")
parser.add_argument('--groupByType', help='images or seconds - group images as per --groupBy', default="seconds")

args = parser.parse_args()


#connect to database file
dbconnect = sqlite3.connect("letslapse.db")


def configureDB():
    cursor = dbconnect.cursor()
    sqlStr = "CREATE TABLE IF NOT EXISTS timelapse_stacks "
    sqlStr += "(id INTEGER PRIMARY KEY, timelapse_shoot_id INTEGER, shotIndex INTEGER, captureTime DATETIME, "
    sqlStr += "timeframe INTEGER, stackFromJPEG BOOLEAN, processingTime DATETIME, startImageIndex INTEGER, endImageIndex INTEGER);"
    #print(sqlStr)
    cursor.execute(sqlStr)
    #print(cursor)
    dbconnect.commit()


#set up the DB if it's not yet there
configureDB()


def getIdForShoot(shootName):
    dbconnect.row_factory = sqlite3.Row
    cursor = dbconnect.cursor()
    sqlStr = "SELECT id FROM timelapse_shoots WHERE shootName = '" + shootName + "';"
    #print(sqlStr)

    cursor.execute(sqlStr)
    dbconnect.commit()
    timelapse_shoot_id = -1
    for row in cursor:
        timelapse_shoot_id = (row['id'])

    return timelapse_shoot_id


def getTotalNumberOfImagesCaptured(timelapse_shoot_id):

    dbconnect.row_factory = sqlite3.Row
    cursor = dbconnect.cursor()
    sqlStr = "select captureIndex from timelapse_shots where timelapse_shoot_id = " + str(timelapse_shoot_id) + " order by captureIndex desc limit 1;"
    #print(sqlStr)

    cursor.execute(sqlStr)
    dbconnect.commit()
    totalCaptures = -1
    for row in cursor:
        totalCaptures = (row['captureIndex'])

    return totalCaptures

def getLastStackedImage(timelapse_shoot_id): #this returns the last stacked image and might be 1 in the event no process has taken place (i.e. start)
    dbconnect.row_factory = sqlite3.Row
    cursor = dbconnect.cursor()
    sqlStr = "SELECT * FROM timelapse_stacks WHERE timelapse_shoot_id = '" + str(timelapse_shoot_id) + "' ORDER BY id DESC LIMIT 1;"
    #print(sqlStr)

    cursor.execute(sqlStr)
    dbconnect.commit()
    lastStackedImage = {}
    lastStackedImage["endImageIndex"] = 0
    lastStackedImage["shotIndex"] = 0
    for row in cursor:
        lastStackedImage["endImageIndex"] = row['endImageIndex']
        lastStackedImage["shotIndex"] = row['shotIndex']

    return lastStackedImage

def getImagesToStack(timelapse_shoot_id, fromImageIndex):
    dbconnect.row_factory = sqlite3.Row
    cursor = dbconnect.cursor()
    sqlStr = "SELECT * FROM timelapse_shots WHERE timelapse_shoot_id = " + str(timelapse_shoot_id) + " AND captureIndex = "+str(fromImageIndex+1)+";"
    #print(sqlStr)
    
    cursor.execute(sqlStr)
    dbconnect.commit()
    firstImageInSetTimestamp = -1
    for row in cursor:
        firstImageInSetTimestamp = (row['captureTime'])

    
    fromTimestamp = datetime.datetime.strptime(firstImageInSetTimestamp, "%d/%m/%Y %H:%M:%S")
    toTimestamp = fromTimestamp + datetime.timedelta(0, 25)

    #print(fromTimestamp)

    toTimestampConv = datetime.datetime.strptime( str(toTimestamp), "%Y-%m-%d %H:%M:%S").strftime("%d/%m/%Y %H:%M:%S")
    #print(toTimestampConv)

    dbconnect.row_factory = sqlite3.Row
    cursor = dbconnect.cursor()
    sqlStr = "SELECT id, captureIndex, captureTime FROM timelapse_shots WHERE timelapse_shoot_id = " + str(timelapse_shoot_id) + " AND captureIndex >= "+str(fromImageIndex+1)+" AND captureTime < '"+str(toTimestampConv)+"';"
    cursor.execute(sqlStr)
    dbconnect.commit()
    imagesToStack = []
    for row in cursor:
        imgData = {}
        imgData['captureIndex'] = row['captureIndex']
        imgData['captureTime'] = row['captureTime']
        imagesToStack.append(imgData)
        
    return imagesToStack




def getFiles(path):
    #print(path)
    for file in os.listdir(path):
        if os.path.isfile(os.path.join(path, file)):
            if "_thumb" not in file:
            #print(file.split(".jpg")[1])
                yield os.path.join(file)


def extractToDNG():
    print("extractToDNG() - extracting all DNG images to folder ")
    if os.path.isdir("dng") == True :
        print("dng folder already created")
    else :
        print("dng folder now created")
        os.system("mkdir dng")


    for file in getFiles(cwd+"/"):
        thisFileNoExt = file.split(".jpg")[0]
        print(thisFileNoExt)
        RPICAM2DNG().convert(file)
        os.system("mv " + thisFileNoExt + ".dng dng/")

    print("DNG extraction complete")

def convertFromDNG():
    print("convertFromDNG() - converting all DNG images to JPEG, fixing white balance ")
    if os.path.isdir("converted") == True :
        print("converted folder already created")
    else :
        os.system("mkdir converted")
        print("converted folder now created")

    for file in getFiles(cwd+"/dng"):
        print(file)
        thisFileNoExt = file.split(".dng")[0]

        with rawpy.imread(cwd+"/dng/"+thisFileNoExt+".dng") as raw:
            rgb = raw.postprocess(use_camera_wb=False, use_auto_wb=True, highlight_mode=2)

        imageio.imsave(cwd+"/converted/"+thisFileNoExt+"_render.jpg", rgb)

    print("convertFromDNG() conversion complete")

def stringifyImagesToStack(fromIndex, toIndex):
    stackStart = fromIndex
    stackEnd = toIndex

    curStackIndex = stackStart
    thisFormat = ".jpg"
    #shellStr = "convert"
    imageList = ""
    while curStackIndex < stackEnd:
        #print(x+myInt)
        imageList += " image"+str(curStackIndex)+""+thisFormat
        curStackIndex = curStackIndex+1

    return imageList
    #print(shellStr)


def storeStackImageDB(timelapse_shoot_id, shotIndex, captureTime, timeframe, stackFromJPEG, processingTime, startImageIndex, endImageIndex):
    print("adding record to db")
    cursor = dbconnect.cursor()
    #execute insetr statement
    sqlStr = "INSERT INTO timelapse_stacks "
    sqlStr += "VALUES ("
    sqlStr += "NULL, "
    sqlStr += str(timelapse_shoot_id) +", "+str(shotIndex) +", '"+str(captureTime) +"', "+str(timeframe) +", "+str(stackFromJPEG) +", "+str(processingTime) +", "+str(startImageIndex) +", "+str(endImageIndex)
    sqlStr += ");"
    #print(sqlStr)
    cursor.execute(sqlStr)

    dbconnect.commit()

    if (endImageIndex + 50) < totalNumberOfImagesCaptured:
        #we still have plenty of images to process
        return True
    else:
        sleep(60)
        print("WHOA SLOW DOWN - Don't have images to process")
        return False


def stackImages(timelapse_shoot_id, imagesToStack, shotIndex):
    shotIndex = shotIndex+1
    stackedOutputFolder = "timelapse_"+args.shootName+"/stacked"
    if os.path.isdir(stackedOutputFolder) == True :
        #print(stackedOutputFolder +" folder already created")
        print("processing "+stackedOutputFolder+"/image" + str(shotIndex) + ".jpg")
    else :
        print(stackedOutputFolder +" folder now created")
        os.system("mkdir "+stackedOutputFolder)

    start_time = int(datetime.datetime.now().timestamp())
    #print(imagesToStack)
    imgToConv = ""
    endImageIndex = -1
    startImageIndex = imagesToStack[0]["captureIndex"]
    captureTime = imagesToStack[0]["captureTime"]
    timeframe = args.groupBy
    stackFromJPEG = True
    for image in imagesToStack:
        zeroBasedIndex = int(image['captureIndex']) - 1
        imgToConv +=  "timelapse_"+args.shootName + "/group"+str(int(zeroBasedIndex/1000))+"/image" + str(zeroBasedIndex) + ".jpg "
        
        endImageIndex = image["captureIndex"]
    shellStr = "convert " + imgToConv + "-evaluate-sequence mean "+stackedOutputFolder+"/image"+str(shotIndex)+".jpg"
    #print(shellStr)
    os.system(shellStr)

    processingTime = int(datetime.datetime.now().timestamp()) - start_time
    if processingTime < 1:
        lotsOfPhotosToProcess = False
        exit()

    print("Processed "+str(len(imagesToStack)) + " images in " + str(processingTime) + " seconds, from image"+str(startImageIndex)+".jpg")

    shellStr = "rm " + imgToConv

    return storeStackImageDB(timelapse_shoot_id, shotIndex, captureTime, timeframe, stackFromJPEG, processingTime, startImageIndex, endImageIndex)
    


lotsOfPhotosToProcess = True
timelapse_shoot_id = getIdForShoot(args.shootName)

totalNumberOfImagesCaptured = getTotalNumberOfImagesCaptured(timelapse_shoot_id)

while lotsOfPhotosToProcess is True:
    lastStackedImage = getLastStackedImage(timelapse_shoot_id)
    imagesToStack = getImagesToStack(timelapse_shoot_id, int(lastStackedImage["endImageIndex"]))
    checkOnProgress = stackImages(timelapse_shoot_id, imagesToStack, lastStackedImage["shotIndex"])
    
    if(checkOnProgress == False):
        totalNumberOfImagesCaptured = getTotalNumberOfImagesCaptured(timelapse_shoot_id)


exit()



#extractToDNG()
#convertFromDNG()

#for i in range(1000):
    #imgToConv = stringifyImagesToStack (i*10, (i*10)+10)
#shellStr = "convert " + imgToConv + " -evaluate-sequence mean converted/output_"+str(stackStart)+"_"+str(stackEnd)
#os.system(shellStr)



#convert image10.jpg image11.jpg image12.jpg image13.jpg image14.jpg image15.jpg image16.jpg image17.jpg image18.jpg image19.jpg image20.jpg -evaluate-sequence mean output.jpg

#convert image10.jpg image11.jpg image12.jpg -evaluate-sequence mean output.jpg

#path = 'image25.dng'
#with rawpy.imread(path) as raw:
#    rgb = raw.postprocess()

