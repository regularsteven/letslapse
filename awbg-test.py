from time import sleep
from os import system
from fractions import Fraction
#from picamera import PiCamera
from PIL import Image, ExifTags, ImageStat
import argparse
#sleep(2)

parser = argparse.ArgumentParser()
parser.add_argument('--img', help='image filename to test')
args = parser.parse_args()



testType = "static" #or "capture"

def scoreHistogram(histogram) :
    thisScore = 0
    for i in range(len(histogram)):
        thisScore = thisScore + histogram[0]
    return thisScore

if testType == "static" :
    img = Image.open(args.img)
    r, g, b = img.split()
    #print(r.histogram())
    #print(g.histogram())
    #print(b.histogram())

    rInt = scoreHistogram(r.histogram())
    gInt = scoreHistogram(g.histogram())
    bInt = scoreHistogram(b.histogram())
    total = rInt + gInt + bInt
    print("RGB Histogram Scores: "+str(scoreHistogram(r.histogram())) + ","+str(scoreHistogram(g.histogram()))+","+str(scoreHistogram(b.histogram())))
    print("RGB Percentages: "+str((rInt / total)*100) + ","+str((gInt / total)*100)+","+str((bInt / total)*100))
    exit()

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

        print("RGB Readings :"+str(scoreHistogram(r.histogram())) + ","+str(scoreHistogram(g.histogram()))+","+str(scoreHistogram(b.histogram())))
        
        system("mv awbtest/"+outputFile + ".jpg awbtest/"+str(counter)+outputFile+ "-rgbhist_"+str(scoreHistogram(r.histogram())) + ","+str(scoreHistogram(g.histogram()))+","+str(scoreHistogram(b.histogram())) + ".jpg")
        print("image renamed, waiting 5 seconds")
        print(" ")
        sleep(2)
    sleep(1)