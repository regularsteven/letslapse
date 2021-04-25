from picamera import PiCamera
from os import system
from time import sleep


camera = PiCamera()
#full resolution = 4056, 3040
camera.resolution = (4056, 3040)

for i in range(200):
    print(i)
    camera.capture('demo/image{0:04d}.jpg'.format(i))
    sleep(6)

system('ffmpeg -framerate 25 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
