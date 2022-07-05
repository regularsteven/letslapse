import os
#import numpy
import PIL
import re
#import cv2 as cv
from PIL import Image, ExifTags, ImageStat
#import piexif
from os import system
import time
import argparse
from datetime import datetime
import os.path
from os import path


import ll_utils




# ****** EXAMPLE USE ***** # 
#execute the following in the folder that requires the conversion


#CONVERT IMAGE SEQUENCE:

#need to run command from folder with image sequence

# *************** TEST FOLDER TO ENSURE WERE READY **********************
#python3 /home/steven/Documents/dev/letslapse/blend.py --test full OR --test basic
  # this will evaluate the folder to check all images are in place in basic (which also happens in the actual blend scripts)
  # but will also check the meta-data of each image in FULL test to report the biggest gap between photos
  # this is useful for overnight shoots where the compression of time is required for smooth playback

# *************** Create image sequence based on images being GROUPED BY TIME **********************
#python3 /home/steven/Documents/dev/letslapse/blend.py --groupBy 45 --groupByType seconds --makeMP4 yes

# *************** Create image sequence based on images being GROUPED BY IMAGE NUMBER **********************
#python3 /home/steven/Documents/dev/letslapse/blend.py --groupBy 30 --groupByType images --makeMP4 yes

#windows - run from directory in with images
#py -3 E:\Clients\letslapse\longexposure.py --groupBy 30 --groupByType seconds --makeMP4 no


#standard way to run this would be put all requred images inside a folder, then run:
# python3 /home/steven/Documents/dev/letslapse/blend.py --test full
# from here, get the number - say it's 62 seconds. Then merge them all based on this timeframe
# python3 /home/steven/Documents/dev/letslapse/blend.py --groupBy 62 --groupByType seconds --makeMP4 yes


# *********************************************************************************
# *********************************************************************************
# *********************************************************************************
                    #CONVERT VIDEO TO IMAGE SEQUENCE

# run command from project home, eg. cd ~/Documents/dev/letslapse/ OR from a specific folder ()
# 1 python3 blend.py --video videos/castle-long.mp4 
# 2 python3 blend.py --video videos/castle-long.mp4 --blendingMethod easing
# 3 python3 ~/Documents/dev/letslapse/blend.py --groupBy 30 --video filename.mp4


                    #CONVERT VIDEO TO varied playback
# python3 ~/Documents/dev/letslapse/blend.py --groupBy 50,2000-2200@1,5500-5900@2 --video tram_low.mp4
# python3 ~/Documents/dev/letslapse/blend.py --groupBy 50 --blendingMethod 2000-2200@1,5500-5900@2 --video rain_low.mp4


parser = argparse.ArgumentParser()
parser.add_argument('--video', help='specify video to convert to images then blend to image')
parser.add_argument('--blendingMethod', help='defaults as "regular", set value to make "easing"', default="regular")
parser.add_argument('--groupBy', help='number to group batching by with --type images or seconds', default="30")
parser.add_argument('--groupByType', help='images or seconds - group images as per --groupBy', default="seconds")
parser.add_argument('--makeMP4', help='images or seconds - group images as per --groupBy', default="yes")
parser.add_argument('--imagePrefix', help='specify and image name other than image', default="image")

parser.add_argument('--customGrouping', help='range of frames @ FPS')

parser.add_argument('--test', help='tests the folder satructure to ensure all images are in place, returns the largest gap between two images')

args = parser.parse_args()

imagePrefix = args.imagePrefix




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
if thisFolderIndex:
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
            if path.isfile(imagePrefix+str(a)+'.jpg') == True:
                filename = imagePrefix+str(a)+'.jpg'
        if thisFolderIndex != False :
            filename = imagePrefix+str(int(thisFolderIndex)*1000+a)+'.jpg'

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
                        print("In Progress - new big gap between images found: " + str(biggestGapBetweenPhotos) + " - from " + str(filename))
                        
                    
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




