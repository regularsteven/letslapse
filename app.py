# app.py


#from camera.camera import camera
from letslapse import config

from letslapse import webserver
from letslapse import db


print("LetsLapse running on " + config.this_system())

def main():
    # Initialize camera
    # my_camera = camera.Camera()
    # create the the database if required
    db.startCreateDB()
    # Start the web server
    webserver.start_server()

if __name__ == '__main__':
    main()
