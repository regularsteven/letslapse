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

preview_config = picam2.create_preview_configuration()

picam2.configure(preview_config)

picam2.start()

#preview_config = picam2.create_preview_configuration()
picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition})

#time.sleep(2)

if args.format == "jpg":
    filename = args.filename + "_" + str(args.lensPosition) + "." + args.format
    capture_config = picam2.create_still_configuration(display=None)
    r = picam2.switch_mode_capture_request_and_stop(capture_config)
    r.save("main", filename)
else:
    filename = args.filename + "_" + str(args.lensPosition) + "." + args.format
    capture_config = picam2.create_still_configuration(raw={}, display=None)
    
    #picam2.switch_mode_and_capture_file(capture_config, filename, name="raw")
    
    r = picam2.switch_mode_capture_request_and_stop(capture_config)
    #r.save("main", "full3.jpg")
    r.save_dng("full3.dng")




#picam2.configure(preview_config)

#picam2.start(show_preview=False)