def blendGroupToOne(imlist, sequenceNo, migrateExif, outputFolder) :
    start = time.time()
    
    print("blendGroupToOne(imlist, sequenceNo: "+str(sequenceNo)+", migrateExif: "+str(migrateExif)+", outputFolder:"+outputFolder+")")
    print(imlist)
    blendingTool = "numpy"
    blendingTool = "imagemagick"

    # load exif data from the first image parsed in - we'll use this to put in the output image
    im = Image.open( imlist[0])
    print("first image: "+ imlist[0])

    
    fileName = os.getcwd()+"/"+outputFolder+"/image"+str(sequenceNo)+".jpg"
    
    #print("fileName: "+fileName)

    if migrateExif == True:
        exif_dict = piexif.load(im.info["exif"])
        exif_bytes = piexif.dump(exif_dict)

        exif = { ExifTags.TAGS[k]: v for k, v in im._getexif().items() if k in ExifTags.TAGS }
        #print((exif["ShutterSpeedValue"]))

    if blendingTool == "imagemagick":
        listOfFiles = ""
        for im in imlist:
            listOfFiles += im +" "
        print("convert "+ listOfFiles)
        system("convert " +listOfFiles+ " -evaluate-sequence mean "+fileName)
    
    #blendingTool = "numpy"
    fileName = os.getcwd()+"/"+outputFolder+"/image"+str(sequenceNo)+"_"+blendingTool+".jpg"
    if blendingTool == "numpy":

        # ref to https://stackoverflow.com/questions/17291455/how-to-get-an-average-picture-from-100-pictures-using-pil 
        #if blendAction = "preprocess" #this is the first step, to put all the blending jobs into a text file
        # if blendAction = "process" #this is second, go through the text file and blend the actual images

        #### Assuming all images are the same size, get dimensions of first image
        w,h=Image.open(imlist[0]).size
        N=len(imlist)

        #### Create a numpy array of floats to store the average (assume RGB images)
        arr=numpy.zeros((h,w,3),numpy.float16)

        
        #exit()
        

        #print("Build up average pixel intensities, casting each image as an array of floats")
        for im in imlist:
            substart = time.time()
            thisImg = Image.open(im)
            
            print(im)
            imarr=numpy.array(thisImg,dtype=numpy.float16)
            arr=arr+imarr/N
            subend = time.time()
            #print ('time for blendGroupToOne - mix image ' + str(subend - substart) )
        #print("Round values in array and cast as 8-bit integer")
        arr=numpy.array(numpy.round(arr),dtype=numpy.uint8)

        #print("Generate, save and preview final image")
        out=Image.fromarray(arr,mode="RGB")
        
        

        if migrateExif == True:
            out.save(fileName, exif=exif_bytes, quality=90, subsampling=0)
        else: 
            out.save(fileName)
        #out.show()
    end = time.time()
    print ('time for blendGroupToOne ' + str(end - start) )

    
    

def blendByImages(imagesToBlendToOne, fullImageSet, migrateExif): 

    

    print("imagesToBlendToOne: "+ str(imagesToBlendToOne))

    print("fullImageSet:")
    print(fullImageSet)
    
    print(os.getcwd())
    
    if imagesToBlendToOne == 1:
        print("no need to process these images, as we're just rendering them as one simple playback")
    
    else :
        for a in range(int((fullImageSet) / (imagesToBlendToOne+1)) ):
            #a = (a + 2204 + 1) #if there's a prevoius session run, and images already processed, this can make it start with an offset (just use the number of images created as '10')
            imlist = []
            for i in range(imagesToBlendToOne+1):
                #print(i)
                if a == 0:
                    #in some instances, images start at index 1 - if so, don't add it.
                    if path.isfile(imagePrefix+str(i)+'.jpg') == True:
                        imlist.append(imagePrefix+str(i)+'.jpg')
                else :
                    imlist.append(imagePrefix+str(i+(imagesToBlendToOne*a))+'.jpg')
            blendingOutput = imlist[0]
            if len(imlist) > 0:
                blendingOutput = blendingOutput+ " to " + imlist[len(imlist)-1]
            print("Blending " + blendingOutput)
            #print(imlist)
            #imlist.append(1)
            outputFolder = "/blended"+str(groupBy)+"_"+str(groupByType)
            blendGroupToOne(imlist, a, migrateExif, outputFolder)

def testIfPrime(num): 
    
    return True

    #for i in range(2, (int(num)/2)+1):
        # If num is divisible by any number between
        # 2 and n / 2, it is not prime
    #    if (num % i) == 0:
    #        return False
    #        break
    #else:
    #    return True



if args.video == None:
    print("Standard operation - blend images")
    groupByType = args.groupByType #images or seconds
        #if images, this would be a simple group up by images I.e. 10 images and then merge the average pixels of all
        #if seconds, this would require analysis of all images taken betwee the range of seconds (eg 60 seconds) and for many images taken in 60 seconds, bundle up to 1, for 2 images, bundle to one

    groupBy = args.groupBy

    imagesToBlendToOne = int(groupBy)
    
    if path.isdir("blended"+str(groupBy)+"_"+str(groupByType)) == True :
        print("directory already created")
    else :
        system("mkdir blended"+str(groupBy)+"_"+str(groupByType))

    #system("rm blended"+str(groupBy)+"_"+str(groupByType)+"/image*")
    #system("rm image*")


