from time import sleep
from picamera import PiCamera
from PIL import Image, ExifTags, ImageStat


camera = PiCamera(resolution=(1600, 1200), framerate=30)
# Set ISO to the desired value
camera.iso = 800
# Wait for the automatic gain control to settle
sleep(2)
# Now fix the values
camera.shutter_speed = camera.exposure_speed
camera.exposure_mode = 'off'

g = camera.awb_gains
print("camera.awb_gains: ")
print(g)
camera.awb_mode = 'off'

indoorKohubLight = (309/256),(365/128)
outdoorSunny = (3.2),(1.85)

#camera.awb_gains = indoorKohubLight
# Finally, take several photos with the fixed settings
camera.capture('awbgTest.jpg')

#def getHistogram ( img ):
    

img = Image.open("awbgTest.jpg")
r, g, b = img.split()
#len(r.histogram())
### 256 ###

def scoreHistogram(histogram) :
    thisScore = 0
    for i in range(len(histogram)):
        thisScore = thisScore + histogram[0]
    return thisScore


print("Red: " + str(scoreHistogram(r.histogram())))
print("Green: " + str(scoreHistogram(g.histogram())))
print("Blue: " + str(scoreHistogram(b.histogram())))
