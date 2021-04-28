#from picamera import PiCamera
from os import system
from time import sleep
#from pydng.core import RPICAM2DNG


#camera = PiCamera()
#full resolution = 4056, 3040
#camera.resolution = (4056, 3040)

#sleep(2)
#camera.capture("demo/rawtest.yuv", 'yuv')
#sleep(2)
#d=RPICAM2DNG()
#d.convert("demo/rawyuv.jpg")


for i in range(1200):
     print(i)
     system("raspistill -r -o /var/www/html/site/shoot/seq_{0:04d}.jpg".format(i))
 #    d.convert("/var/www/html/site/shoot/seq_{0:04d}.jpg".format(i))
     sleep(1)


#for i in range(200):
#    print(i)
#    camera.capture('demo/image{0:04d}.jpg'.format(i))
#    sleep(6)

#system('ffmpeg -framerate 25 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
