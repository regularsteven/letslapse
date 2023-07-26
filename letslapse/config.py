import os

def this_system():
    if os.uname()[0] == "Linux":
        return "Pi"
    elif os.uname()[0] == "Darwin":
        return "MacOS"
    elif os.uname()[0] == "Windows":
        return "Windows"
    else:
        return "Unknown"


siteRoot = "/mnt/studio/"
#siteRoot = "/home/steven/letsLapse/"

#path for saving images:
storagePath = "images/"


device_storage = "/home/steven/"
nasPath = "/mnt/nas/"