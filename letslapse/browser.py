import os
from os import listdir, walk, path
from os.path import isfile, join
from os import system

import letslapse.config as config
#
# if debugging is required,
# python3 ll_browser.py and uncomment the last line to print results in command line

def getShoots(filterBy):
    #1 - go through the top level
    siteRoot = os.getcwd()
    topLevel = sorted(os.listdir(siteRoot))
    shootFolders = []



    for t in range(len(topLevel)):
        #look in each and and find the timelapse_ folders - these are the shoot folders
        
        if "timelapse_" in topLevel[t] and ".log" not in topLevel[t]:
            #print(t)
            shootImages = []
            thisShoot = topLevel[t]
            #print("-"+thisShoot)
            shootLevel = sorted(os.listdir(siteRoot+"/"+thisShoot))
            #print(shootLevel)
            for s in range(len(shootLevel)):
                thisGroup = shootLevel[s]
                if "group" in thisGroup: #this avoids latest.jpg issues as created from ultraBasic
                
                    #print("--"+thisGroup)
                    groupLevel = sorted(os.listdir(siteRoot+"/"+thisShoot + "/"+thisGroup))
                    #print(groupLevel)
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
    if path.isdir(config.storagePath) == False :
        system("mkdir " + config.storagePath)

    # siteRoot = os.getcwd()
    
    topLevel = sorted(os.listdir(config.siteRoot+config.storagePath))
    jpegs = []
    for t in range(len(topLevel)):
        #look in each and and find the timelapse_ folders - these are the shoot folders
        #if 'thumb' not in topLevel[t]:
        #removed extentions: - add this at end: .replace('.jpg','') 
        jpegs.append(topLevel[t])

    return jpegs

def getVideos():
    if path.isdir("videos") == False :
        system("mkdir videos")

    siteRoot = os.getcwd()
    topLevel = sorted(os.listdir(siteRoot+"/videos/"))
    mp4s = []
    for t in range(len(topLevel)):
        #look in each and and find the timelapse_ folders - these are the shoot folders
        mp4s.append(topLevel[t])

    return mp4s

#print(getShoots("00.jpg"))