from picamera2 import Picamera2, Preview
import time
picam2 = Picamera2()
#picam2.start_and_capture_file("filename.jpg",delay=0,show_preview=False)

camera_config = picam2.create_preview_configuration()
picam2.configure(camera_config)
picam2.start_preview(Preview.DRM)
picam2.start()
time.sleep(2)
picam2.capture_file("test2.jpg")
