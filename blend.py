from PIL import Image

# Function to change the image size
def changeImageSize(maxWidth, 
                    maxHeight, 
                    image):
    
    widthRatio  = maxWidth/image.size[0]
    heightRatio = maxHeight/image.size[1]

    newWidth    = int(widthRatio*image.size[0])
    newHeight   = int(heightRatio*image.size[1])

    newImage    = image.resize((newWidth, newHeight))
    return newImage
    
# Take two images for blending them together   
image1 = Image.open("./shoots/blend/set-edit-1.jpg") #.convert("RGBA")
image2 = Image.open("./shoots/blend/set-edit-2.jpg") #.convert("RGBA")

# Make the images of uniform size
#image3 = changeImageSize(800, 500, image1)
#image4 = changeImageSize(800, 500, image2)

# Make sure images got an alpha channel


# Display the images
#image5.show()
#image6.show()

# alpha-blend the images with varying values of alpha
alphaBlended1 = Image.blend(image1, image2, alpha=.5)
#alphaBlended2 = Image.blend(image5, image6, alpha=.4)

# Display the alpha-blended images
alphaBlended1.save("output.jpg")
#alphaBlended2.show()