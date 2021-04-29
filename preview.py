from os import system
from time import sleep
#from pydng.core import RPICAM2DNG
from datetime import datetime

import argparse

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')


parser.add_argument('pos_arg', type=str,
                    help='A required integer positional argument')

parser.add_argument('iso_arg', type=int,
                    help='A required integer positional argument')   
                    
args = parser.parse_args()


now = datetime.now()

current_time = now.strftime("%H_%M_%S")
print("/previews/preview_"+current_time+"_time.jpg")

 
#sleep(2)
#d=RPICAM2DNG()

# -r = append raw file for later processing
# ISO - Set capture ISO (100 - 800)
# -ss 6000000 = shutter speed 6 seconds, 200000000 (i.e. 200s)
# --awb = off
# --hflip,    -hf     Set horizontal flip
# --vflip,    -vf     Set vertical flip
# --rotation, -rot        Set image rotation ( 0, 90, 180, and 270)
# --awbgains, -awbg     e.g. -awbg 1.5,1.2 Sets blue and red gains (as floating point numbers) to be applied when -awb off is set e.g. -awbg 1.5,1.2
# -ex = explosure
# -ev -10 to +10

#print(args.pos_arg)

expsureInput = int(float(args.pos_arg))

exposureTime = expsureInput * 1000000


system("raspistill -r -t 1 -o /var/www/html/previews/preview_"+current_time+"_time.jpg -ISO "+str(args.iso_arg)+" -ex off -ss "+str(exposureTime)+" -w 800 -h 600")
