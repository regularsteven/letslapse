from os import system
import requests, os, json
from time import sleep
from datetime import datetime
import json
import sqlite3

def isPi():
    checkIfSystemHasARM = os.uname()[4][:3].startswith("arm")
    print("system has ARM: " + str(checkIfSystemHasARM))
    return (checkIfSystemHasARM)


if isPi():
    from picamera import PiCamera


def detectAWBG():
    print("running camera to detect color temperature")
    camera = PiCamera(resolution=(1280, 720), framerate=30)
    # Set ISO and meter mode to the desired value
    camera.iso = 400
    camera.meter_mode = 'matrix'
    # Wait for the automatic gain control to settle
    sleep(1)
    # Now fix the values
    camera.shutter_speed = camera.exposure_speed
    camera.exposure_mode = 'off'
    g = camera.awb_gains
    camera.awb_mode = 'off'
    camera.awb_gains = g
    measuredGains = g
    camera.close()
    return measuredGains

#print(detectAWBG())


protocol = "http://"
letslapseDomain = "letslapse.local"
letslapseCMS = protocol+letslapseDomain

mediaEndpoint = "/wp-json/wp/v2/media/"
postsEndpoint = "/wp-json/wp/v2/posts/"
usersEndpoint = "/wp-json/wp/v2/users/"

#user credentials to come from device
username = os.getenv('API_USER') #"pizero-dev"
password = os.environ.get('API_PASSWORD') #"YZbc)WdcolGV3P0HuK6jS2sf"

username = "pizero-dev"
password = "YZbc)WdcolGV3P0HuK6jS2sf"

letslapseCMSOnline = False
userAuthenticated = False


def convert_str_bool(s):
    trues = ["true", "True", "1"]
    print(trues)
    print(s)
    if str(s) in trues:
        return True
    else: 
        return False




def logInCMS():
    return -1
    url=letslapseCMS+usersEndpoint+"me"
    print(url)

    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password) )
    if res:
        jsonResp = json.loads(res.text)["capabilities"]
        if 'subscriber' in jsonResp:
            print("registered, but not yet provisioned")
        elif 'author' in jsonResp:
            print("provisioned and ready")
        elif 'administrator' in jsonResp:
            print("admin user")
        else:
            print (json.loads(res.text)["capabilities"])
    else: 
        print(res.status_code)
        


def registerCMS():
    return -1
    url=letslapseCMS+usersEndpoint+"register"
    print(url)
    data = {
        'username':"somename",
        'email':'someemail@whatever.com',
        'password':'privateas'
        }
    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        data=json.dumps(data) )

    print(res.status_code)

    
def pingCMS(): 
    return -1
    hostname = letslapseDomain
    response = os.system("ping -c 1 " + hostname)

    #and then check the response...
    if response == 0:
        print(hostname + ' is up!')
        letslapseCMSOnline = True
    else:
        letslapseCMSOnline = False
        print(hostname + ' is down!')
    
    print("letslapseCMSOnline: " + str(letslapseCMSOnline))



def convertImagesToVideo(inputImage, outputVideo):
    system("ffmpeg -i "+inputImage+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 "+outputVideo+".mp4")





def createPost(postName):
    return -1
    url=letslapseCMS+postsEndpoint
    data = {
        'title':postName,
        'content':'[gallery]',
        'status':'private'
        }
    res = requests.post(url=url,
                        data=json.dumps(data),
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password))
    print("createPost")
    print(res.status_code)
    if res:
        letslapseCMSOnline = True
        return (json.loads(res.text)['id'])
    else:
        letslapseCMSOnline = False
        return -1


def attachPostToImage(postID, imageId):
    return -1
    url=letslapseCMS+mediaEndpoint+str(imageId)
    print(url)

    metaToUpdate=json.dumps({"post":postID})
    print(metaToUpdate)

    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password),
                        data=(metaToUpdate))
    print(res.text)

def uploadMedia(imgPath, postID):
    return -1
    url=letslapseCMS+mediaEndpoint

    data = open(imgPath, 'rb').read()
    fileName = os.path.basename(imgPath)

    res = requests.post(url=url,
                        data=data,
                        headers={ 'Content-Type': 'image/jpg','Content-Disposition' : 'attachment; filename=%s'% fileName},
                        auth=(username, password))

    if res:
        #once the image is uploaded, we can attach to an existing post... 
        letslapseCMSOnline = True
        print("success - " + str(postID) + " " +  str(json.loads(res.text)['id']))
        attachPostToImage(postID, json.loads(res.text)['id'])
        return (json.loads(res.text)['id'])
    else:
        letslapseCMSOnline = False
        return -1
   



#db related for internal DB storage


dbconnect = sqlite3.connect("letslapse.db")
dbconnect.row_factory = sqlite3.Row



def startCreateDB():
    #create the core table if it's not there
    db = dbconnect.cursor()
    sqlStr = "CREATE TABLE IF NOT EXISTS timelapse_shoots "
    sqlStr += "(id INTEGER PRIMARY KEY, shootName VARCHAR (255), startTime DATETIME, endTime DATETIME, includeRAW BOOLEAN, useThumbnail BOOLEAN, disableAWBG BOOLEAN, underexposeNights BOOLEAN, lockExposure BOOLEAN, delayBetweenShots INTEGER, width INTEGER, height INTEGER);"
    db.execute(sqlStr)
    dbconnect.commit()

    #create the table for each individual shoot
    db = dbconnect.cursor()
    sqlStr = "CREATE TABLE IF NOT EXISTS timelapse_shots "
    sqlStr += "(id INTEGER PRIMARY KEY, timelapse_shoot_id INTEGER, captureIndex INTEGER, captureTime DATETIME, "
    sqlStr += "shutterSpeed INTEGER, analogueGains DECIMAL, digitalGains DECIMAL, blueGains DECIMAL, redGains DECIMAL, brightnessTarget DECIMAL, brightnessScore DECIMAL);"
    #print(sqlStr)
    db.execute(sqlStr)
    dbconnect.commit()



def createProgressTxtFromDB() : 
    db = dbconnect.cursor()
    #if we have a known shoot, no need for the following
    sqlStr = "select * from timelapse_shots inner join timelapse_shoots on timelapse_shots.timelapse_shoot_id=timelapse_shoots.id where timelapse_shoots.endTime = '' ORDER by id DESC limit 1;"
    rows = db.execute(sqlStr).fetchone()
    dbconnect.commit()
    
    jsonOutput = "{"

    jsonOutput += '"status":"progress",'
    if (isinstance(rows, sqlite3.Row)):
        names = rows.keys()
        curCount = 0
        for colName in names:
            if curCount > 2: #have a dodgy bit of sql and the id from both tables gets sucked in, but we don't want this, hence we start from column 2
                jsonOutput += "," #only add this as the prefix for the 1st on (2nd, but zero based)

            if curCount > 1:
                jsonOutput += '"'+ ( str(colName) + '":"' + str(rows[colName]) ) + '"'
            curCount = curCount + 1
    else:
        print("nothing in progress")
        jsonOutput += '"status": "ready"'
    jsonOutput += "}"

    return jsonOutput


def killTimelapseDB():
    db = dbconnect.cursor()
    now = datetime.now()
    dt_string = now.strftime("%d/%m/%Y %H:%M:%S")
    sqlStr = "update timelapse_shoots set endTime = '"+str(dt_string)+"' where endTime == '';"
    db.execute(sqlStr)
    dbconnect.commit()
