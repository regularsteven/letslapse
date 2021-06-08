from time import sleep
from os import system
from fractions import Fraction
#from picamera import PiCamera
from PIL import Image, ExifTags, ImageStat


#camera = PiCamera(resolution=(1600, 1200), framerate=30)
# Set ISO to the desired value
#camera.iso = 800
# Wait for the automatic gain control to settle
sleep(2)


def scoreHistogram(histogram) :
    thisScore = 0
    for i in range(len(histogram)):
        thisScore = thisScore + histogram[0]
    return thisScore



# Now fix the values
#camera.shutter_speed = camera.exposure_speed
#camera.exposure_mode = 'off'

#autoGains = str(camera.awb_gains)

location = "insideKohub"
#camera.awb_mode = 'off'

indoorKohubLight = 1.20703125,2.78125
outdoorSunny = (3.2),(1.85)

blueGain = 1
redGain = 1
gainIncrement = .5
counter = 0
for bFor in range(6):
    blueGain = bFor* gainIncrement

    for rFor in range(6):
        counter = counter + 1
        redGain = rFor* gainIncrement
        #camera.awb_gains = blueGain,redGain
        print("capturing with gains - RED: " + str(redGain) + ", BLUE: " + str(blueGain) )
        # Finally, take several photos with the fixed settings

        #gFloat = float(sum(Fraction(g) for g in '1 2/3'.split()))

        outputFile = location +"-awbg_settings"+str(blueGain)+","+str(redGain)#+'-awbg_settings'+str(camera.awb_gains)
        
        outputFile = outputFile.replace(' ','').replace('(','_').replace(')','_')
        print("writing: "+outputFile)
        
        #camera.capture("awbtest/"+outputFile+'.jpg')
        shellCommand = "raspistill -t 1 -w 1600 -h 1200 -o awbtest/"+outputFile+".jpg -ss 100000 -dg 2 -ag 2 -awb off -awbg " + str(blueGain)+","+str(redGain)
        print(shellCommand)
        system(shellCommand)
        #def getHistogram ( img ):


        img = Image.open("awbtest/"+outputFile+'.jpg')
        r, g, b = img.split()
        #len(r.histogram())
        ### 256 ###


        #print("Red: " + str(scoreHistogram(r.histogram())))
        #print("Green: " + str(scoreHistogram(g.histogram())))
        #print("Blue: " + str(scoreHistogram(b.histogram())))

        print("RGB Readings :"+str(scoreHistogram(r.histogram())) + ","+str(scoreHistogram(g.histogram()))+","+str(scoreHistogram(b.histogram())))
        
        system("mv awbtest/"+outputFile + ".jpg awbtest/"+str(counter)+outputFile+ "-rgbhist_"+str(scoreHistogram(r.histogram())) + ","+str(scoreHistogram(g.histogram()))+","+str(scoreHistogram(b.histogram())) + ".jpg")
        print("image renamed, waiting 5 seconds")
        print(" ")
        sleep(2)
    sleep(1)