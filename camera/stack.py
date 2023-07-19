import numpy as np
from picamera2 import Picamera2

# Rebuild the images array from the saved .npy files
num_frames = 4
images = []
for i in range(num_frames):
    image = np.load(f"testing_{i}_4.5.npy")
    
    images.append(image)



metadata = {'SensorTimestamp': 51867530120000, 'ScalerCrop': (0, 0, 4608, 2592), 'ColourCorrectionMatrix': (1.1673871278762817, 0.21403875946998596, -0.38143041729927063, -0.4674781560897827, 1.594957947731018, -0.12748435139656067, -0.07635503262281418, -1.0225597620010376, 2.098909378051758), 'ExposureTime': 119305, 'SensorTemperature': 45.0, 'AfPauseState': 0, 'FrameDuration': 120567, 'AeLocked': False, 'AfState': 0, 'DigitalGain': 1.0077252388000488, 'AnalogueGain': 4.612612724304199, 'ColourGains': (1.2584811449050903, 3.261364698410034), 'ColourTemperature': 2673, 'Lux': 24.42319107055664, 'SensorBlackLevels': (4096, 4096, 4096, 4096), 'FocusFoM': 2895}

exposure_time = metadata["ExposureTime"]

raw_format = np.load(f"testing_0_4.5.sensor")
config = np.load(f"testing_0_4.5.config")

accumulated = images.pop(0).astype(int)
for image in images:
    accumulated += image

# point of failure two

# Fix the black level, and convert back to uint8 form for saving as a DNG.
black_level = metadata["SensorBlackLevels"][0] / 2**(16 - raw_format.bit_depth)
accumulated -= (num_frames - 1) * int(black_level)
accumulated = accumulated.clip(0, 2 ** raw_format.bit_depth - 1).astype(np.uint16)
accumulated = accumulated.view(np.uint8)
metadata["ExposureTime"] = exposure_time

picam2 = Picamera2()

picam2.helpers.save_dng(accumulated, metadata, config["raw"], "accumulated.dng")