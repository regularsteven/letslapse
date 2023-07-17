from picamera2 import Picamera2, Preview
import time
picam2 = Picamera2()
picam2.start_preview(Preview.DRM)



preview_config = picam2.create_preview_configuration()
capture_config = picam2.create_still_configuration(raw={})
picam2.configure(preview_config)

picam2.start()
time.sleep(2)

picam2.switch_mode_and_capture_file(capture_config, "full.dng", name="raw")