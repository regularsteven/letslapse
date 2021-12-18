#!/bin/bash
#from this directory
#./blend.sh 10 videos/OneMonth.mp4

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROCESS_SPEED=$1
INPUT_FILE=$2

PROCESS_FROM=$3
PROCESS_TO=$4


#if the input param is a video, we'll use this for the FFMPEG export
FFMPEG_EXPORT=" "
#if the input param is a folder, we'll use this for the start and end frames for processing

if [ -n "$PROCESS_FROM" ]; then
    if [ -n "$PROCESS_TO" ]; then
        FFMPEG_EXPORT="-ss $PROCESS_FROM -to $PROCESS_TO "
    fi
fi

basename "$INPUT_FILE"
FILE_NAME_EXTN="$(basename -- $INPUT_FILE)"

FILE_NAME=`echo $FILE_NAME_EXTN | cut -d "." -f 1`
FILE_EXTN=`echo $FILE_NAME_EXTN | cut -d "." -f 2`

if [ -d $INPUT_FILE ]; then
    echo "Process Directory"
elif [ -f $INPUT_FILE ]; then
    echo "Blend Video - 1) Video to image seq, 2) Blend & stack images, 3) Images to MP4"
else
    echo "error - no file or folder exists"
fi




POST_PROCESS=0

if [ $PROCESS_SPEED -gt 10 ]; then
    echo "------------------------------"
    echo "------------------------------"
    echo "Big process speed, need to break into smaller tasks"
    echo "------------------------------"
    echo "------------------------------"
    
    if [ $PROCESS_SPEED == 20 ]; then
        PROCESS_SPEED=5
        POST_PROCESS=4
    fi

    if [ $PROCESS_SPEED == 25 ]; then
        PROCESS_SPEED=5
        POST_PROCESS=5
    fi

    if [ $PROCESS_SPEED == 30 ]; then
        PROCESS_SPEED=6
        POST_PROCESS=5
    fi
    if [ $PROCESS_SPEED == 40 ]; then
        PROCESS_SPEED=10
        POST_PROCESS=4
    fi
    if [ $PROCESS_SPEED == 50 ]; then
        PROCESS_SPEED=10
        POST_PROCESS=5
    fi
    if [ $PROCESS_SPEED == 100 ]; then
        PROCESS_SPEED=10
        POST_PROCESS=10
    fi
fi


STACKED_FOLDER=" "
TOTAL_IMAGES=" "
TOTAL_IMAGES_MATCH_PROCESS_SPEED=" "
TOTAL_IMAGES_SAFE=" "
FRAMES_DIR=" "


if [ -f $INPUT_FILE ]; then

    #read name
    echo "1 Video to Image Sequence"
    echo " - $INPUT_FILE speed at $PROCESS_SPEED x speed to IMAGES"

    FRAMES_DIR="videos/$FILE_NAME-frames"
    mkdir "$SCRIPT_DIR/$FRAMES_DIR"
    ffmpeg $FFMPEG_EXPORT-i $INPUT_FILE -qscale:v 1 $FRAMES_DIR/image%d.jpg

    STACKED_FOLDER="videos/$FILE_NAME-stacked-$PROCESS_SPEED-images"
fi


if [ -d $INPUT_FILE ]; then
    FRAMES_DIR="$FILE_NAME/group0"
    STACKED_FOLDER="$FILE_NAME/stacked-$PROCESS_SPEED-images"
fi

