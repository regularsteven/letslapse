#!/usr/bin/python3
import os
instanceCount = 0
for line in os.popen("ps -f -C python3 | grep letslapse_streamer.py"):
    instanceCount = instanceCount + 1
    if instanceCount > 1:
        print("letslapse_streamer.py: Instance already running - exiting now")
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

PORT = 8081

# Instantiate the parser
parser = argparse.ArgumentParser(description='Optional app description')

parser.add_argument('--testing', type=str,
                    help='Local development testing')

#we need to check the status of progress.txt
#if this file exists, then we are in the process of a shoot and we don't want to run anything that touches the camera



args = parser.parse_args()
import picamera

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

with picamera.PiCamera(resolution='640x480', framerate=10) as camera:
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

# print in the command line instead of file's console
if __name__ == '__main__':
    main()
