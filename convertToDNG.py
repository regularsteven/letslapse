from pydng.core import RPICAM2DNG
import os

import argparse

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('pos_arg', type=str,
                    help='A required integer positional argument')
                    
args = parser.parse_args()

print(args.pos_arg)

def files(path):
    for file in os.listdir(path):
        if os.path.isfile(os.path.join(path, file)):
            if ".jpg" in file:
                yield os.path.join(path, file)

for file in files(args.pos_arg+"/"):
    RPICAM2DNG().convert(file)
