import os, numpy, PIL
import re
from PIL import Image, ExifTags, ImageStat
import piexif
from os import system
import time
import argparse
from datetime import datetime
import os.path
from os import path





# ****** EXAMPLE USE ***** # 
#execute the following in the folder that requires the conversion

# *************** TEST FOLDER TO ENSURE WERE READY **********************
#python3 /home/steven/Documents/dev/pitime/blend.py --test full OR --test basic
  # this will evaluate the folder to check all images are in place in basic (which also happens in the actual blend scripts)
  # but will also check the meta-data of each image in FULL test to report the biggest gap between photos
  # this is useful for overnight shoots where the compression of time is required for smooth playback

# *************** Create image sequence based on images being GROUPED BY TIME **********************
#python3 /home/steven/Documents/dev/pitime/blend.py --groupBy 45 --groupByType seconds --makeMP4 yes

# *************** Create image sequence based on images being GROUPED BY IMAGE NUMBER **********************
#python3 /home/steven/Documents/dev/pitime/blend.py --groupBy 10 --groupByType images --makeMP4 yes

#windows - run from directory in with images
#py -3 E:\Clients\pitime\longexposure.py --groupBy 60 --groupByType seconds --makeMP4 no


#standard way to run this would be put all requred images inside a folder, then run:
# python3 /home/steven/Documents/dev/pitime/blend.py --test full
# from here, get the number - say it's 62 seconds. Then merge them all based on this timeframe
# python3 /home/steven/Documents/dev/pitime/blend.py --groupBy 62 --groupByType seconds --makeMP4 yes



parser = argparse.ArgumentParser()
parser.add_argument('--groupBy', help='number to group batching by with --type images or seconds')
parser.add_argument('--groupByType', help='images or seconds - group images as per --groupBy')
parser.add_argument('--makeMP4', help='images or seconds - group images as per --groupBy')

parser.add_argument('--test', help='tests the folder satructure to ensure all images are in place, returns the largest gap between two images')

args = parser.parse_args()



cwd = os.getcwd()
thisDir = cwd.split("/")[len(cwd.split("/"))-1]
thisDirLen = len(thisDir)

#check to see the number of folders inside this working directory - this can include blended output folders, which we want to exclude
#from our total file length number below
folderCount = (len(next(os.walk('.'))[1]))


thisFolderIndex = False
if thisDir[thisDirLen-1].isnumeric() :
    thisFolderIndex = int(thisDir[thisDirLen-1])

if thisDir[thisDirLen-2].isnumeric() :
    thisFolderIndex = int(thisDir[thisDirLen-2] + thisDir[thisDirLen-1])


#this will allow for the first file in any folder grouped by 1000, as per capture
#thisFolderIndex = re.findall(r'\d+', cwd)[1]

print("thisFolderIndex: "+ str(thisFolderIndex))


#### Access all JPG files in directory
allfiles=os.listdir(os.getcwd())


fullImageSet = len(allfiles)
startingTimestamp = 0







def getMeta ( filename ):
    img = Image.open(filename)
    exif = { ExifTags.TAGS[k]: v for k, v in img._getexif().items() if k in ExifTags.TAGS }
    imageDateTime = exif["DateTimeDigitized"]
    d = datetime.strptime(imageDateTime, "%Y:%m:%d %H:%M:%S")
    #dawnRamp = datetime.fromisoformat(d)
    return d.timestamp()
    



