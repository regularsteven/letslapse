1) ensure dependencies are installed
`brew install webp`
`brew install ffmpeg`

2) convert source HQ clip to low FPS for use

2a) trim if required:

ffmpeg -ss 2 -t 10 -i Tram_Loop_Clean_50fps_square.mov \
  -vf "select='not(mod(n\,5))',scale=640:640:flags=lanczos,setpts=N/10/TB" \
  -r 10 -an -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart \
  Tram_Loop_640_10fps_trimmed.mp4

2b) optional: use full source if it's good:

ffmpeg -i Tram_Loop_Clean_50fps_square.mov \            
  -vf "select='not(mod(n\,5))',scale=640:640:flags=lanczos,setpts=N/10/TB" \
  -r 10 -an \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart \
  Tram_Loop_640_10fps.mp4

3) create atlas sprite map from low FPS working version
ffmpeg -i Tram_Loop_640_10fps_trimmed.mp4 \           
  -vf "scale=320:320:flags=lanczos,tile=11x11:margin=0:padding=0" \         
  -frames:v 1 tram_atlas_320_11x11.png 

4) convert to webp for optimised web use                                
cwebp -q 82 -m 6 tram_atlas_320_11x11.png -o tram_atlas_320_11x11.webp  