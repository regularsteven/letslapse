#!/usr/bin/python3
import os
instanceCount = 0
for line in os.popen("ps -f -C python3 | grep letslapse_server.py"):
    instanceCount = instanceCount + 1
    if instanceCount > 1:
        print("letslapse_server.py: Instance already running - exiting now")
        exit()

from time import sleep
import subprocess
import io
import socketserver
from datetime import datetime
from threading import Condition
from http import server
import threading, signal
from os import system, path
import json
from subprocess import check_call, call
import sys
from urllib.parse import urlparse, parse_qs
import argparse

import sqlite3

#my own custom utilities extracted for simpler structure 
import ll_browser
import ll_utils



# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('--port', type=int,
                    help='specifiy port to run, 80 requires sudo', default = 80)
                    
args = parser.parse_args()

PORT = args.port

localDev = False
if ll_utils.isPi() == False:
    localDev = True

print(ll_utils.isPi)

if localDev:
    print("Running in testing mode for localhost development")
    siteRoot = os.getcwd()
else: 
    siteRoot = "/home/pi/letslapse"
    

os.chdir(siteRoot+"/")





#start up the streamer, this will run as a child on a different port
#system("python3 ll_streamer.py")

letslapse_streamerPath = siteRoot+"/ll_streamer.py"    #CHANGE PATH TO LOCATION OF ll_streamer.py



def letslapse_streamer_thread():
    call(["python3", letslapse_streamerPath])


def checkStreamerIsRunning():
    instanceCount = 0
    for line in os.popen("ps -f -C python3 | grep ll_streamer.py"):
        print(line)
        instanceCount = instanceCount + 1
        if instanceCount > 0:
            return True
        else: 
            return False

def check_kill_process(pstring):
    for line in os.popen("ps ax | grep " + pstring + " | grep -v grep"):
        fields = line.split()
        pid = fields[0]
        os.kill(int(pid), signal.SIGKILL)


def startTimelapse(shootName, includeRaw, underexposeNights, ultraBasic, disableAWBG, width, startingGains, useThumbnail, lockExposure, shutterSpeed, analogueGains, digitalGains, delayBetweenShots, exitAfter) :
    shellStr = 'nohup python3 ll_timelapse.py --shootName '+shootName

    if startingGains is not False:
        shellStr += " --startingGains " + startingGains

    if bool(includeRaw):
        shellStr = shellStr + ' --raw'
    if bool(ultraBasic):
        shellStr = shellStr + ' --ultraBasic'
    if bool(disableAWBG):
        shellStr = shellStr + ' --disableAWBG'
    if bool(underexposeNights):
        shellStr = shellStr + ' --underexposeNights'
    if bool(useThumbnail):
        shellStr = shellStr + ' --useThumbnail'
    if bool(lockExposure):
        shellStr = shellStr + ' --lockExposure'

    shellStr = shellStr + " --startingSS " +  str(shutterSpeed)
    shellStr = shellStr + " --analogueGains " +  str(analogueGains)
    shellStr = shellStr + " --digitalGains " +  str(digitalGains)
    if int(delayBetweenShots) > 0:
        shellStr = shellStr + " --delayBetweenShots " +  str(delayBetweenShots)
    if int(exitAfter) > 0:
        shellStr = shellStr + " --exitAfter " +  str(exitAfter)

    
    shellStr = shellStr + " --width "+ str(width)
    shellStr = shellStr + ' &'
    print(shellStr)
    system(shellStr)
    return "startTimelapse function complete"

def shootPreview(query_components) :
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
    sysCommand = "python3 ll_still.py --filename "+filename + settings
    print(sysCommand)
    system(sysCommand)
    print("end shootPreview")
    #processThread = threading.Thread(target=letslapse_streamer_thread)
    #processThread.start()
    return filename






class StreamingOutput(object):
    def __init__(self):
        self.frame = None
        self.buffer = io.BytesIO()
        self.condition = Condition()

    def write(self, buf):
        if buf.startswith(b'\xff\xd8'):
            self.buffer.truncate()
            with self.condition:
                self.frame = self.buffer.getvalue()
                self.condition.notify_all()
            self.buffer.seek(0)
        return self.buffer.write(buf)

class MyHttpRequestHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(urlparse(self.path))
        query_components = parse_qs(urlparse(self.path).query)
        if 'action' in query_components:
            # Sending an '200 OK' response
            self.send_response(200)
            # Setting the header
            self.send_header("Content-type", "application/json")
            actionVal = query_components["action"][0]

            # Some custom HTML code, possibly generated by another function
            jsonResp = '{'
            jsonResp += '"completedAction":"'+actionVal+'"'
            
            if actionVal == "timelapse" :
                check_kill_process("ll_streamer.py")
                #check to see if this timelapse project is already in place - don't make a new one, if so
                shootName = query_components["shootName"][0]

                if "includeRaw" in query_components:
                    includeRaw = query_components["includeRaw"][0]
                    if includeRaw == "false":
                        includeRaw = False
                else:
                    includeRaw = False
                
                if "underexposeNights" in query_components:
                    underexposeNights = query_components["underexposeNights"][0]
                else:
                    underexposeNights = False
                
                if "lockExposure" in query_components:
                    lockExposure = query_components["lockExposure"][0]
                else:
                    lockExposure = False
                
                if "shutterSpeed" in query_components:
                    shutterSpeed = query_components["shutterSpeed"][0]
                else:
                    shutterSpeed = 8000
                
                if "analogueGains" in query_components:
                    analogueGains = query_components["analogueGains"][0]
                else:
                    analogueGains = 1
                
                if "digitalGains" in query_components:
                    digitalGains = query_components["digitalGains"][0]
                else:
                    digitalGains = 1

                if "delayBetweenShots" in query_components:
                    delayBetweenShots = query_components["delayBetweenShots"][0]
                else:
                    delayBetweenShots = 0

                if "exitAfter" in query_components:
                    exitAfter = query_components["exitAfter"][0]
                else:
                    exitAfter = 0
                
                
                if "ultraBasic" in query_components:
                    ultraBasic = query_components["ultraBasic"][0]
                    if ultraBasic == "false":
                        ultraBasic = False
                else:
                    ultraBasic = False
                
                if "disableAWBG" in query_components:
                    disableAWBG = query_components["disableAWBG"][0]
                else:
                    disableAWBG = False
                
                if "width" in query_components:
                    width = query_components["width"][0]
                else:
                    width = 4096
                
                if "startingGains" in query_components:
                    startingGains = query_components["startingGains"][0]
                else:
                    startingGains = False
                
                if "useThumbnail" in query_components:
                    useThumbnail = query_components["useThumbnail"][0]
                else:
                    useThumbnail = False
                
                
                jsonResp += ',"shootName":"'+shootName+'"'
                if path.isfile("progress.txt") == True:
                    #in an early version, this file was created as a flat txt file, but since migrated as a sqlite file - as such, a request for this will just get the JSON and fake the text file
                    jsonResp += ',"error":false'
                    
                    jsonResp += ',"message":"resuming"'
                    #must be continuing the shoot
                    startTimelapse(shootName, includeRaw, underexposeNights, ultraBasic, disableAWBG, width, startingGains, useThumbnail)

                elif path.isdir("timelapse_"+shootName) == True :
                    print("project with the same name already in use")
                    jsonResp += ',"error":true'
                    jsonResp += ',"message":"used"'
                else: 
                    #this instance is a new shoot
                    jsonResp += ',"error":false'
                    jsonResp += ',"message":"starting"'
                    startTimelapse(shootName, includeRaw, underexposeNights, ultraBasic, disableAWBG, width, startingGains, useThumbnail, lockExposure, shutterSpeed, analogueGains, digitalGains, delayBetweenShots, exitAfter)
                sleep(3) #gives time for the timelapse to start
                
            elif actionVal == "preview" :
                jsonResp += ',"filename":"'+shootPreview(query_components)+'"'
            elif actionVal == "killtimelapse" :
                #?action=killtimelapse&pauseOrKill=kill
                check_kill_process("ll_timelapse.py")
                check_kill_process("raspistill")
                if query_components["pauseOrKill"][0] == "kill":
                    #update DB where the endTime value gets set
                    #system("rm progress.txt")
                    ll_utils.killTimelapseDB()
            elif actionVal == "killstreamer" :
                check_kill_process("ll_streamer.py")
            elif actionVal == "startstreamer" :
                processThread = threading.Thread(target=letslapse_streamer_thread)
                processThread.start()
                sleep(5) #ideally this would wait for a callback, but this allows the camera to start
                isStreamerRunning = checkStreamerIsRunning()
                print("isStreamerRunning - TEST 1")
                print(isStreamerRunning)
                checkStreamerIsRunningCount = 0
                
                while isStreamerRunning == False :
                    sleep(4)
                    isStreamerRunning = checkStreamerIsRunning()
                    checkStreamerIsRunningCount = checkStreamerIsRunningCount+1
                    print(isStreamerRunning)
                    print("checkStreamerIsRunningCount" + str(checkStreamerIsRunningCount))
                
            elif actionVal == "getAWBG" :
                measuredGains = ll_utils.detectAWBG()
                jsonResp += ',"awbg":"'+ str(float(measuredGains[0])) +','+str(float(measuredGains[1]))+'"'
            elif actionVal == "uptime" :
                uptime = subprocess.check_output("echo $(awk '{print $1}' /proc/uptime)", shell=True)
                hostname = os.uname()[1]
                print(float(uptime))
                jsonResp += ',"seconds":"'+str(float(uptime))+'"'
                jsonResp += ',"hostname":"'+str(hostname)+'"'
            elif actionVal == "updatecode" :
                myhost = os.uname()[1]
                jsonResp += ',"hostname":"'+myhost+'"'
                updatecode = "git --git-dir=/home/pi/letslapse/.git pull"
                if(myhost == "gs66"):
                    updatecode = "git --git-dir="+siteRoot+"/.git pull"
                updateCodeResp = subprocess.check_output(updatecode, shell=True).strip()
                #updateCodeResp.split()
                jsonResp += ',"updateCodeResp":'+str(json.dumps(updateCodeResp.decode('utf-8')))
                #print(updatecode)
            elif actionVal == "blend" :
                jsonResp += ',"processing":"'+str(query_components["shootName"][0])+'"'
                jsonResp += ',"speed":"'+str(query_components["processingSpeed"][0])+'"'
                
                strToFire = "nohup ./blend.sh "+ str(query_components["processingSpeed"][0]) + " " + str(query_components["shootName"][0]) + " &"
                print(strToFire)
                system(strToFire)

            elif actionVal == "listshoots":
                #for display of projects and still shots
                print("tbc")
                folderLen = (len(next(os.walk('.'))[1]))
            
            elif actionVal == "getStills":
                
                jsonResp += ',"stills":'+str( json.dumps( ll_browser.getStills() ) )
                #print(browser.getShoots("0.jpg"))
            
            elif actionVal == "getVideos":
                
                jsonResp += ',"videos":'+str( json.dumps( ll_browser.getVideos() ) )
                #print(browser.getShoots("0.jpg"))
            
            
            elif actionVal == "getShoots":
                
                jsonResp += ',"gallery":'+str( json.dumps( ll_browser.getShoots("00.jpg") ) )
                #print(browser.getShoots("0.jpg"))


            elif actionVal == "quit" :
                exit()

            jsonResp += '}'
            print(actionVal)
             # Whenever using 'send_header', you also have to call 'end_headers'
            self.end_headers()
            # Writing the HTML contents with UTF-8
            self.wfile.write(bytes(jsonResp, "utf8"))

            if actionVal == "exit" :
                check_kill_process("ll_timelapse.py")
                check_kill_process("ll_streamer.py")
                exit()
            if actionVal == "shutdown" :
                check_kill_process("ll_timelapse.py")
                check_kill_process("ll_streamer.py")
                system("sudo shutdown now")
            elif actionVal == "reset" :
                check_kill_process("ll_timelapse.py")
                check_kill_process("ll_streamer.py")
                system("sudo reboot now")
            
            return
        elif self.path == '/':
            self.send_response(301)
            self.send_header('Location', '/index.html')
            self.end_headers()
        
        else :

            #if an image is requested that doesn't exist, it's probably a thumbnail request - in this event, extract it from the image and save it
            if self.path.endswith('_thumb.jpg'):
                if path.isfile(siteRoot+self.path) == False:
                    print("Extract the thum - it's not available. Temp function, should kill this")
                    exifCommand = "exiftool -b -ThumbnailImage "+siteRoot+self.path.replace("_thumb", "")+" > "+siteRoot+self.path
                    
                    exifProcess = subprocess.check_output(exifCommand, shell=True)
                
            if self.path == "/progress.txt":
                #progress.txt was formally a static file, but now is dynamically generated
                jsonResp = ll_utils.createProgressTxtFromDB()
                
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                
                self.end_headers()
                self.wfile.write(bytes(jsonResp, "utf8"))
                    #with open(siteRoot+self.path, 'rb') as file: 
                    #    self.wfile.write(file.read())

            else:
                print("General FILE serving")
                self.send_response(200)
                if self.path.endswith('.svg'):
                    self.send_header('Content-Type', 'image/svg+xml')
                elif self.path.endswith('.css'):
                    self.send_header('Content-Type', 'text/css')
                elif self.path.endswith('.js'):
                    self.send_header('Content-Type', 'application/javascript')
                elif self.path.endswith('.jpg'):
                    self.send_header('Content-Type', 'image/jpeg')
                elif self.path.endswith('.mp4'):
                    self.send_header('Content-Disposition', 'attachment; filename="'+os.path.basename(self.path)+'"')
                    self.send_header('Content-Type', 'video/mp4')
#                    self.send_header('Content-Length', len(self.path))
                else:
                    self.send_header('Content-Type', 'text/html')

                
                self.end_headers()
                
                with open(siteRoot+self.path, 'rb') as file: 
                    self.wfile.write(file.read())
            
                
            #self.send_response(200)
            #self.send_header('Content-Type', 'text/html')
            #return http.server.SimpleHTTPRequestHandler.do_GET(self)

        #



#on strartup, if progress.txt is in place, then a boot has happened and the shoot should restart
#if path.isfile("progress.txt") == True:
#    print("System restarted - progress.txt indicated shoot in progress")
#    system("nohup python3 ll_timelapse.py &")


ll_utils.startCreateDB()

# Create an object of the above class
handler_object = MyHttpRequestHandler

my_server = socketserver.TCPServer(("", PORT), handler_object)
print("my_server running on PORT" + str(PORT))
# Star the server
my_server.serve_forever()


