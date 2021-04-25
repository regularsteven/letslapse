from picamera import PiCamera
from os import system

camera = PiCamera()

for i in range(30):
    print(i)
    camera.capture('demo/image{0:04d}.jpg'.format(i))

system('ffmpeg -framerate 10 -pattern_type glob -i "demo/*.jpg" -c:v libx264 -crf 0 demo/output.mp4')

print('done')
