from os import system
import requests, os, json
from time import sleep
from picamera import PiCamera




def detectAWBG():
    print("running camera to detect color temperature")
    camera = PiCamera(resolution=(1280, 720), framerate=30)
    # Set ISO and meter mode to the desired value
    camera.iso = 400
    camera.meter_mode = 'matrix'
    # Wait for the automatic gain control to settle
    sleep(1)
    # Now fix the values
    camera.shutter_speed = camera.exposure_speed
    camera.exposure_mode = 'off'
    g = camera.awb_gains
    camera.awb_mode = 'off'
    camera.awb_gains = g
    measuredGains = g
    camera.close()
    return measuredGains

#print(detectAWBG())


protocol = "http://"
letslapseDomain = "letslapse.local"
letslapseCMS = protocol+letslapseDomain

mediaEndpoint = "/wp-json/wp/v2/media/"
postsEndpoint = "/wp-json/wp/v2/posts/"
usersEndpoint = "/wp-json/wp/v2/users/"

#user credentials to come from device
username = os.getenv('API_USER') #"pizero-dev"
password = os.environ.get('API_PASSWORD') #"YZbc)WdcolGV3P0HuK6jS2sf"

username = "pizero-dev"
password = "YZbc)WdcolGV3P0HuK6jS2sf"

letslapseCMSOnline = False
userAuthenticated = False


def convert_str_bool(s):
    trues = ["true", "True", "1"]
    print(trues)
    print(s)
    if str(s) in trues:
        return True
    else: 
        return False




def logInCMS():
    return -1
    url=letslapseCMS+usersEndpoint+"me"
    print(url)

    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password) )
    if res:
        jsonResp = json.loads(res.text)["capabilities"]
        if 'subscriber' in jsonResp:
            print("registered, but not yet provisioned")
        elif 'author' in jsonResp:
            print("provisioned and ready")
        elif 'administrator' in jsonResp:
            print("admin user")
        else:
            print (json.loads(res.text)["capabilities"])
    else: 
        print(res.status_code)
        


def registerCMS():
    return -1
    url=letslapseCMS+usersEndpoint+"register"
    print(url)
    data = {
        'username':"somename",
        'email':'someemail@whatever.com',
        'password':'privateas'
        }
    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        data=json.dumps(data) )

    print(res.status_code)

    
def pingCMS(): 
    return -1
    hostname = letslapseDomain
    response = os.system("ping -c 1 " + hostname)

    #and then check the response...
    if response == 0:
        print(hostname + ' is up!')
        letslapseCMSOnline = True
    else:
        letslapseCMSOnline = False
        print(hostname + ' is down!')
    
    print("letslapseCMSOnline: " + str(letslapseCMSOnline))



def convertImagesToVideo(inputImage, outputVideo):
    system("ffmpeg -i "+inputImage+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 "+outputVideo+".mp4")





def createPost(postName):
    return -1
    url=letslapseCMS+postsEndpoint
    data = {
        'title':postName,
        'content':'[gallery]',
        'status':'private'
        }
    res = requests.post(url=url,
                        data=json.dumps(data),
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password))
    print("createPost")
    print(res.status_code)
    if res:
        letslapseCMSOnline = True
        return (json.loads(res.text)['id'])
    else:
        letslapseCMSOnline = False
        return -1


def attachPostToImage(postID, imageId):
    return -1
    url=letslapseCMS+mediaEndpoint+str(imageId)
    print(url)

    metaToUpdate=json.dumps({"post":postID})
    print(metaToUpdate)

    res = requests.post(url=url,
                        headers={ 'Content-Type': 'application/json'},
                        auth=(username, password),
                        data=(metaToUpdate))
    print(res.text)

def uploadMedia(imgPath, postID):
    return -1
    url=letslapseCMS+mediaEndpoint

    data = open(imgPath, 'rb').read()
    fileName = os.path.basename(imgPath)

    res = requests.post(url=url,
                        data=data,
                        headers={ 'Content-Type': 'image/jpg','Content-Disposition' : 'attachment; filename=%s'% fileName},
                        auth=(username, password))

    if res:
        #once the image is uploaded, we can attach to an existing post... 
        letslapseCMSOnline = True
        print("success - " + str(postID) + " " +  str(json.loads(res.text)['id']))
        attachPostToImage(postID, json.loads(res.text)['id'])
        return (json.loads(res.text)['id'])
    else:
        letslapseCMSOnline = False
        return -1
   
