from pydng.core import RPICAM2DNG
import os

import argparse

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('pos_arg', type=str,
                    help='A required integer positional argument')
                    
args = parser.parse_args()

print(args.pos_arg)
#preview_15_29_26_ss-1_iso-200.jpg
RPICAM2DNG().convert("/var/www/html/previews/"+args.pos_arg)