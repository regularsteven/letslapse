from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
import time

parser = argparse.ArgumentParser(description='Optional params')

parser.add_argument('--format', type=str, help='image format', default="jpg")
parser.add_argument('--lensPosition', type=float, help='Macro 15 to Infinate 2.75', default=2.75)
parser.add_argument('--name', type=str, help='image name', default="image")


args = parser.parse_args()

picam2 = Picamera2()
picam2.start_preview(Preview.DRM)



#preview_config = picam2.create_preview_configuration()

if args.format == "jpg":
    capture_config = picam2.create_still_configuration()
else:
    capture_config = picam2.create_still_configuration(raw={})


picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition})

#picam2.configure(preview_config)

#picam2.start(show_preview=False)
time.sleep(2)

filename = args.name + "_" + str(args.lenPosition) +  "." + args.format
picam2.switch_mode_and_capture_file(capture_config, filename, name=args.format)