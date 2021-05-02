#from picamera import PiCamera
from os import system
from time import sleep


from datetime import datetime

now = datetime.now()

hour_min = now.strftime("%H_%M")

#from pydng.core import RPICAM2DNG


#camera = PiCamera()
#full resolution = 4056, 3040
#camera.resolution = (4056, 3040)

#sleep(2)
#camera.capture("demo/rawtest.yuv", 'yuv')
#sleep(2)
#d=RPICAM2DNG()
#d.convert("demo/rawyuv.jpg")

storagePath = "shoot/"
for i in range(1200):
    thisFile = "seq_"+hour_min+"_{0:04d}.jpg".format(i)
    print(i)
    system("raspistill -t 1 -r -o "+storagePath+thisFile+ " -w 400 -h 300")
    #d.convert("/var/www/html/site/shoot/seq_{0:04d}.jpg".format(i))
    sleep(3)


#for i in range(200):
#    print(i)
#    camera.capture('demo/image{0:04d}.jpg'.format(i))
#    sleep(6)

#system('ffmpeg -framerate 25 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
