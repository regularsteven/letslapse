# app.py

#from camera.camera import camera
from letslapse import webserver


def main():
    # Initialize camera
    # my_camera = camera.Camera()

    # Start the web server
    webserver.start_server()

if __name__ == '__main__':
    main()
