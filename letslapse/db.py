import sqlite3
from datetime import datetime

import letslapse.config as config

#db related for internal DB storage
dbconnect = sqlite3.connect(config.device_storage + "letslapse.db")

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
