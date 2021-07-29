from os import system


def convertImagesToVideo(inputImage, outputVideo):
    system("ffmpeg -i "+inputImage+"%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 "+outputVideo+".mp4")
