# server.py

from flask import Flask, render_template
from camera.camera import Camera

app = Flask(__name__)
camera = None

def start_server(camera_instance):
    global camera
    camera = camera_instance
    app.run()

@app.route('/')
def index():
    return render_template('index.html')

# Define other routes and handlers here

if __name__ == '__main__':
    start_server(Camera())  # For testing purposes
