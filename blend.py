from PIL import Image
    
# Take two images for blending them together   
imageA = Image.open("./blending/image0000.jpg") #.convert("RGBA")
imageB = Image.open("./blending/image0001.jpg") #.convert("RGBA")

lastAlphaBlend

for i in range(3):

    lastAlphaBlend = Image.blend(image1, image2, alpha=(1/2))


image3 = Image.open("./blending/image0002.jpg") #.convert("RGBA")
alphaBlended2 = Image.blend(alphaBlended1, image3, alpha=(1/3))


image4 = Image.open("./blending/image0002.jpg") #.convert("RGBA")
alphaBlended3 = Image.blend(alphaBlended2, image4, alpha=(1/4))


#for each layer, opacity needs to decrease for each layer allowing for the blur
#top layer = 15
#bottom layer = 1
#take 100 / number of layer.
#layer 1 = 100
#layer 2 = 50
#layer 3 = 33
#layer 4 = 25


# Display the alpha-blended images
alphaBlended2.save("./blending/output.jpg")
#alphaBlended2.show()