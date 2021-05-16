import os, numpy, PIL
from PIL import Image
from os import system
import argparse


parser = argparse.ArgumentParser()
parser.add_argument('--imagesToBatch', help='number of images to batch')
args = parser.parse_args()



system("rm blendedImage*")

#### Access all JPG files in directory
allfiles=os.listdir(os.getcwd())
print("allfiles")
print(allfiles)

#imlist=[filename for filename in allfiles if  filename[-4:] in [".jpg",".JPG"]]


#['image0.jpg', 'image1.jpg', 'image2.jpg', 'image3.jpg', 'image4.jpg']

imagesToBatch = int(args.imagesToBatch)
fullImageSet = len(allfiles) / imagesToBatch
for a in range(int(fullImageSet)):
    imlist=[]
    for i in range(imagesToBatch):
        #print(i)
        if a == 0:
            imlist.append('image'+str(i)+'.jpg')
        else :
            imlist.append('image'+str(i+(imagesToBatch*a))+'.jpg')


    print("imlist")
    print(imlist)

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
    fileName = "blendedImage"+str(a)+".jpg"
    print(fileName)
    out.save(fileName)
    #out.show()

system("ffmpeg -i blendedImage%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 a_blendedVideo"+str(imagesToBatch)+".mp4")