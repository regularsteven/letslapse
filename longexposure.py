import os, numpy, PIL
from PIL import Image, ExifTags, ImageStat
from os import system
import time
import argparse
from datetime import datetime
import os.path
from os import path


parser = argparse.ArgumentParser()
parser.add_argument('--groupBy', help='number to group batching by with --type images or seconds')
parser.add_argument('--groupByType', help='images or seconds - group images as per --groupBy')
parser.add_argument('--makeMP4', help='images or seconds - group images as per --groupBy')
args = parser.parse_args()

# ****** EXAMPLE USE ***** # 
#execute the following in the folder that requires the conversion
#python3 /mnt/ssd/Clients/PiShots/longexposure.py --groupBy 10 --groupByType seconds --makeMP4 yes

system("rm blendedImage*")

#### Access all JPG files in directory
allfiles=os.listdir(os.getcwd())
print("allfiles")
#print(allfiles)

#imlist=[filename for filename in allfiles if  filename[-4:] in [".jpg",".JPG"]]


def getMeta ( filename ):
    img = Image.open(filename)
    exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
    imageDateTime = exif["DateTimeDigitized"]
    d = datetime.strptime(imageDateTime, "%Y:%m:%d %H:%M:%S")
    #dawnRamp = datetime.fromisoformat(d)
    return d.timestamp()
    


#['image0.jpg', 'image1.jpg', 'image2.jpg', 'image3.jpg', 'image4.jpg']

groupByType = args.groupByType #images or seconds
    #if images, this would be a simple group up by images I.e. 10 images and then merge the average pixels of all
    #if seconds, this would require analysis of all images taken betwee the range of seconds (eg 60 seconds) and for many images taken in 60 seconds, bundle up to 1, for 2 images, bundle to one

imagesToBatch = int(args.groupBy)
fullImageSet = len(allfiles)
#fullImageSet = 3
startingTimestamp = 0



def blendGroupToOne(imlist, sequenceNo) :
    #### Assuming all images are the same size, get dimensions of first image
    w,h=Image.open(imlist[0]).size
    N=len(imlist)

    #### Create a numpy array of floats to store the average (assume RGB images)
    arr=numpy.zeros((h,w,3),numpy.float)

    #### Build up average pixel intensities, casting each image as an array of floats
    for im in imlist:
        imarr=numpy.array(Image.open(im),dtype=numpy.float)
        arr=arr+imarr/N
    #### Round values in array and cast as 8-bit integer
    arr=numpy.array(numpy.round(arr),dtype=numpy.uint8)

    #### Generate, save and preview final image
    out=Image.fromarray(arr,mode="RGB")
    fileName = "blendedImage"+str(sequenceNo)+".jpg"
    print(fileName)
    out.save(fileName)
    #out.show()

if groupByType == "images" :
    print(fullImageSet)
    print(imagesToBatch)
    
    if imagesToBatch == 1:
        print("no need to process these images, as we're just rendering them as one simple playback")
    else :
        for a in range(int((fullImageSet) / imagesToBatch) -1):
            imlist=[]
            for i in range(imagesToBatch):
                #print(i)
                if a == 0:
                    imlist.append('image'+str(i)+'.jpg')
                else :
                    imlist.append('image'+str(i+(imagesToBatch*a))+'.jpg')
            print("imlist")
            print(imlist)

            blendGroupToOne(imlist, a)
else :
    print("building up lists of images within certain timeranges - seconds: " + str(imagesToBatch))
    
    timerangeGroupIndex = 0
    imlist=[]
    for a in range(int(fullImageSet)-10):
        
        filename = 'image'+str(a)+'.jpg'
        #print(filename)
        thisTimestamp = getMeta( filename )
        
        
        if a == 0 : 
            startingTimestamp = thisTimestamp


        if(thisTimestamp < (startingTimestamp + imagesToBatch)) :
            imlist.append(filename)
        else: 
            
            #print("blendGroupToOne: " + str(timerangeGroupIndex))
            print("blending the following images")
            print(imlist)
            blendGroupToOne(imlist, timerangeGroupIndex)
            timerangeGroupIndex = timerangeGroupIndex+1
            startingTimestamp = thisTimestamp
            imlist=[]
            imlist.append(filename)




if args.makeMP4 == "yes" :
    if path.isdir('blended') == True :
        print("directory already created")
    else :
        system("mkdir blended")

    inputFile = "blendedImage"
    if imagesToBatch == 1:
        inputFile = "image"
    system("ffmpeg -i "+inputFile+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 blended/a_blendedVideo_"+str(groupByType)+""+str(imagesToBatch)+".mp4")
