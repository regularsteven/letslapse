from picamera2 import Picamera2, Preview
from libcamera import controls
import time
picam2 = Picamera2()


picam2.start_preview(Preview.DRM)



preview_config = picam2.create_preview_configuration()
capture_config = picam2.create_still_configuration(raw={}, display=None)

#config = picam2.still_configuration()
picam2.configure(preview_config)

picam2.start()

picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": 3.0})

time.sleep(2)

r = picam2.switch_mode_capture_request_and_stop(capture_config)
r.save("main", "full3.jpg")
r.save_dng("full3.dng")

#request = picam2.capture_request()
# This request has been taken by the application and can now be used, for example
#request.save("main", "test.jpg")
# Once done, the request must be returned.
#request.release()
