from os import system
from time import sleep
#from pydng.core import RPICAM2DNG
from datetime import datetime
from decimal import Decimal
import argparse

#example usage:
#python3 preview.py --ss 1000 --iso 100 --awbg 3,2

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('--ss', type=str,
                    help='Shutter Speed')

parser.add_argument('--iso', type=int,
                    help='ISO')   

parser.add_argument('--awbg', type=str,
                    help='blue and green values')   
                    
args = parser.parse_args()

now = datetime.now()

current_time = now.strftime("%H_%M_%S")

 
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

exposureInput = Decimal(args.ss)
#print("Exposure INPUT Time: ")
#print(Decimal(args.ss_arg))


exposureTime = (exposureInput)

userParams = "-ISO "+str(args.iso)+" -ss "+str(exposureTime) + " -co -10"
jpegDimensions = " -w 2400 -h 1800"

whiteBalance = "" 
# awbg : blue,red
if args.awbg != "auto":
    whiteBalance = " -awb off -awbg "+args.awbg
#1.7,1.5 = ok



#print("Exposure INPUT Time: "+str(exposureInput))

outputPathAndFilename = "previews/preview_"+current_time+"_ss-"+str(exposureInput)+"_iso-"+str(args.iso)+"_awbg-"+args.awbg+".jpg"

print("/"+outputPathAndFilename)

system("raspistill --verbose -t 1 -drc high -o "+outputPathAndFilename+" "+userParams+jpegDimensions + whiteBalance)


#burst mode:
#raspistill --verbose -t 10000 -tl 1000 -o image%04d.jpg -ISO 100 -ss 0.0008 -co -10 -drc high
