from time import sleep
from picamera import PiCamera

camera = PiCamera(resolution=(1280, 720), framerate=30)
# Set ISO and meter mode to the desired value
camera.iso = 400
camera.meter_mode = 'matrix'
# Wait for the automatic gain control to settle
sleep(2)
# Now fix the values
camera.shutter_speed = camera.exposure_speed
camera.exposure_mode = 'off'
g = camera.awb_gains
camera.awb_mode = 'off'
camera.awb_gains = g
blueGains = float(g[0])
redGains = float(g[1])
print("Blue and Red Gains")
print(str(blueGains)+","+str(redGains))