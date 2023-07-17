# app.py

from camera.camera import camera
from web_interface import server

def main():
    # Initialize camera
    my_camera = camera.Camera()

    # Start the web server
    server.start_server(my_camera)

if __name__ == '__main__':
    main()
