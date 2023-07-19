from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
import time
import numpy as np
from picamera2.sensor_format import SensorFormat
import pickle




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

        #print("1) pre set config")
        config = picam2.create_still_configuration(raw={"format": raw_format.format}, buffer_count=2)
        
        
        #print("config:")
        #print(config)
        
        #print("config[raw]:")
        #print(config["raw"])

        #print("4) picam2.configure(config)")
        picam2.configure(config)
        picam2.set_controls({}) #"AnalogueGain": 1.0})

    if args.format == "jpg":
        r.save("main", filename +  "." + args.format)
    elif args.format == "dng":
        r.save_dng(filename +  "." + args.format)
    else:
        #print("5) start camera")
        picam2.start()
        time.sleep(1)

        #print("6) start capture")
        raw_capture = picam2.capture_array("raw").view(np.uint16)
        
        #print("2) config set, dumping to file")
        with open('raw_config', 'wb') as config_file:
            pickle.dump(config["raw"], config_file)


        #print("7) save raw_capture")
        
        np.save(filename +  ".npy", raw_capture)
        #print("9) store associated meatadata")
        # associated metadata for image
        metadata = picam2.capture_metadata()
        with open('metadata', 'wb') as metadata_file:
            pickle.dump(metadata, metadata_file)
        
        #print(picam2.sensor_format)
        raw_format = SensorFormat(picam2.sensor_format)
        #print(raw_format)
        raw_format.packing = None

        #np.save(filename +  ".sensor", raw_format)
        with open('raw_format', 'wb') as raw_format_file:
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



def shoot_raw_sequence(totalShots):
    for i in range(totalShots):
        capture_and_save_image(i)

shoot_raw_sequence(totalShots = 20)