def testFiles(testType) :
    print("TESTING STRUCTURE")

    #check that all expected files are in place
    #print("Checking to see if all expected images are here - testing for " + str(fullImageSet))
    #print("Checking meta data to find the biggest gap between photos")
    foundMissingFiles = False
    biggestGapBetweenPhotos = 0
    lastPhotoTimestamp = 0
    for a in range(int(fullImageSet)-folderCount): #-1 is based on the blended folder being in the folder - we want to exclude this
        if thisFolderIndex == False :
            filename = 'image'+str(a)+'.jpg'
        if thisFolderIndex != False :
            filename = 'image'+str(int(thisFolderIndex)*1000+a)+'.jpg'

        if path.isfile(filename) == False:
            foundMissingFiles = True 
            print(filename + " DOES NOT EXIST")
        #option to check all files in folder and find the greatest gap between them
        #when shooting from day to night, the darkest of shots, this should be 59 seconds
        #this isn't required, but could become useful if we need to merge all and maintain time-based even play back that matches the slowest / biggest shots 
        else : 
            if testType == "full" :
                thisPhotoTimestamp = getMeta ( filename )
                if a<1 :
                    lastPhotoTimestamp = thisPhotoTimestamp
                else:
                    
                    gapBetweenThisAndLastPhoto = thisPhotoTimestamp - lastPhotoTimestamp
                    if gapBetweenThisAndLastPhoto > biggestGapBetweenPhotos :
                        biggestGapBetweenPhotos = gapBetweenThisAndLastPhoto
                        print("In Progress - new big gap between images found: " + str(biggestGapBetweenPhotos))
                        
                    
                    lastPhotoTimestamp = thisPhotoTimestamp
    

    if testType == "full" :
        print("Biggest gap between images found: " + str(biggestGapBetweenPhotos))
    
    print("number of FOLDERS: " + str(folderCount) )
    print("number of FILES: " + str(int(fullImageSet)-folderCount) )
    print("Are any files missing: " + str(foundMissingFiles))
    return foundMissingFiles

if args.test == "basic" or args.test == "full" : 
    testFiles(args.test)
    exit()




groupByType = args.groupByType #images or seconds
    #if images, this would be a simple group up by images I.e. 10 images and then merge the average pixels of all
    #if seconds, this would require analysis of all images taken betwee the range of seconds (eg 60 seconds) and for many images taken in 60 seconds, bundle up to 1, for 2 images, bundle to one

groupBy = args.groupBy

imagesToBatch = int(groupBy)



if path.isdir("blended"+str(groupBy)+"_"+str(groupByType)) == True :
    print("directory already created")
else :
    system("mkdir blended"+str(groupBy)+"_"+str(groupByType))

system("rm blended"+str(groupBy)+"_"+str(groupByType)+"/image*")
#system("rm image*")




    



def blendGroupToOne(imlist, sequenceNo) :
    #### Assuming all images are the same size, get dimensions of first image
    w,h=Image.open(imlist[0]).size
    N=len(imlist)

    #### Create a numpy array of floats to store the average (assume RGB images)
    arr=numpy.zeros((h,w,3),numpy.float)

    # load exif data from the first image parsed in - we'll use this to put in the output image
    im = Image.open( imlist[0])
    exif_dict = piexif.load(im.info["exif"])
    exif_bytes = piexif.dump(exif_dict)

    #### Build up average pixel intensities, casting each image as an array of floats
    for im in imlist:
        thisImg = Image.open(im)
        
        print(im)
        imarr=numpy.array(thisImg,dtype=numpy.float)
        arr=arr+imarr/N
    #### Round values in array and cast as 8-bit integer
    arr=numpy.array(numpy.round(arr),dtype=numpy.uint8)

    #### Generate, save and preview final image
    out=Image.fromarray(arr,mode="RGB")
    fileName = "blended"+str(groupBy)+"_"+str(groupByType)+"/image"+str(sequenceNo)+".jpg"
    print(fileName)
    out.save(fileName, exif=exif_bytes, quality=100, subsampling=0)
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
    

    foundMissingFiles = testFiles("basic")
    
    if foundMissingFiles == True :
        print("based on missing files, aborting process")
        exit()

    
    timerangeGroupIndex = 0
    imlist=[]
    for a in range(int(fullImageSet)-folderCount): #-1 is based on the blended folder being in the folder - we want to exclude this
        if thisFolderIndex == False :
            filename = 'image'+str(a)+'.jpg'
        if thisFolderIndex != False :
            filename = 'image'+str(int(thisFolderIndex)*1000+a)+'.jpg'
        print(filename)
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
    inputFile = "blended"+str(groupBy)+"_"+str(groupByType)+"/image"
    if imagesToBatch == 1:
        inputFile = "image"
    folderStrOutput = ""
    if thisFolderIndex != False :
        folderStrOutput = "_"+str(thisFolderIndex)
    system("ffmpeg -i "+inputFile+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 ../"+thisDir+"_blendedVideo"+folderStrOutput+"_"+str(groupByType)+""+str(imagesToBatch)+".mp4")
    #fmpeg -i image%d.jpg -b:v 500000k -vcodec mpeg4 -r 25 ../../70_auto_southcliff_90seconds.mp4
