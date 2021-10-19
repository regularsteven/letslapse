#!/bin/bash

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INPUT_FILE=$1
PROCESS_SPEED=$2


basename "$INPUT_FILE"
FILE_NAME_EXTN="$(basename -- $INPUT_FILE)"

FILE_NAME=`echo $FILE_NAME_EXTN | cut -d "." -f 1`
FILE_EXTN=`echo $FILE_NAME_EXTN | cut -d "." -f 2`

echo "Blend Basic - 1) Video to image seq, 2) Blend to images, 3) Images to MP4"
#read name
echo "Input: $INPUT_FILE - Process: $2 x speed"


#echo $FILE_NAME_EXTN
#echo $FILE_NAME
#echo $FILE_EXTN

FRAMES_DIR="videos/$FILE_NAME-frames"

mkdir "$SCRIPT_DIR/$FRAMES_DIR"



#ffmpeg -i $INPUT_FILE -qscale:v 1 $FRAMES_DIR/image%d.jpg


#convert " +listOfFiles+ " -evaluate-sequence mean "+fileName

max=$PROCESS_SPEED
FILES_TO_CONVERT=""
for i in `seq 1 $max`; do
    FILES_TO_CONVERT+="$FRAMES_DIR/image${i}.jpg "
done
i=1
convert $FILES_TO_CONVERT-evaluate-sequence mean videos/fileName.jpg
echo $i