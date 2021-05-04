# pitime
raspberry pi timelaps rig


shoot, edit, stream

"local internal" = internal storage
"local storage" = SD or HDD storage

## to do
1) capture image - at interval
    from pi hq camera
    or from sony (gphoto2)
    or from fake source (i.e. folder one by one)
    &
    place image inside 'drop' local storage folder if available
        - else wait until it's back (might have been disconnected for transfer to backup / delete)
2) watch 'drop' folder for new files
    extract JPEG if possible (exiftool)
    or create JPEG if not possible
    & 
    extract to 'processed' local storage folder
3a) Option A - Simple Local Stream (ffmpeg)
    processed folder sorts by most recent

    //options:
    ffmpeg -loop 1 -i BangkokSky-%d.jpg -vf scale=320:240 -r 10 -vcodec mpeg4 -f mpegts udp://127.0.0.1:554

    resize: 
    ffmpeg -loop 1 -i BangkokSky-%d.jpg -vf scale=320:240 -r .5 -vcodec mpeg4 -f mpegts udp://192.168.30.75:9099

   test stream:
   ffprobe udp://192.168.30.75:9099

    ffmpeg -loop 1 -re -f lavfi -i BangkokSky-%d.jpg -vf scale=320:240 -r .5 -f rtp rtp://192.168.56.75:9099




    ffmpeg -y -i rtsp://admin:admin@192.168.56.75:554/live -vframes 1 BangkokSky-1.jpg


    # local video - is working: 
    ## ffmpeg -i melbourne.mp4 -f mpegts udp://127.0.0.1:9099
    ## open in vlc: udp://@127.0.0.1:9099
    ## ffmpeg -i melbourne.mp4 -f mpegts udp://192.168.30.75:9099
    ## open local: udp://@192.168.30.75:9099

    #local image -  is working:
    ##ffmpeg -loop 1 -i BangkokSky-%d.jpg -vf scale=320:240 -r .5 -vcodec mpeg4 -f mpegts udp://192.168.30.75:9099
    ## open local udp://@192.168.30.75:9099

    //ffmpeg -i melbourne.mp4 -f rtp rtp://192.168.30.75:9099
    //ffmpeg -i melbourne.mp4 -vf scale=320:240 -r .5 -f rtp rtp://192.168.30.75:9099



    # resize all images - is working
    ## ffmpeg -i BangkokSky-%d.jpg -vf scale="720:-1" resize%d.jpg


    1: Get full image
    2: convert image to small version
        - ffmpeg -i BangkokSky-%d.jpg -vf scale="720:-1" resize/seq%d.jpg
    3: update the stream with the smaller versions
        - ffmpeg -loop 1 -i seq%d.jpg  -r .5 -vcodec mpeg4 -f mpegts udp://192.168.30.75:9099


# ffmpeg resize 
ffmpeg -i seq_%04d.jpg -vf scale=1920:-1 resize/small_%04d.jpg

# ffmpeg create timelapse seq 
ffmpeg -framerate 25 -pattern_type glob -i "*.jpg" -c:v libx264 -crf 0 output.mp4  -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2"
ffmpeg -r 24 -i small_%04d.jpg -vcodec libx264 -y -an video.mp4 -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2"

streaming idea 2: WORKING across network
raspivid -t 0 -l -o tcp://192.168.30.76:3333 -w 640 -h 360
raspivid -t 0 -l -o tcp://192.168.30.76:3333 -w 1280 -h 720
vlc tcp/h264://192.168.30.76:3333
OR
tcp/h264://192.168.30.76:3333


IDEA

1) display most recent low-res image as poster frame in html img src
    Javascript to refresh to the image every minute
2) behind this image, previous images and load up slider for scrobble player


3b) 


# troubleshooting
sometimes the camera crashes - find it and kill it
ps -A | grep raspi
sudo kill 1599 
