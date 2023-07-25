from picamera2 import Picamera2, Preview
from libcamera import controls
import argparse
from datetime import datetime
import time
from time import sleep
import numpy as np
from picamera2.sensor_format import SensorFormat
#from picamera2.encoders import JPEGEncoder
import pickle
import os
import pprint
from os import system, path

#example use:
#python3 camera.py --o test --format raw --count 5


#path for saving images:
storagePath = "/mnt/nas/"

# argparser for custom params from commandline or defaults
parser = argparse.ArgumentParser(description='Optional params')
parser.add_argument('--o', type=str, help='file name', default="image")
parser.add_argument('--format', type=str, help='image format', default="jpg")
parser.add_argument('--focus', type=float, help='Macro 15, Infinate 2.5, Arm length 4.5', default=2.5) #for the lensPosition
parser.add_argument('--lensPosition', type=float, help='Macro 15, Infinate 2.5, Arm length 4.5', default=2.5) #for the lensPosition
parser.add_argument('--count', type=int, help='1 and up, 0 for no end', default=1)
args = parser.parse_args()


#picam2.start_preview(Preview.DRM)

def capture_and_save_image(filename):

    picam2 = Picamera2()

    print("filename: "+ str(filename))
    
    print("args: ")
    print(args)

    
    shootPath = storagePath + args.o + "/"
    
    #preview_config = picam2.create_preview_configuration()
    #picam2.configure(preview_config)
    #capture config, depending on format
    if args.format == "jpg" or args.format == "dng":
        
        picam2.start()
        picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition, "AnalogueGain": 0})
        print("args.lensPosition")
        print(args.lensPosition)
        
        time.sleep(1)
        capture_config = picam2.create_still_configuration(raw={}, display=None)
        r = picam2.switch_mode_capture_request_and_stop(capture_config)
    else:
        raw_format = SensorFormat(picam2.sensor_format)
        raw_format.packing = None

        config = picam2.create_still_configuration(raw={"format": raw_format.format}, buffer_count=2)
        
        picam2.configure(config)
        picam2.set_controls({"AnalogueGain": 0})


    #save, depending on format
    if args.format == "jpg":
        r.save("main", shootPath + filename)
        #r.save("lowres", "stills/" + "thumb"+filename)
    elif args.format == "dng":
        r.save_dng(shootPath + filename)
    else:
        picam2.start()
        picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": args.lensPosition, "AnalogueGain": 0})
        
        #time.sleep(1)
        # filename =  + filename
        raw_capture = picam2.capture_array("raw").view(np.uint16)
        
        with open(shootPath + filename+'.config', 'wb') as config_file:
            pickle.dump(config["raw"], config_file)


        #np.save(filename +  ".npy", raw_capture)
        np.savez_compressed(shootPath + filename +  ".npz", raw_capture)

        # associated metadata for image
        metadata = picam2.capture_metadata()
        with open(shootPath + filename+".meta", 'wb') as metadata_file:
            pickle.dump(metadata, metadata_file)
        
        #raw_format = SensorFormat(picam2.sensor_format)
        #raw_format.packing = None

        #with open(filename+".format", 'wb') as raw_format_file:
        #    pickle.dump(raw_format, raw_format_file)

    picam2.stop()
    picam2.close()
    






def setup_folder():
    folder = storagePath+args.o
    isExist = os.path.exists(folder)
    if not isExist:
        # Create a new directory because it does not exist
        os.makedirs(folder)
        print("The new directory is created!")


def pull_focus(startPoint, endPoint, totalSteps):
    setup_folder()
    #create a loop to capture 10 images and save them as an image sequence with a 1 second delay between each image
    for i in range(totalSteps):
        print(str(i) + " of " + str(totalSteps))
        args.lensPosition = startPoint + ((endPoint - startPoint) / float(totalSteps)) * float(i)
        args.lensPosition = round(args.lensPosition, 2)
        #print("Current point is: " + str(currentPoint))
        #filename = "/mnt/usb/" + args.o + "/" + args.o + "_" + str(i)
        filename = "pull_" + args.o + "_" + str(i) + ".jpg"
        capture_and_save_image(filename)
        print(filename + " - captured")

#pull_focus(startPoint = 2, endPoint = 4,totalSteps =10)

def capture():
    setup_folder()
    args.lensPosition = args.focus
    for i in range(args.count):
        #filename = "/mnt/usb/" + args.o + "/" + args.o + "_" + str(i)
        filename = args.o + "_" + str(i)
        capture_and_save_image(filename)
        #sleep(10)

# capture()

if __name__ == '__main__':
    #pull_focus(startPoint = 1, endPoint = 5,totalSteps = 20)  # For testing purposes
    #capture_and_save_image("sample.jpg")  # For testing purposes
    capture()  # For testing purposes

