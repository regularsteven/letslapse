from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
import time


# argparser for custom params from commandline or defaults
parser = argparse.ArgumentParser(description='Optional params')
parser.add_argument('--filename', type=str, help='file name', default="image")
parser.add_argument('--format', type=str, help='image format', default="jpg")
parser.add_argument('--lensPosition', type=float, help='Macro 15 to Infinate 2.75', default=2.75)
args = parser.parse_args()



picam2 = Picamera2()
picam2.start_preview(Preview.DRM)





def capture_and_save_image(index):
    filename = args.filename + "_" + str(args.lensPosition) + "_" + str(index) +  "." + args.format

    preview_config = picam2.create_preview_configuration()
    capture_config = picam2.create_still_configuration(raw={}, display=None)
    picam2.configure(preview_config)
    picam2.start()
    picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition})
    time.sleep(2)

    r = picam2.switch_mode_capture_request_and_stop(capture_config)

    if args.format == "jpg":
        r.save("main", filename)
    else:
        r.save_dng(filename)

    picam2.stop()



#create a loop to capture 10 images and save them as an image sequence with a 1 second delay between each image
for i in range(1):
    time.sleep(1)
    capture_and_save_image(i)
