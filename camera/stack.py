import numpy as np
import sys
from picamera2 import Picamera2
import pickle
import struct
from pidng.camdefs import Picamera2Camera
from pidng.core import PICAM2DNG
import picamera2.formats as formats

 

# Build the images array from the saved .npy (RAW uint16) files
num_frames = 10
images = []
for i in range(num_frames):
    image = np.load(f"working_{i}_4.5.npy")
    images.append(image)

metadata = object()

with open('metadata', 'rb') as fp:
    metadata = pickle.load(fp)
exposure_time = metadata["ExposureTime"]


raw_config = object()
with open('raw_config', 'rb') as fp:
    raw_config = pickle.load(fp)

raw_format = type('', (), {})()
raw_format.bit_depth = 10


accumulated = images.pop(0).astype(int)
for image in images:
    accumulated += image


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
black_level = metadata["SensorBlackLevels"][0] / 2**(16  - raw_format.bit_depth)
accumulated -= (num_frames - 1) * int(black_level)
accumulated = accumulated.clip(0, 2 ** raw_format.bit_depth - 1).astype(np.uint16)
accumulated = accumulated.view(np.uint8)
metadata["ExposureTime"] = exposure_time


save_dng(accumulated, metadata, raw_config, "accumulated.dng")

