from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
import time
import numpy as np
from picamera2.sensor_format import SensorFormat
import pickle

# argparser for custom params from commandline or defaults
parser = argparse.ArgumentParser(description='Optional params')
parser.add_argument('--o', type=str, help='file name', default="image")
parser.add_argument('--format', type=str, help='image format', default="jpg")
parser.add_argument('--focus', type=float, help='Macro 15, Infinate 2.75, Arm length 4.5', default=2.75) #for the lensPosition
parser.add_argument('--lensPosition', type=float, help='Macro 15, Infinate 2.75, Arm length 4.5', default=2.75) #for the lensPosition
parser.add_argument('--count', type=int, help='1 and up, 0 for no end', default=1)
args = parser.parse_args()

picam2 = Picamera2()
#picam2.start_preview(Preview.DRM)

def capture_and_save_image(index):
    print("index: " str(index))
    args.lensPosition = args.focus
    filename = args.o + "_" + str(index)

    preview_config = picam2.create_preview_configuration()
    picam2.configure(preview_config)
    
    picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition, "AnalogueGain": 0})
    
    if args.format == "jpg" or args.format == "dng":

        picam2.start()
        time.sleep(1)
        capture_config = picam2.create_still_configuration(raw={}, display=None)
        r = picam2.switch_mode_capture_request_and_stop(capture_config)
    else:
        raw_format = SensorFormat(picam2.sensor_format)
        raw_format.packing = None

        config = picam2.create_still_configuration(raw={"format": raw_format.format}, buffer_count=2)
        
        picam2.configure(config)
        picam2.set_controls({}) #"AnalogueGain": 1.0})

    if args.format == "jpg":
        r.save("main", filename +  "." + args.format)
    elif args.format == "dng":
        r.save_dng(filename +  "." + args.format)
    else:
        picam2.start()
        time.sleep(1)

        raw_capture = picam2.capture_array("raw").view(np.uint16)
        
        with open(filename+'.config', 'wb') as config_file:
            pickle.dump(config["raw"], config_file)


        np.save(filename +  ".npy", raw_capture)
        # associated metadata for image
        metadata = picam2.capture_metadata()
        with open(filename+".meta", 'wb') as metadata_file:
            pickle.dump(metadata, metadata_file)
        
        raw_format = SensorFormat(picam2.sensor_format)
        raw_format.packing = None

        with open(filename+".format", 'wb') as raw_format_file:
            pickle.dump(raw_format, raw_format_file)

    picam2.stop()


def pull_focus(startPoint, endPoint, totalSteps):
    #create a loop to capture 10 images and save them as an image sequence with a 1 second delay between each image
    for i in range(totalSteps):
        print(str(i) + " of " + str(totalSteps))
        args.lensPosition = startPoint + ((endPoint - startPoint) / float(totalSteps)) * float(i)
        args.lensPosition = round(args.lensPosition, 2)
        #print("Current point is: " + str(currentPoint))
        capture_and_save_image(i)

# pull_focus(startPoint = 5, endPoint = 10, totalSteps = 3)



def capture():
    for i in range(args.count):
        capture_and_save_image(i)

capture()
