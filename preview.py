from os import system
from time import sleep
#from pydng.core import RPICAM2DNG
from datetime import datetime

now = datetime.now()

current_time = now.strftime("%H_%M_%S")
print("/previews/preview_"+current_time+"_time.jpg")


#sleep(2)
#d=RPICAM2DNG()


system("raspistill -r -o /var/www/html/previews/preview_"+current_time+"_time.jpg")
