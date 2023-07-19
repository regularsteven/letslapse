from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
import time
import numpy as np
from picamera2.sensor_format import SensorFormat



# argparser for custom params from commandline or defaults
parser = argparse.ArgumentParser(description='Optional params')
parser.add_argument('--filename', type=str, help='file name', default="image")
parser.add_argument('--format', type=str, help='image format', default="jpg")
parser.add_argument('--lensPosition', type=float, help='Macro 15 to Infinate 2.75', default=4.5)
args = parser.parse_args()



picam2 = Picamera2()
#picam2.start_preview(Preview.DRM)


def capture_and_save_image(index):
    filename = args.filename + "_" + str(index)+ "_" + str(args.lensPosition)

    preview_config = picam2.create_preview_configuration()
    picam2.configure(preview_config)
    
    picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition})
    
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
        np.save(filename +  ".npy", raw_capture)

        # associated metadata for image
        metadata = picam2.capture_metadata()
        np.save(filename +  ".meta", metadata)

        raw_format = SensorFormat(picam2.sensor_format)
        raw_format.packing = None
        np.save(filename +  ".sensor", raw_format)
        
        np.save(filename +  ".config", config)

        print("raw_format: "+ str(raw_format))
        print("metadata: "+ str(metadata))
        print("config: "+ str(config))


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


capture_and_save_image(index=0)
capture_and_save_image(index=1)
capture_and_save_image(index=2)
capture_and_save_image(index=3)
#capture_and_save_image(index=4)
#capture_and_save_image(index=5)

