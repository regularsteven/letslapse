from pidng.core import RPICAM2DNG
import os

import argparse

#usage 
#python3 convertToDNG.py relative/folder/path/ 
#python3 convertToDNG.py timelapse_50mm/group0/

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


#hdrmerge has potential ... 
# see https://jcelaya.github.io/hdrmerge/documentation/2014/07/11/user-manual.html

#dcraw -T -6 -W -r 3.0 1.0 1.49 1.0 *.dng
# dcraw can export TIF from DNG

#convert image10.jpg image11.jpg image12.jpg image13.jpg image14.jpg image15.jpg image16.jpg image17.jpg image18.jpg image19.jpg image20.jpg -evaluate-sequence mean output.jpg

#convert image1.tiff image2.tiff image3.tiff image4.tiff image5.tiff image6.tiff image7.tiff image8.tiff image9.tiff image10.tiff image11.tiff image12.tiff image13.tiff image14.tiff  -evaluate-sequence mean output.tiff


# imagemagick can blend images - think this might be faster than my blend tool ... need to look into this
