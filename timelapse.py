#from picamera import PiCamera

import calendar
import time


from os import system
from time import sleep

from datetime import datetime


#from pydng.core import RPICAM2DNG


#camera = PiCamera()
#full resolution = 4056, 3040
#camera.resolution = (4056, 3040)

#sleep(2)
#camera.capture("demo/rawtest.yuv", 'yuv')
#sleep(2)
#d=RPICAM2DNG()
#d.convert("demo/rawyuv.jpg")


#setup 

dayExposure = (0.00001)
nightExposure = 30
#for facing west
sunsetExposure = .01
sunriseExposure = .01

iso = 100 #set 200 for twilight and to 400 for night


# 1 get the current time
# get next transition (if before or after noon) either sunrise or sunset

# from "midnight"
# "start sunrise twilight)" > "sunrise" > "sunrise ramp" > "day" > "sunset ramp" > "sunset" > "end sunset twilight" 



#keyTimeStamps = []

firstLight = "05:30:00" #dawnRamp below - this is the fist spot of light on in the sky
dayBreak = "06:30:00" #sunrise below - when the sun is on the horizon
dayFullStart = "07:30:00" #sunriseRamp below - when the sun has hit an elevation for START full day-sky
dayFullEnd = "17:30:00" #sunsetRamp below - when the sun has hit an elevation for END full day-sky
nightBreak = "18:30:00" #sunset below - when the sun is on the horizon
lastLight = "19:15:00" #duskRamp below - the moment it's the night sky


#debug testing

#testingInterval = 1 #minutes
#testingStartHour = 13
#testingStartMinute = 32
#firstLight = str(testingStartHour)+":"+str(testingStartMinute)+":00" #dawnRamp below - this is the fist spot of light on in the sky
#dayBreak = str(testingStartHour)+":"+str(testingStartMinute+(testingInterval*1))+":00" #sunrise below - when the sun is on the horizon
#dayFullStart = str(testingStartHour)+":"+str(testingStartMinute+(testingInterval*2))+":00" #sunriseRamp below - when the sun has hit an elevation for START full day-sky
#dayFullEnd = str(testingStartHour)+":"+str(testingStartMinute+(testingInterval*3))+":00" #sunsetRamp below - when the sun has hit an elevation for END full day-sky
#nightBreak = str(testingStartHour)+":"+str(testingStartMinute+(testingInterval*4))+":00" #sunset below - when the sun is on the horizon
#lastLight = str(testingStartHour)+":"+str(testingStartMinute+(testingInterval*5))+":00" #duskRamp below - the moment it's the night sky





#print("today: "+year_month_date)
now = datetime.now()
hour_min = now.strftime("%H_%M")
year_month_date = now.strftime("%Y-%m-%d")
tz = "+07:00" #timezone for Thailand
dawnRamp = datetime.fromisoformat(year_month_date+' '+firstLight+tz)
dawnRampTS = dawnRamp.timestamp()

sunrise = datetime.fromisoformat(year_month_date+' '+dayBreak+tz)
sunriseTS = sunrise.timestamp()

sunriseRamp = datetime.fromisoformat(year_month_date+' '+dayFullStart+tz)
sunriseRampTS = sunriseRamp.timestamp()


sunsetRamp = datetime.fromisoformat(year_month_date+' '+dayFullEnd+tz)
sunsetRampTS = sunsetRamp.timestamp()

sunset = datetime.fromisoformat(year_month_date+' '+nightBreak+tz)
sunsetTS = sunset.timestamp()

duskRamp = datetime.fromisoformat(year_month_date+' '+lastLight+tz)
duskRampTS = duskRamp.timestamp()


def configureKeyTimes():
    now = datetime.now()
    hour_min = now.strftime("%H_%M")
    year_month_date = now.strftime("%Y-%m-%d")
    tz = "+07:00" #timezone for Thailand
    dawnRamp = datetime.fromisoformat(year_month_date+' '+firstLight+tz)
    dawnRampTS = dawnRamp.timestamp()

    sunrise = datetime.fromisoformat(year_month_date+' '+dayBreak+tz)
    sunriseTS = sunrise.timestamp()

    sunriseRamp = datetime.fromisoformat(year_month_date+' '+dayFullStart+tz)
    sunriseRampTS = sunriseRamp.timestamp()


    sunsetRamp = datetime.fromisoformat(year_month_date+' '+dayFullEnd+tz)
    sunsetRampTS = sunsetRamp.timestamp()

    sunset = datetime.fromisoformat(year_month_date+' '+nightBreak+tz)
    sunsetTS = sunset.timestamp()

    duskRamp = datetime.fromisoformat(year_month_date+' '+lastLight+tz)
    duskRampTS = duskRamp.timestamp()




