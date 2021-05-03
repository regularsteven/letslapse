import socket
from os import system
from time import sleep
import socket
#from pydng.core import RPICAM2DNG
from datetime import datetime






now = datetime.now()

current_time = now.strftime("%H_%M_%S")
print("running live preview for " + socket.gethostbyname(socket.gethostname()))

 
#sleep(2)
#d=RPICAM2DNG()

# -r = append raw file for later processing




#system("raspivid -t 0 -l -o tcp://192.168.38.76:3333 -w 1280 -h 720")
