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

IDEA

1) display most recent low-res image as poster frame in html img src
    Javascript to refresh to the image every minute
2) behind this image, previous images and load up slider for scrobble player


3b) 