else:
    #make the directory for the frames
    print("Blend Video!")
    starttime = datetime.now().strftime('%s')
    videoName = args.video.replace(".mp4", "")

    frameCount = 0

    projectName = str(videoName)+"_letsLapse"

    framesDirectory = projectName+"/frames"

    stillsAlreadyExported = False
    if os.path.isdir(projectName) == False:
        system("mkdir "+projectName)
    
    if os.path.isdir(framesDirectory) == False:
        system("mkdir "+framesDirectory)
        print("Creating folders for exported images: "+framesDirectory)
    else:
        #frames directory has been created, count the files to see if they match the length of the video
        frameCountCmd = "ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "+args.video
        for line in os.popen(frameCountCmd):
            fields = line.split()
            frameCount = fields[0]
            
        
        if path.isfile(framesDirectory+'/image'+str(frameCount)+'.jpg') == True:
            stillsAlreadyExported = True
            
    #print("stillsAlreadyExported: "+str(stillsAlreadyExported))
    
    #os.chdir("videos/")
    if stillsAlreadyExported == False:


        print("extract frames with FFMPEG")
        ffmpegCommand = "ffmpeg -i "+str(args.video) +" -qscale:v 1 " +framesDirectory + "/image%d.jpg" 
    
        system(ffmpegCommand)

        endtime = datetime.now().strftime('%s')
        processingtime = int(endtime) - int(starttime)

        print(str(processingtime))
        exit()
    else: 
        print("Frames already exported, no need to export again")
    
    #print(ffmpegCommand)
    
    #possible mode=dirty - this would recompress JPGs if testIfPrime(num) == False

    groupBy = int(args.groupBy)
    groupByType = "images" #must be images as the files don't have metadata which is required for grouping by seconds

    calculatedGroupBy = 0
    biggestMatch = 0

    #we loop through the number of groupBy - see if a folder already exists that we can re-render; this will be faster 
    if testIfPrime(groupBy) == False:
        folderToProcessFrom = ""
        for a in range(groupBy):
            if a>1:
                folderInt = str((groupBy/a)).replace(".0", "")
                testFolder = projectName+"/"+"blended"+folderInt+"_images"
                
                if os.path.isdir(testFolder) == True:
                    #print(folderInt)
                    if int(folderInt) > biggestMatch:
                        biggestMatch = int(folderInt)

                        calculatedGroupBy = a # we want the index of the current 
                        framesDirectory = testFolder
                        #print(framesDirectory)
                        #print("WE HAVE A MATCH")
                        
    else: 
        print("Input blending number is a prime, so much build from the original frames")

    
    print("Using "+framesDirectory+" to dirty-process frames")

    print("calculatedGroupBy: "+str(calculatedGroupBy))

    os.chdir(framesDirectory)
    #print("call this script to make the video" )
    migrateExif = False #the video frames don't contain exif data
    
    #os.getcwd("videos/"+str(args.video)+"_frames/")
    allfiles=os.listdir(os.getcwd())
    fullImageSet = len(allfiles)
    

    #if path.isdir("blended"+str(groupBy)+"_"+str(groupByType)) == True :
    #    print("directory already created")
    #else :
    if calculatedGroupBy == 0:
        print("Not doing any recalculations - this is a normal first run")
    else:
        groupBy = calculatedGroupBy


    blendedDirectory = "blended"+str(groupBy)+"_"+str(groupByType)

    blendingMethod = args.blendingMethod

    # note look into using -threads for better performance
    #exit()
    if blendingMethod == "regular":
        system("mkdir "+blendedDirectory)
        print("About to do blendingMethod == regular ")
        print("-------")
        print("-------")
        print("-------")
        blendByImages(groupBy, fullImageSet, migrateExif)

        if calculatedGroupBy == args.groupBy:
            print("the calculatedGroupBy and input are the same")
            system("mv "+blendedDirectory + " ../")
        else: 
            print("with calculations made to optimse the render, we need to rename the folder when moving it")
            system("mv "+blendedDirectory + " ../"+"blended"+str(args.groupBy)+"_"+str(groupByType) )
            blendedDirectory = "blended"+str(args.groupBy)+"_"+str(groupByType)
        os.chdir("../")
        inputFile = blendedDirectory+"/image%d.jpg"
        system("ffmpeg -i "+inputFile+" -b:v 100000k -vcodec mpeg4 -r 25 ../"+videoName+"_letsLapse_"+str(args.groupBy)+"_"+str(groupByType)+".mp4")
        
        #altMethod1 = 'ffmpeg -i tram.mp4 -filter:v "minterpolate=\'mi_mode=mci:mc_mode=aobmc:vsbmc=1:fps=150\'" tram150fps.mp5'
        #print("Alternative method 1:")
        #print(altMethod1)
        #altMethod2 = 'ffmpeg -i tram.mp4 -filter:v "setpts=0.25*PTS" tram2_25pts.mp4'

    elif blendingMethod == "easing":
        outputFolder = "easing"+str(groupBy)+"_"+str(groupByType)
        system("mkdir "+outputFolder)
        imageIndex = 1
        imagesProcessed = 0
        imagesToProcess = True
        a=1
        delaySpeedInFrames = 120
        while imagesToProcess == True:
            print("--------")
        #for a in range(int(fullImageSet)-1):
            imlist = []
            #if inside the first or last frames, we want to ease in and out
            if a < delaySpeedInFrames:
                print("adding single images")
                curImage = imagePrefix+str(a)+'.jpg'
                imlist.append(curImage)
                blendGroupToOne(imlist, a, migrateExif, outputFolder)
                imageIndex = imageIndex+1
                

            if a > delaySpeedInFrames-1 :
                numberToBlend = a - (delaySpeedInFrames-1)
                #if numberToBlend > 100: 
                #    numberToBlend = 100

                numberToBlend = int(numberToBlend/20) + 1 #bigger the number, the slower the transition
                #numberToBlend = numberToBlend + int(numberToBlend/4)

                print("adding "+str(numberToBlend)+" images")
                for m in range(numberToBlend):
                    curImage = imagePrefix+str(imageIndex+m)+'.jpg'
                    if imageIndex+m < fullImageSet:
                        imlist.append(curImage)
                imageIndex = imageIndex+ len(imlist)
            
            if len(imlist)>0:
                #this length should always be greater than zero
                blendGroupToOne(imlist, a, migrateExif, outputFolder)
            else:
                #this catches the case where we're at the end of the file list inside the folder
                imagesToProcess = False

            #for i in range(imagesToBlendToOne):
                #print(i)
            #    imlist.append('image'+str(i+(imagesToBlendToOne*a))+'.jpg')
            #print("imlist")
            print("Images processed: " + str(imagesProcessed))
            imagesProcessed = imagesProcessed+ len(imlist)

            #check to see if we've gone through the full list
            if imagesProcessed > fullImageSet:
                imagesToProcess = False

            a=a+1

        #imlist.append(1)
        #option 1
        print(os.getcwd())
        print(outputFolder)
        firstImage = outputFolder+'/image'
        outputVideo = 'single'

        ll_utils.convertImagesToVideo(firstImage, outputVideo)

        #option 2 - make the video play and reverse
        #ffmpegCommand = 'ffmpeg -framerate 50 -i '+outputFolder+'/image%d.jpg -filter_complex "[0]reverse[r];[0][r]concat,loop=0:42,setpts=N/50/TB" -crf 5 -pix_fmt yuv420p '+outputFolder+'/single.mp4'
        #system(ffmpegCommand)
        #2 
        #option 3 - loop the playback from the source video
        #ffmpegCommand = 'ffmpeg -stream_loop 3 -i '+outputFolder+'/single.mp4 -c copy '+outputFolder+'/output.mp4'
        #system(ffmpegCommand)
            
    else:
        print("blendingMethod:")
        print(blendingMethod)
        print("   ------ with custom blended images between ranges")

        #check structure matches required spec, eg:
        #[fromframe-toframe@blendrate], or 2000-2200@1,5500-5900@2

        outputFolder = "custom"+str(groupBy)+"_"+str(blendingMethod)
        system("mkdir "+outputFolder)
        #print(fullImageSet)
        customBlendParts = blendingMethod.split(",")
        
        
        curImageSet = 0
        imlist = []
        basedGroupBy = groupBy
        imageToAdd = 0

        

        for i in range(fullImageSet):
            imageToAdd = imageToAdd+1 #use this intead of i as we're 1 based from image sequence

            imlist.append( imagePrefix +str(imageToAdd)+'.jpg' )
            if imageToAdd == groupBy:
                #time to make the image
                curImageSet = curImageSet+1

                print("Image: " + str(curImageSet))
                print(imlist)
                print("   ------ send the images to be blended")
                framesToAddOnCounter = basedGroupBy

                #this is very dirty - shouldn't have to do this much string manipulation inside the loop and ideally store these as variables
                for n in customBlendParts:
                    
                    this_fromFrame = int(n.split("@")[0].split("-")[0])
                    this_toFrame = int(n.split("@")[0].split("-")[1])
                    #print("Testing if inside a custom blending range of frames, from: " + str(this_fromFrame) + " " + str(this_toFrame))
                    if imageToAdd >= this_fromFrame and imageToAdd <= this_toFrame:
                        print("inside a range to blend custom amounts")
                        this_imagesToBlendToOne = int(n.split("@")[1])
                        framesToAddOnCounter = this_imagesToBlendToOne

                groupBy = groupBy + framesToAddOnCounter

                blendGroupToOne(imlist, curImageSet, migrateExif, outputFolder)
                imlist = []
            #check 
            #i=i+1
            #print(i)
        
        system("mv "+outputFolder + " ../")
        os.chdir("../")
        inputFile = outputFolder+"/image%d.jpg"
        system("ffmpeg -i "+inputFile+" -b:v 100000k -pix_fmt yuv420p -r 25 ../"+videoName+"_letsLapse_"+str(args.groupBy)+"_"+str(groupByType)+"_"+str(blendingMethod)+".mp4")

        #imlist = [imagePrefix+'1.jpg', imagePrefix+'2.jpg', imagePrefix+'3.jpg', imagePrefix+'4.jpg', imagePrefix+'5.jpg', imagePrefix+'6.jpg', imagePrefix+'7.jpg', imagePrefix+'8.jpg', imagePrefix+'9.jpg', imagePrefix+'10.jpg']
        #imageSeq = "1"
        #blendGroupToOne(imlist, imageSeq, migrateExif, outputFolder)
        #print()
        exit()
    
    
    #system("python3 /../blend.py --groupBy "+groupBy+" --groupByType images --makeMP4 yes")


    #optional boomerang output
    


    #
    
    exit()
    
