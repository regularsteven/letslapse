from os import system
from time import sleep
#from pydng.core import RPICAM2DNG
from datetime import datetime

now = datetime.now()

current_time = now.strftime("%H_%M_%S")
print("Current Time =", current_time)


#sleep(2)
d=RPICAM2DNG()


system("raspistill -r -o /var/www/html/site/previews/"+current_time+"_{0:04d}.jpg".format(i))