#!/usr/bin/python3

# Mostly copied from https://picamera.readthedocs.io/en/release-1.13/recipes2.html
# Run this script, then point a web browser at http:<this-ip-address>:8000
# Note: needs simplejpeg to be installed (pip3 install simplejpeg).

import io
import logging
import socketserver
from http import server
from threading import Condition

from picamera2 import Picamera2
from picamera2.encoders import JpegEncoder
from picamera2.outputs import FileOutput
from pprint import pprint

from libcamera import controls

lsize = (1280, 720)

reductionRatio = 4
fps = 10

PAGE = f"""\
<html>
<head>
<title></title>
</head>
<body>
<h1>LetsLapse Streamer Test</h1>
<img src="stream.mjpg" width="{lsize[0]}" />
</body>
</html>
"""


class StreamingOutput(io.BufferedIOBase):
    def __init__(self):
        self.frame = None
        self.condition = Condition()

    def write(self, buf):
        with self.condition:
            self.frame = buf
            self.condition.notify_all()


class StreamingHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(301)
            self.send_header('Location', '/index.html')
            self.end_headers()
        elif self.path == '/index.html':
            content = PAGE.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', len(content))
            self.end_headers()
            self.wfile.write(content)
        elif self.path == '/stream.mjpg':
            self.send_response(200)
            self.send_header('Age', 0)
            self.send_header('Cache-Control', 'no-cache, private')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=FRAME')
            self.end_headers()
            try:
                while True:
                    with output.condition:
                        output.condition.wait()
                        frame = output.frame
                    self.wfile.write(b'--FRAME\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', len(frame))
                    self.end_headers()
                    self.wfile.write(frame)
                    self.wfile.write(b'\r\n')
            except Exception as e:
                logging.warning(
                    'Removed streaming client %s: %s',
                    self.client_address, str(e))
        else:
            self.send_error(404)
            self.end_headers()


class StreamingServer(socketserver.ThreadingMixIn, server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

picam2 = Picamera2()



hqCam = True
# HQ camera has a 4x3, whereas the alternative has 16x9
if 'AfMode' in picam2.camera_controls:
    hqCam = False
    


pprint(picam2.sensor_modes)

#size = picam2.sensor_resolution

available_modes = picam2.sensor_modes
#min_bit_depth = 11
#available_modes = list(filter(lambda x: (x["bit_depth"] >= min_bit_depth), available_modes))
#available_modes.sort(key=lambda x: x["fps"], reverse=True)
#[print(i) for i in available_modes]
chosen_mode = available_modes[2]



if hqCam:
    output_resolution = (int(4056/reductionRatio), int(3040/reductionRatio))
    deviceControls = {"FrameRate": fps}
    picam2.configure(
        picam2.create_video_configuration(
            main={"size": output_resolution},
            )
    )
else:
    deviceControls = {"AfMode": controls.AfModeEnum.Continuous, "FrameRate": fps}
    picam2.configure(
        picam2.create_video_configuration(
            raw={"size": chosen_mode["size"], "format": chosen_mode["format"].format},
            #main={"size": output_resolution},
            )
    )

                 

output = StreamingOutput()
picam2.start_recording(JpegEncoder(), FileOutput(output))

#can only do this on cameras which support it 

picam2.set_controls(deviceControls)

#picam2.set_controls({"AfMode": controls.AfModeEnum.Manual, "LensPosition": 10, "AnalogueGain": 0})


try:
    address = ('', 8081)
    server = StreamingServer(address, StreamingHandler)
    server.serve_forever()

    #lens_position = picam2.capture_metadata()['LensPosition']

finally:
    picam2.stop_recording()