if groupByType == "images" :
    migrateExif = True
    outputFolder = "/blended"+str(groupBy)+"_"+str(groupByType)
    blendByImages(imagesToBlendToOne, fullImageSet, migrateExif)
else :
    print("building up lists of images within certain timeranges - seconds: " + str(imagesToBlendToOne))
    

    #foundMissingFiles = testFiles("basic")
    
    #if foundMissingFiles == True :
    #    print("based on missing files, aborting process")
    #    exit()

    
    timerangeGroupIndex = 0
    imlist=[]
    outputFolder = "/blended"+str(groupBy)+"_"+str(groupByType)
    for a in range(int(fullImageSet)-folderCount): #exclude folders from the count
        if thisFolderIndex == False :
            filename = imagePrefix+str(a)+'.jpg'
        if thisFolderIndex != False :
            filename = imagePrefix+str(int(thisFolderIndex)*1000+a)+'.jpg'
        #print(filename)
        thisTimestamp = getMeta( filename )
        
        
        if a == 0 : 
            startingTimestamp = thisTimestamp


        if(thisTimestamp < (startingTimestamp + imagesToBlendToOne)) :
            imlist.append(filename)
        else: 
            #imlist.append(0)
            print("blending the following images")
            print(imlist)
            migrateExif = True
            blendGroupToOne(imlist, timerangeGroupIndex, migrateExif, outputFolder)
            timerangeGroupIndex = timerangeGroupIndex+1
            startingTimestamp = thisTimestamp
            imlist=[]
            imlist.append(filename)




if args.makeMP4 == "yes" :
    inputImage = "blended"+str(groupBy)+"_"+str(groupByType)+"/image"
    
    #in the event we are just blending an image tequence, we won't be looking for a blended image
    if imagesToBlendToOne == 1:
        inputImage = "image"
    
    folderStrOutput = ""
    if thisFolderIndex != False :
        folderStrOutput = "_"+str(thisFolderIndex)

    outputVideo = "../"+thisDir+"_blendedVideo"+folderStrOutput+"_"+str(groupByType)+""+str(imagesToBlendToOne)
    
    ll_utils.convertImagesToVideo(firstImage, outputVideo)
    
    