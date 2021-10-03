from pydng.core import RPICAM2DNG
import os

import argparse

#usage 
#python3 /home/steven/Documents/dev/letslapse/convertToDNG.py 

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('pos_arg', type=str,
                    help='A required integer positional argument')
                    
args = parser.parse_args()

print(args.pos_arg)

def files(path):
    for file in os.listdir(path):
        if os.path.isfile(os.path.join(path, file)):
            if ".jpg" in file and "_thumb" not in file:
                print(file)
                yield os.path.join(path, file)

for file in files(args.pos_arg+"/"):
    RPICAM2DNG().convert(file)
