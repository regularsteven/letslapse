#!/usr/bin/python3
import os
instanceCount = 0
for line in os.popen("ps -f -C python3 | grep ll_streamer.py"):
    instanceCount = instanceCount + 1
    if instanceCount > 1:
        print("ll_streamer.py: Instance already running - exiting now")
        exit()
import io
import logging
import socketserver
from threading import Condition
from http import server
import threading, os, signal
from os import system
import subprocess
from subprocess import check_call, call
import sys
from urllib.parse import urlparse, parse_qs
import argparse

PORT = 8083

import ll_utils

if ll_utils.isPi() == True:
    import picamera
else:
    print("running on a non-pi")
    import cv2
    #import requests
    import numpy as np

class StreamingOutput(object):
    def __init__(self):
        self.frame = None
        self.buffer = io.BytesIO()
        self.condition = Condition()

    def write(self, buf):
        if buf.startswith(b'\xff\xd8'):
            self.buffer.truncate()
            with self.condition:
                self.frame = self.buffer.getvalue()
                self.condition.notify_all()
            self.buffer.seek(0)
        return self.buffer.write(buf)

class StreamingHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):

        if 'stream.mjpg' in self.path:
            if ll_utils.isPi() == False:
                self.send_response(200)
                self.send_header('Age', 0)
                self.send_header('Cache-Control', 'no-cache, private')
                self.send_header('Pragma', 'no-cache')
                self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=FRAME')
                self.end_headers()
                try:
                    while True:
                        #with output.condition:
                        #    output.condition.wait()
                        
                        cap = cv2.VideoCapture(1)
                        
                        ret, frame = cap.read()
                        
                        _, jpg = cv2.imencode(".jpg", frame)

                        self.wfile.write(b'--FRAME\r\n')
                        self.send_header('Content-Type', 'image/jpeg')
                        self.send_header('Content-Length', len(frame))
                        self.end_headers()
                        self.wfile.write(jpg)
                        print("streaming now")
                        self.wfile.write(b'\r\n')
                        #self.wfile.write(jpg)

                except Exception as e:
                    logging.warning(
                        'Removed streaming client %s: %s',self.client_address, str(e))
                        
            else: 
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
                        print("streaming now")
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

if ll_utils.isPi() == True:
    with picamera.PiCamera(resolution='640x480', framerate=15) as camera:
        output = StreamingOutput()
        camera.start_recording(output, format='mjpeg')
        try:
            address = ('', PORT)
            server = StreamingServer(address, StreamingHandler)
            print("Streaming.")
            server.serve_forever()

        finally:
            print("ERROR: Stream not able to run. Stream ended.")
            camera.stop_recording()
else: 
    with socketserver.TCPServer(("", PORT), StreamingHandler) as httpd:
        print("Serving at port ", PORT)
        try:
            httpd.serve_forever()
        except:
            pass


# print in the command line instead of file's console
if __name__ == '__main__':
    main()
