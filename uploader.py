import requests, os, json

import ll_utils

fileToUpload = "stills/img_21_15_49_ss-300000_iso-800_awbg-3,2_manual.jpg"
fileName = os.path.basename(fileToUpload)



#ll_utils.pingCMS()
#ll_utils.logIn()

ll_utils.registerCMS()

#postID = ll_utils.createPost("debug post")
#print("New post created: "+str(postID))



#ll_utils.uploadMedia(fileToUpload, postID)
#print("Media uploaded")

#print("ID = "+ str(idOfUploadedMedia))


#ll_utils.attachPostToImage(postID, mediaID)

#http://192.168.7.1:8000//wp-json/wp/v2/media?parent=227

#

