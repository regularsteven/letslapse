#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INPUT_FILE=$2
PROCESS_SPEED=$1


basename "$INPUT_FILE"
FILE_NAME_EXTN="$(basename -- $INPUT_FILE)"

FILE_NAME=`echo $FILE_NAME_EXTN | cut -d "." -f 1`
FILE_EXTN=`echo $FILE_NAME_EXTN | cut -d "." -f 2`

echo "Blend Basic - 1) Video to image seq, 2) Blend & stack images, 3) Images to MP4"
#read name
echo "1 Video to Image Sequence"
echo " - $INPUT_FILE at $PROCESS_SPEED x speed to IMAGES"


#echo $FILE_NAME_EXTN
#echo $FILE_NAME
#echo $FILE_EXTN

FRAMES_DIR="videos/$FILE_NAME-frames"
STACKED_FOLDER="videos/$FILE_NAME-stacked-$PROCESS_SPEED-images"

mkdir "$SCRIPT_DIR/$FRAMES_DIR"

ffmpeg -i $INPUT_FILE -qscale:v 1 $FRAMES_DIR/image%d.jpg


mkdir "$SCRIPT_DIR/$STACKED_FOLDER"

echo "2 Blend & Stack Images"

max=$PROCESS_SPEED
TOTAL_IMAGES=$(ls $FRAMES_DIR/ | wc -l)

#SAFE is to ensure we don't try to add more images into a frame than we've added in other images - so it might cut short a little
TOTAL_IMAGES_SAFE=`expr $TOTAL_IMAGES - $PROCESS_SPEED`


THIS_FILE=0
INPUT_IMAGE=0
for imageSet in `seq 1 $TOTAL_IMAGES`; do
    THIS_OUTPUT_FILE=`expr $THIS_OUTPUT_FILE + 1`
    FILES_TO_CONVERT=""
    #echo "imageSet : $imageSet"
    FROM_IMAGE=$INPUT_IMAGE
    for image in `seq 1 $max`; do
        INPUT_IMAGE=`expr $INPUT_IMAGE + 1`
        #CUR_INDEX=`expr $image \* $imageSet`
        #echo " :$INPUT_IMAGE"
        FILES_TO_CONVERT+="$FRAMES_DIR/image$INPUT_IMAGE.jpg "
    done
    echo "blending image$FROM_IMAGE.jpg to image$INPUT_IMAGE.jpg into img${THIS_OUTPUT_FILE}.jpg"
    convert $FILES_TO_CONVERT-evaluate-sequence mean $STACKED_FOLDER/img${THIS_OUTPUT_FILE}.jpg
    if [ $INPUT_IMAGE -ge $TOTAL_IMAGES_SAFE ]
    then
        echo "No more files to process"
        break
    fi
done



ffmpeg -i $STACKED_FOLDER/img%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 videos/$FILE_NAME-$PROCESS_SPEED-speed.mp4


