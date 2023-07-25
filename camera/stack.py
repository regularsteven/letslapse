import numpy as np
import sys
from picamera2 import Picamera2
import pickle
import struct
from pidng.camdefs import Picamera2Camera
from pidng.core import PICAM2DNG
import picamera2.formats as formats

 

# Build the images array from the saved .npy (RAW uint16) files

inputfile = "/home/steven/letslapse/stills" + "/" + sys.argv[1]
num_frames = int(sys.argv[2])



metadata = object()

with open(inputfile+'_0.meta', 'rb') as fp:
    metadata = pickle.load(fp)
exposure_time = metadata["ExposureTime"]


raw_config = object()
with open(inputfile+'_0.config', 'rb') as fp:
    raw_config = pickle.load(fp)

raw_format = type('', (), {})()
raw_format.bit_depth = 10




def make_array(buffer, config):
    """Make a 2d numpy array from the named stream's buffer."""
    array = buffer
    fmt = config["format"]
    w, h = config["size"]
    stride = 9216 #this is for a 16 bit image

    # Turning the 1d array into a 2d image-like array only works if the
    # image stride (which is in bytes) is a whole number of pixels. Even
    # then, if they don't match exactly you will get "padding" down the RHS.
    # Working around this requires another expensive copy of all the data.
    if formats.is_raw(fmt):
        image = array.reshape((h, stride))
    else:
        raise RuntimeError("Format " + fmt + " not supported")
    return image

def save_dng(buffer, metadata, config, filename):
    """Save a DNG RAW image of the raw stream's buffer."""
    raw = make_array(buffer, config)

    camera = Picamera2Camera(config.copy(), metadata)
    r = PICAM2DNG(camera)

    dng_compress_level = 0

    r.options(compress=dng_compress_level)
    r.convert(raw, str(filename))


# Fix the black level, and convert back to uint8 form for saving as a DNG.
print(metadata)
# Create an empty list to hold the loaded images
images = []

# Loop through the range of num_frames (e.g., 20 in this case)
# and load the corresponding numpy arrays (images) from files
for i in range(num_frames):
    # Load the image from the file in the format "inputfile_i_2.75.npy"
    # The f-string is used to insert the value of i into the filename
    image = np.load(f"{inputfile}_{i}.npy")
    
    # Append the loaded image to the 'images' list
    images.append(image)

# Take the first image from the list and assign it to the 'accumulated' variable
# The 'pop(0)' function removes the first element from the 'images' list and returns it
accumulated = images.pop(0).astype(float)

# Loop through the remaining images in the 'images' list and accumulate them into 'accumulated'
for image in images:
    # Convert the image to floating-point before adding
    image_float = image.astype(float)

    # Add the pixel values using floating-point arithmetic
    accumulated += image_float
    # accumulated += image - not this ... 


accumulated /= num_frames

# Clip the pixel values to ensure they are within the valid range of 0 to 2^(bit_depth) - 1
# '2 ** raw_format.bit_depth' calculates the maximum possible pixel value
accumulated = np.clip(accumulated, 0, 2 ** raw_format.bit_depth - 1).astype(np.uint16)

# Convert the accumulated image from uint16 to uint8 for saving as a DNG file
# The 'view' function creates a new view of the array with a different data type without copying the data
# This is done to reduce memory usage while maintaining the same pixel values
accumulated = accumulated.view(np.uint8)


save_dng(accumulated, metadata, raw_config, inputfile+"_merged.dng")
