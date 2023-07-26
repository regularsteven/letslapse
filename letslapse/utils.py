from os import system
import requests, os, json
from time import sleep
from datetime import datetime
import json


import letslapse.camera as camera
import letslapse.config as config




def isPi():
    return False
    checkIfSystemHasARM = os.uname()[4][:3].startswith("arm")
    print("system has ARM: " + str(checkIfSystemHasARM))
    return (checkIfSystemHasARM)


if isPi():
    from picamera import PiCamera


def detectAWBG():
    print("running camera to detect color temperature")
    camera = PiCamera(resolution=(1280, 720), framerate=30)
    # Set ISO and meter mode to the desired value
    camera.iso = 400
    camera.meter_mode = 'matrix'
    # Wait for the automatic gain control to settle
    sleep(1)
    # Now fix the values
    camera.shutter_speed = camera.exposure_speed
    camera.exposure_mode = 'off'
    g = camera.awb_gains
    camera.awb_mode = 'off'
    camera.awb_gains = g
    measuredGains = g
    camera.close()
    return measuredGains

#print(detectAWBG())



def convert_str_bool(s):
    trues = ["true", "True", "1"]
    print(trues)
    print(s)
    if str(s) in trues:
        return True
    else: 
        return False




def convertImagesToVideo(inputImage, outputVideo):
    system("ffmpeg -i "+inputImage+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 "+outputVideo+".mp4")




def shootPreview(query_components) :
    global config
    
    folder = config.storagePath
    isExist = os.path.exists(folder)
    if not isExist:
        # Create a new directory because it does not exist
        os.makedirs(folder)
        print("The new directory is created!")


    mode = query_components["mode"][0]
    now = datetime.now()
    current_time = now.strftime("%H_%M_%S")
    settings = ""
    if mode == "auto": 
        filename = "img_"+current_time+"_auto.jpg"
        settings = " --mode auto"
    else : 
        ss = query_components["ss"][0]
        #iso = query_components["iso"][0]
        ag = query_components["analogueGains"][0]
        dg = query_components["digitalGains"][0]

        awbg = query_components["awbg"][0]
        raw = bool(query_components["raw"][0])
        settings = " --ss "+ss+" --ag "+ag+" --dg "+dg+" --awbg "+awbg + " --raw "+str(raw)
        filename = "img_"+current_time+"_ss-"+str(ss)+"_ag-"+str(ag)+"_dg-"+str(dg)+"_awbg-"+awbg+"_manual.jpg"


    print("start shootPreview")
    #sysCommand = "python3 ll_still.py --filename "+filename + settings

    #filename = "/mnt/usb/" + args.o + "/" + args.o + "_" + str(i)
    
    camera.capture_and_save_image(filename)
    
    # shootPreview

    #print(sysCommand)
    
    #system(sysCommand)
    
    print("end shootPreview")
    #processThread = threading.Thread(target=letslapse_streamer_thread)
    #processThread.start()
    return filename


