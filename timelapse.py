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

dayExposure = .0001
nightExposure = 30
#for facing west
sunsetExposure = 1
sunriseExposure = 2

iso = 100 #set 200 for twilight and to 400 for night


# 1 get the current time
# get next transition (if before or after noon) either sunrise or sunset

# from "midnight"
# "start sunrise twilight)" > "sunrise" > "sunrise ramp" > "day" > "sunset ramp" > "sunset" > "end sunset twilight" 



#keyTimeStamps = []

now = datetime.now()

hour_min = now.strftime("%H_%M")
year_month_date = now.strftime("%Y-%m-%d")

print("today: "+year_month_date)

dawnRamp = datetime.fromisoformat(year_month_date+' 05:30:00+07:00')
dawnRampTS = dawnRamp.timestamp()

sunrise = datetime.fromisoformat(year_month_date+' 06:00:00+07:00')
sunriseTS = sunrise.timestamp()

sunriseRamp = datetime.fromisoformat(year_month_date+' 07:00:00+07:00')
sunriseRampTS = sunriseRamp.timestamp()


sunsetRamp = datetime.fromisoformat(year_month_date+' 08:10:00+07:00')
sunsetRampTS = sunsetRamp.timestamp()

sunset = datetime.fromisoformat(year_month_date+' 18:30:00+07:00')
sunsetTS = sunset.timestamp()

duskRamp = datetime.fromisoformat(year_month_date+' 17:30:00+07:00')
duskRampTS = duskRamp.timestamp()

shutterSpeed = dayExposure



print(calendar.timegm(time.gmtime()))


storagePath = "shoot/"
for i in range(1200):
    curTimeTS = calendar.timegm(time.gmtime())
    thisFile = "seq_"+hour_min+"_{0:04d}.jpg".format(i)
    
    
    
    if(curTimeTS < dawnRampTS or curTimeTS > duskRampTS):
        shutterSpeed = nightExposure
    
    if(curTimeTS > sunriseTS and curTimeTS < sunriseRampTS):
        print("after sunrise AND before full daylight")

    if(curTimeTS > sunsetRampTS and curTimeTS < sunsetTS):
        print("between sunset ramp and sunset")
        #calc percentage to sunset
        differenceBetween = sunsetTS - sunsetRampTS #(sunset > sunsetRamp)
        timeIntoMarker = curTimeTS - sunsetRampTS #(curTime > sunsetRampTS)
        percentageIntoPeriod = (timeIntoMarker/differenceBetween)

        
        endBaseSS = sunsetExposure - dayExposure #basline to zero 
        calculatedSS = ((percentageIntoPeriod*endBaseSS))+dayExposure

        shutterSpeed = calculatedSS
        print("percentageIntoPeriod:")
        print(percentageIntoPeriod)
        print("shutterSpeed:")
        print(shutterSpeed)
    
    print(curTimeTS)
    print(sunsetRampTS)
    print(sunsetTS)

    #print("shutterSpeed: " + str(shutterSpeed))
    print()
    #system("raspistill -t 1 -r -o "+storagePath+thisFile+ " -w 400 -h 300")
    #d.convert("/var/www/html/site/shoot/seq_{0:04d}.jpg".format(i))
    sleep(1)


#for i in range(200):
#    print(i)
#    camera.capture('demo/image{0:04d}.jpg'.format(i))
#    sleep(6)

#system('ffmpeg -framerate 25 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
