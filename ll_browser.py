import os
from os import listdir, walk
from os.path import isfile, join

#


def getShoots(filterBy):
    #1 - go through the top level
    siteRoot = os.getcwd()
    topLevel = sorted(os.listdir(siteRoot))
    shootFolders = []



    for t in range(len(topLevel)):
        #look in each and and find the timelapse_ folders - these are the shoot folders
        if "timelapse_" in topLevel[t]:
            shootImages = []
            thisShoot = topLevel[t]
            #print("-"+thisShoot)
            shootLevel = sorted(os.listdir(siteRoot+"/"+thisShoot))
            for s in range(len(shootLevel)):
                thisGroup = shootLevel[s]
                #print("--"+thisGroup)
                groupLevel = sorted(os.listdir(siteRoot+"/"+thisShoot + "/"+thisGroup))
                for f in range(len(groupLevel)):
                    #need to include the first image as this wont be met by the filter
                    if f == 0:
                        shootImages.append(thisGroup.replace('group','')+"/"+groupLevel[f].replace('.jpg',''))
                    elif filterBy in groupLevel[f]:
                        #print("---"+groupLevel[f])
                        shootImages.append(thisGroup.replace('group','')+"/"+groupLevel[f].replace('.jpg',''))
                #
            #shootFolders.append()
            shootNameAndImages = [thisShoot]
            shootNameAndImages.append(shootImages)
            shootFolders.append(shootNameAndImages)

    return shootFolders

def getStills():
    if path.isdir("stills") == False :
        system("mkdir stills")

    siteRoot = os.getcwd()
    topLevel = sorted(os.listdir(siteRoot+"/stills/"))
    jpegs = []
    for t in range(len(topLevel)):
        #look in each and and find the timelapse_ folders - these are the shoot folders
        if 'thumb' not in topLevel[t]:
            jpegs.append(topLevel[t].replace('.jpg',''))

    return jpegs