shutterSpeed = dayExposure

print(calendar.timegm(time.gmtime()))
variableExposure = 0 #if the exposure is a constant, this will be 0 (false). if we're in a transtion perioud, it's 1 (true)
#initialize variables for use
startTS = 0
endTS = 0
startExposure = 0
endExposure = 0
shootID = now.strftime("%Y_%m_%d_%H_%M")
pauseBetweenShots = 6

storagePath = "shoot/"
for i in range(2400):

    configureKeyTimes()






    variableExposure = 0
    shutterSpeed = dayExposure
    curTimeTS = calendar.timegm(time.gmtime())
    
    iso = 100
    print(curTimeTS)
    #print(dawnRampTS)
    #print(duskRampTS)

    print(str(sunriseRampTS) + " " + str(sunriseTS))

    #default exposure is daylight exposure
    #catch for the night
    if(curTimeTS < dawnRampTS or curTimeTS > duskRampTS):
        print("between dusk and dawn")
        iso = 400
        shutterSpeed = nightExposure


    #fist light / sunrise ramp in
    if(curTimeTS >= dawnRampTS and curTimeTS <= sunriseTS):
        variableExposure = 1
        print("between dawn ramp and sunrise")
        iso = 200
        #set up which variables we're using for variableExposure
        startTS = dawnRampTS
        endTS = sunriseTS
        startExposure = nightExposure
        endExposure = sunriseExposure
    
    if(curTimeTS >= sunriseTS and curTimeTS < sunriseRampTS):
        variableExposure = 1
        
        print("between sunrise and full day light")
        #set up which variables we're using for variableExposure
        startTS = sunriseTS
        endTS = sunriseRampTS
        startExposure = sunriseExposure
        endExposure = dayExposure


    if(curTimeTS >= sunsetRampTS and curTimeTS <= sunsetTS):
        variableExposure = 1
        print("between sunset ramp and sunset")
        #set up which variables we're using for variableExposure
        startTS = sunsetRampTS
        endTS = sunsetTS
        startExposure = dayExposure
        endExposure = sunsetExposure
    
    if(curTimeTS >= sunsetTS and curTimeTS <= duskRampTS):
        variableExposure = 1
        print("between sunset and duskRamp")
        iso = 200
        #set up which variables we're using for variableExposure
        startTS = sunsetTS
        endTS = duskRampTS
        startExposure = sunsetExposure
        endExposure = nightExposure
        
    

    if variableExposure == 1:
        print("variable exposure case")
        #calc percentage between start marker and end marker
        differenceBetween = endTS - startTS #(sunset > sunsetRamp)
        timeIntoMarker = curTimeTS - startTS #(curTime > sunsetRampTS)
        percentageIntoPeriod = (timeIntoMarker/differenceBetween)

        
        endBaseSS = endExposure - startExposure #basline to zero 
        calculatedSS = ((percentageIntoPeriod*endBaseSS))+startExposure

        shutterSpeed = calculatedSS
        print("percentageIntoPeriod: " + str(percentageIntoPeriod))
    else:
        print("constant exposure case")
    

    outputSS =f"{shutterSpeed:.5f}"
    print("shutterSpeed: " +str(outputSS))

    

    #print("shutterSpeed: " + str(shutterSpeed))
    print()
    
    thisFile = "seq_"+shootID+"_{0:04d}-ss_"+str(outputSS)+"-iso_"+str(iso)+"-time_"+hour_min+".jpg".format(i)
    pictureParams = "-ISO "+str(iso)+" -ss "+str(outputSS) + " -co -10" #-w 4000 -h 3000
    system("raspistill -t 1 -o "+storagePath+thisFile+ " "+pictureParams)
    #system()
    #d.convert("/var/www/html/site/shoot/seq_{0:04d}.jpg".format(i))
    sleep(pauseBetweenShots+shutterSpeed)


#for i in range(200):
#    print(i)
#    camera.capture('demo/image{0:04d}.jpg'.format(i))
#    sleep(6)

#system('ffmpeg -framerate 25 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