mkdir "$SCRIPT_DIR/$STACKED_FOLDER/"
#need to clean up the thumbs for this, they get in the way
/bin/rm -f $SCRIPT_DIR/$FRAMES_DIR/*thumb*.jpg
TOTAL_IMAGES=$(ls $FRAMES_DIR/ | wc -l)
TOTAL_IMAGES_MATCH_PROCESS_SPEED=`expr $TOTAL_IMAGES  %  $PROCESS_SPEED`

TOTAL_IMAGES_SAFE=$TOTAL_IMAGES

if [ $TOTAL_IMAGES_MATCH_PROCESS_SPEED != 0 ]; then
    TOTAL_IMAGES_SAFE=`expr $TOTAL_IMAGES  -  $PROCESS_SPEED`
fi


THIS_FILE=0
INPUT_IMAGE=0

echo "2 Blend & Stack Images"

while [ $POST_PROCESS -ge 0 ]; do
    
    echo "POST PROCESS: $POST_PROCESS"
    
    for imageSet in `seq 1 $TOTAL_IMAGES`; do
        THIS_OUTPUT_FILE=`expr $THIS_OUTPUT_FILE + 1`
        FILES_TO_CONVERT=""
        #echo "imageSet : $imageSet"
        FROM_IMAGE=`expr $INPUT_IMAGE + 1`
        for image in `seq 1 $PROCESS_SPEED`; do
            INPUT_IMAGE=`expr $INPUT_IMAGE + 1`
            #CUR_INDEX=`expr $image \* $imageSet`
            #echo " :$INPUT_IMAGE"
            FILES_TO_CONVERT+="$FRAMES_DIR/image$INPUT_IMAGE.jpg "
        done

        echo "blending image$FROM_IMAGE.jpg to image$INPUT_IMAGE.jpg into image${THIS_OUTPUT_FILE}.jpg"
        BUMP_CONTRAST=" "
        BUMP_CONTRAST=" -modulate 100,130 -level 10%,90%,1"
        convert $FILES_TO_CONVERT $BUMP_CONTRAST -evaluate-sequence mean $STACKED_FOLDER/image${THIS_OUTPUT_FILE}.jpg

        #rm $FILES_TO_CONVERT
        if [ $INPUT_IMAGE -ge $TOTAL_IMAGES_SAFE ]
        then
            #rm $FRAMES_DIR -R
            echo "No more to process"
            break
        fi
    done

    if [ $POST_PROCESS == 0 ]; then
        echo "NO MORE"
        PROCESS_SPEED=$1
        POST_PROCESS=-1
    fi

    if [ $POST_PROCESS -gt 0 ]; then
        
        echo "ONE MORE BATCH"
        

        THIS_FILE=0
        INPUT_IMAGE=0
        THIS_OUTPUT_FILE=0

        TOTAL_IMAGES=$(ls $STACKED_FOLDER/ | wc -l)
        
        FRAMES_DIR=$STACKED_FOLDER


        STACKED_FOLDER="videos/$FILE_NAME-stacked-$1-images"

        mkdir "$SCRIPT_DIR/$STACKED_FOLDER"

        
        PROCESS_SPEED=$POST_PROCESS
        
        
        
        TOTAL_IMAGES_MATCH_PROCESS_SPEED=`expr $TOTAL_IMAGES  %  $PROCESS_SPEED`

        TOTAL_IMAGES_SAFE=$TOTAL_IMAGES

        if [ $TOTAL_IMAGES_MATCH_PROCESS_SPEED != 0 ]; then
            TOTAL_IMAGES_SAFE=`expr $TOTAL_IMAGES  -  $PROCESS_SPEED`
        fi
        echo $TOTAL_IMAGES_SAFE
        POST_PROCESS=0

    fi


done


ffmpeg -i $STACKED_FOLDER/image%d.jpg -b:v 100000k -vcodec mpeg4 -r 25 videos/$FILE_NAME-$PROCESS_SPEED-speed.mp4


while true; do
    read -p "Move video to Camera folder?" yn
    case $yn in
        [Yy]* ) mv videos/$FILE_NAME-$PROCESS_SPEED-speed.mp4 ../../dcim/Camera/; break;;
        [Nn]* ) break;;
        * ) echo "Please answer yes or no.";;
    esac
done


while true; do
    read -p "Move stacked images to Camera folder?" yn
    case $yn in
        [Yy]* ) mv $STACKED_FOLDER ../../dcim/Camera/; break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
done
