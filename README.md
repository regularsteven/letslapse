# LetsLapse
### A DIY time-lapse system, built around Raspberry Pi hardware

LetsLapse allows you to capture day to night time-lapses sequences on affordable hardare, while producing outstanding results.

To get started, you will need a Raspberry Pi device, a compatible camera, MicroSD card and power source. As for specifics, you can run this from a Pi 3, 4, 4B or Pi Zero W, with a range of cameras.

LetsLapse has been developed with Pi Zero W and HQ Camera Module in mind, for compact size and low power requiremens allowing for long shoots.

To proceed, you **must have a Pi and Camera connected**. See the first three pages of https://projects.raspberrypi.org/en/projects/getting-started-with-picamera, until it says "Start up your Raspberry Pi". You don't need to do this yet for this process.

# Install Guide

## Quick Install
This install implies you know how to install Raspberry OS and connect to your device. If you're unsure, see Detailed Install below.

## 1) Install and connect to device
Install  **Raspberry Pi OS Lite** on the MicoSD Card / allow SSH and Wifi and log in to device with SSH.

## 2) Download LetsLapse
Raspberry Pi OS Lite doesn't include GIT. To download ('clone') LetsLapse, we need to install git:

```
sudo apt install git -y
```
Once completed, run the following:

```
git clone https://github.com/regularsteven/letslapse
```
## 3) Install LetsLapse Dependencies 

```
cd letslapse
sudo sh install.sh 

```
## Detailed Install


### 1) Install Raspberry Pi OS 
See https://www.raspberrypi.org/software/ for the **Raspberry Pi Imager**. A fast SD card is required, and the bigger the better.

 > Recommend **Raspberry Pi OS Lite**, as this has the smallest footprint and excudes stuff that can slow the device down - like a pretty operating system which isn't required.

Follow the instructions to ensure the process is verified.

### 2) Set up Raspberry Pi WiFi and system access
See https://github.com/regularsteven/letslapse/. We need to put settings on the MicroSD card to configure wireless network and access to the OS.

1) Place wpa_supplicant.conf (inside 'install' folder) to the SD card partition called "Boot" of your newly formatted MicroSD card
     > Edit the file to put your own WiFi credentials in this file. The formatting matters - so put your wireless network(s) inside the "quotations". If you have a mobile phone hotspot, you can add this and your home network. The Pi will connect to whatever it see's first, in order of their placement.
2) Create an empty file called 'ssh' in the same "Boot" partition. This file tells the Pi OS to allow 'SSH' (logging in remote) to occur.
    > This can be called ssh.txt or just 'ssh'. 

### 3) Start and find the Pi on your network 
Plug the MicroSD card to the Pi and plug in power. Depending on the device, it can take some time to boot up. We will be running the install with no screen plugged in, so we need to wait for the device to be on the network.

If you're in luck, you can access the device via 'raspberrypi.local' on your network. However, not all routers support this, so it might be a little more work to know the Pi's 'address' on your network.

In a Terminal window (MacOS / Linux) or Command Shell (Windows), type:
```
 ping raspberrypi.local 
```

If you're lucky, you'll see "64 bytes from raspberrypi (10.3.141.212): icmp_seq=1 ttl=64 time=0.265 ms", or similar.

In this event, you don't need to worry about IP addresses. You can jump to step 4.

If you're not a lucky person, we need to **find the IP address**. This can be found a number of ways.

1) Get it from your router (if you know it) or WiFi Hotspot.
   > Logging into your router should show you DHCP connections, along with IP addresses and names. Look for 'raspberrypi', and then you will have your IP address. Many Android and iOS devices with a HotSpot will show connections. Many devices (iPhone's / Samsung Galaxy's) will show the IP addresses.
2) In a Terminal window or Command Shell, scan the network, and take note of the output message. You're looking for something like "10.1.2.9" or "192.168.1.9".
    > This runs a scan across the network you're own and loks for the hardware of the network adapter, which is unique to the Pi Zero or Pi4
    
    a) MacOS / Linux, looking for Pi Zero:
    ```
    arp -na | grep -i b8:27:eb
    ```
    b) MacOS / Linux, looking for Pi4 (has a different MAC ID):
    ```
    arp -na | grep -i dc:a6:32
    ```
    c) Windows: 
    ```
    nslookup raspberrypi 
    ```
Take note of the IP address - this is how you need to connect and configure the device. Once you've got the IP, you can ping to test the connectivity like above, only with the IP and not the name. For example:

```
 ping 192.168.0.9 
```

### 4) Log in with SSH

MacOS and Linux can use Terminal, but Windows may require extra configuration. 

> This step is about 'SSH-ing' into the device. SSH is a protocol, like HTTP or FTP, that allows you to log in to the device. We need to SSH in to run some updates and set up the device. 

#### MacOS / Linux
If you're the lucky one with raspberrypi.local found in step 3, you don't need the 'IP' (192.168.0.9).

```
ssh pi@192.168.0.9
```
OR
```
ssh pi@raspberrypi.local
```

You'll be asked for the password. Because this is brand-new, the **password is _raspberry_** 

> Note: If you've done this before, you might be rejected. In this instance,run

```
ssh-keygen -R raspberrypi.local
```

#### Windows
Open Power Shell and type 'ssh pi@192.168.0.9', where 192.168.0.9 is the IP of your device as identified in step 3. If it works, great. If not, I suggest a tool called Putty - it's a simple SSH client which allows for remote connections. See https://www.putty.org/ and find the Download link. In most instances, you want "MSI (‘Windows Installer’) 64-bit x86". Download and install. Once installed, open up. 

In here, you can enter the IP, username and password. 

Username: **pi**

Password: **raspberry**

Address: **IP as found in step three.**

### Install LetsLapse / Update the Pi OS


1) Ideally, you should update your password. Do, or don't. But ideally you do. Type the following and follow prompts:

    ```
    passwd
    ```
2) Update the OS / Software with latest from Raspbbery Pi

    ```
    sudo apt update && sudo apt upgrade
    ```
3) Install 'git'. This allows us to 'clone' LetsLapse code, and BC.

    ```
    sudo apt install git bc -y
    ```

4) Clone LetsLapse

    ```
    git clone https://github.com/regularsteven/letslapse
    ```

5) Run install script

    ```
    cd letslapse
    sudo sh install.sh 
    ```
    > This may take some time, and will install a number of 'dependencies', as well as configure your device to talk / communicate with your camera. Once installed, you will need to restart. You may wish to set up some other aspects of Raspberry Pi, such as the timezone, location settings, and so on. You can do this with "sudo raspi-config" (in the terminal), but this isn't mandatory.

6) Reboot and wait...

## Run LetsLapse

If everything above worked, LetsLapse is installed. In a browser on your network, type the IP address or raspberrypi.local into your browser. If we've got this far, it's good to go.


## What have we done? What's LetsLapse


## Additional Notes 
For, um, cleaning up... 

### Memory issues with floating numpy stuff
Killed message can display when trying to blend images - try update swapfile (4096) as test
Can droubleshoot with dmesg
```
sudo pico /etc/dphys-swapfile
```

### Dependencies installation 
```
sudo apt-get update && apt install python3-pip -y
sudo apt install libopenjp2-7 libopenjp2-7-dev libopenjp2-tools libatlas-base-dev
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt
```

### Windows / File Access

Install SAMBA for simple filesystem access
```
sudo apt-get install samba samba-common-bin 
```

```
sudo nano /etc/samba/smb.conf
```

Add the following to the bottom:
```
[mypishare]
        path = /home/pi/letslapse
        writeable=Yes
        create mask=0777
        directory mask=0777
        public=no
```
Create a user for SAMBA access

```
sudo smbpasswd -a pi
sudo systemctl restart smbd 
```


### POWER REDUCTION
Much of the following is automated inside the install script, but noted for reference

#### Remove bluetooth
```
sudo pico /boot/config.txt
```

Add below, save and close the file Permalink
```
#Disable Bluetooth
dtoverlay=disable-bt
```
 > or remove everything
```
sudo apt-get purge bluez -y
sudo apt-get autoremove -y
```

#### Kill LED light on zero

```
echo none | sudo tee /sys/class/leds/led0/trigger
echo 1 | sudo tee /sys/class/leds/led0/brightness
```

Add the following to config:
```
sudo pico /boot/config.txt
```

```
dtparam=act_led_trigger=none
dtparam=act_led_activelow=on
```

#### Disable hdmi
```
/usr/bin/tvservice -o
sudo pico /etc/rc.local
```

Add the following to the bottom:
```
 f /usr/bin/tvservice -o
```


## Troubleshooting notes
sometimes the camera crashes - find it and kill it
```
ps -A | grep raspi
sudo kill 1599 
```


## Issues with performance
Issues have been found with slow SD cards. If there's an issue that's hard to explain, verify the SD card can work at reasonable performance.

 > https://www.raspberrypi.org/blog/sd-card-speed-test/
  > cd /usr/share/agnostics/
  > sudo sh /usr/share/agnostics/sdtest.sh


### Update Pi Firmware

Some older devices may need a real update. In the instance things just aren't right, run the following to update

```
sudo rpi-update
```
### Additional tools to remove - potential speed optimisations
Can the following be removed?
* aplay
* pulseaudio
* xserver related




# for local development
## best to run of a pi zero or pi4 (for increased performance) and mount locally

To mount, ensure directory is in place of the last attribute
```
sshfs pi@10.3.141.224:/home/pi/letslapse ~/Documents/dev/letslapse-pi4dev/

```
To unmount:
```
umount ~/Documents/dev/letslapse-pi4dev/
```


# cm4 notes
## upgrading to latest everything
Bullseye is now out, trying to ensure we can run letslapse on a CM4 latest OS version 

After flashing drive with sudo ./rpiboot and the imager, adding wpa-suplicant and ssh...

```
sudo apt update
sudo apt dist-upgrade -y
sudo rpi-update
```
 - this will get everything to latest 32bit version
 benchmark after reboot with:





Prime number TEST A
```
sysbench --test=cpu --cpu-max-prime=20000 run
```
I/O of device TEST B
```
sysbench --test=fileio --file-total-size=2G prepare
sysbench --test=fileio --file-total-size=2G --file-test-mode=rndrw --max-time=300 --max-requests=0 run
sysbench --test=fileio --file-total-size=2G cleanup
```
Memory read and write TEST C
```
sysbench --test=memory run --memory-total-size=2G
sysbench --test=memory run --memory-total-size=2G --memory-oper=read
```


DEVICE      | A         | B1                                        | B2        | B3 | C        | Notes
CM4 32b     | 10.0153s  | 2147483648 bytes written in 51.98 seconds | 300.0833s |    | 4.2299s  | Running Bulleye 32bit, latest everything




# bullseye notes:
camera_app/
├── app.py
├── camera/
│   ├── __init__.py
│   ├── camera.py
│   ├── capture.py
│   ├── video.py
│   └── timelapse.py
├── web_interface/
│   ├── __init__.py
│   ├── server.py
│   ├── routes.py
│   ├── templates/
│   │   ├── index.html
│   │   ├── project_gallery.html
│   │   ├── edit_project.html
│   │   └── ...
│   └── static/
│       ├── css/
│       ├── js/
│       └── ...
├── web_server/
│   ├── __init__.py
│   ├── wifi.py
│   └── ...
└── utils/
    ├── __init__.py
    ├── conversions.py
    ├── shell_commands.py
    └── ...


# # focus testing:
 range: 15 > 2.75 ( 0  = theoretical infinate)
 - --lens-position 15 = MACRO (7.5cm)
 - --lens-position 10 = MACRO (10cm)
 - --lens-position 4.5 = Arms length
 - --lens-position 2.75 = INFINATE


## install dependencies:
sudo apt install -y python3-pyqt5 python3-opengl

pip install opencv-python
pip3 install opencv-python
pip3 install simplejpeg

sudo apt install -y libimage-exiftool-perl


sudo setcap 'cap_net_bind_service=+ep' /usr/bin/python3.9

# remote storage process
# # see https://raspberrytips.com/mount-usb-drive-raspberry-pi/

### mount USB:
usbmount
### unmount USB:
sudo umount /mnt/usb
### test if mounted
ls -latr /mnt/usb

add video=HDMI-A-1:1920x1080@60D to sudo /boot/cmdline.txt

# watchdog related:
https://diode.io/blog/running-forever-with-the-raspberry-pi-hardware-watchdog

# simple camera utils in SHELL
libcamera-jpeg -o FirstPhoto.jpg

libcamera-jpeg -o manual_lens_00000.jpg -t 1 --autofocus-mode manual --lens-position 0
libcamera-jpeg -o manual_lens_00025.jpg -t 1 --autofocus-mode manual --lens-position 0.25
libcamera-jpeg -o manual_lens_00050.jpg -t 1 --autofocus-mode manual --lens-position 0.5
libcamera-jpeg -o manual_lens_00075.jpg -t 1 --autofocus-mode manual --lens-position 0.75
libcamera-jpeg -o manual_lens_00125.jpg -t 1 --autofocus-mode manual --lens-position 1.25
libcamera-jpeg -o manual_lens_00150.jpg -t 1 --autofocus-mode manual --lens-position 1.5
libcamera-jpeg -o manual_lens_00175.jpg -t 1 --autofocus-mode manual --lens-position 1.75
libcamera-jpeg -o manual_lens_00200.jpg -t 1 --autofocus-mode manual --lens-position 2
libcamera-jpeg -o manual_lens_00225.jpg -t 1 --autofocus-mode manual --lens-position 2.25
libcamera-jpeg -o manual_lens_00250.jpg -t 1 --autofocus-mode manual --lens-position 2.5
libcamera-jpeg -o manual_lens_00275.jpg -t 1 --autofocus-mode manual --lens-position 2.75
libcamera-jpeg -o manual_lens_00300.jpg -t 1 --autofocus-mode manual --lens-position 3
libcamera-jpeg -o manual_lens_00325.jpg -t 1 --autofocus-mode manual --lens-position 3.25
libcamera-jpeg -o manual_lens_00350.jpg -t 1 --autofocus-mode manual --lens-position 3.5
libcamera-jpeg -o manual_lens_00375.jpg -t 1 --autofocus-mode manual --lens-position 3.75
libcamera-jpeg -o manual_lens_00400.jpg -t 1 --autofocus-mode manual --lens-position 4
libcamera-jpeg -o manual_lens_00425.jpg -t 1 --autofocus-mode manual --lens-position 4.25
libcamera-jpeg -o manual_lens_00450.jpg -t 1 --autofocus-mode manual --lens-position 4.5
libcamera-jpeg -o manual_lens_00475.jpg -t 1 --autofocus-mode manual --lens-position 4.75
libcamera-jpeg -o manual_lens_00500.jpg -t 1 --autofocus-mode manual --lens-position 5
libcamera-jpeg -o manual_lens_00525.jpg -t 1 --autofocus-mode manual --lens-position 5.25
libcamera-jpeg -o manual_lens_00550.jpg -t 1 --autofocus-mode manual --lens-position 5.5
libcamera-jpeg -o manual_lens_00575.jpg -t 1 --autofocus-mode manual --lens-position 5.75
libcamera-jpeg -o manual_lens_00600.jpg -t 1 --autofocus-mode manual --lens-position 6
libcamera-jpeg -o manual_lens_00625.jpg -t 1 --autofocus-mode manual --lens-position 6.25
libcamera-jpeg -o manual_lens_00650.jpg -t 1 --autofocus-mode manual --lens-position 6.5
libcamera-jpeg -o manual_lens_00675.jpg -t 1 --autofocus-mode manual --lens-position 6.75
libcamera-jpeg -o manual_lens_00700.jpg -t 1 --autofocus-mode manual --lens-position 7
libcamera-jpeg -o manual_lens_00725.jpg -t 1 --autofocus-mode manual --lens-position 7.25
libcamera-jpeg -o manual_lens_00750.jpg -t 1 --autofocus-mode manual --lens-position 7.5
libcamera-jpeg -o manual_lens_00775.jpg -t 1 --autofocus-mode manual --lens-position 7.75
libcamera-jpeg -o manual_lens_00800.jpg -t 1 --autofocus-mode manual --lens-position 8
libcamera-jpeg -o manual_lens_00900.jpg -t 1 --autofocus-mode manual --lens-position 9
libcamera-jpeg -o manual_lens_01000.jpg -t 1 --autofocus-mode manual --lens-position 10



libcamera-jpeg -o manual_lens_50.jpg -t 1 --autofocus-mode manual --lens-position 50
libcamera-jpeg -o manual_lens_40.jpg -t 1 --autofocus-mode manual --lens-position 40
libcamera-jpeg -o manual_lens_30.jpg -t 1 --autofocus-mode manual --lens-position 30
libcamera-jpeg -o manual_lens_20.jpg -t 1 --autofocus-mode manual --lens-position 20
libcamera-jpeg -o manual_lens_18.jpg -t 1 --autofocus-mode manual --lens-position 18
libcamera-jpeg -o manual_lens_16.jpg -t 1 --autofocus-mode manual --lens-position 16
libcamera-jpeg -o manual_lens_15.jpg -t 1 --autofocus-mode manual --lens-position 15
libcamera-jpeg -o manual_lens_14.jpg -t 1 --autofocus-mode manual --lens-position 14
libcamera-jpeg -o manual_lens_13.jpg -t 1 --autofocus-mode manual --lens-position 13
libcamera-jpeg -o manual_lens_12.jpg -t 1 --autofocus-mode manual --lens-position 12
libcamera-jpeg -o manual_lens_11.jpg -t 1 --autofocus-mode manual --lens-position 11
libcamera-jpeg -o manual_lens_10.jpg -t 1 --autofocus-mode manual --lens-position 10
libcamera-jpeg -o manual_lens_9.5.jpg -t 1 --autofocus-mode manual --lens-position 9.5
libcamera-jpeg -o manual_lens_9.jpg -t 1 --autofocus-mode manual --lens-position 9
libcamera-jpeg -o manual_lens_8.5.jpg -t 1 --autofocus-mode manual --lens-position 8.5
libcamera-jpeg -o manual_lens_7.jpg -t 1 --autofocus-mode manual --lens-position 7
libcamera-jpeg -o manual_lens_6.5.jpg -t 1 --autofocus-mode manual --lens-position 6.5
libcamera-jpeg -o manual_lens_6.jpg -t 1 --autofocus-mode manual --lens-position 6
libcamera-jpeg -o manual_lens_5.5.jpg -t 1 --autofocus-mode manual --lens-position 5.5
libcamera-jpeg -o manual_lens_5.jpg -t 1 --autofocus-mode manual --lens-position 5
libcamera-jpeg -o manual_lens_4.5.jpg -t 1 --autofocus-mode manual --lens-position 4.5
libcamera-jpeg -o manual_lens_4.jpg -t 1 --autofocus-mode manual --lens-position 4
libcamera-jpeg -o manual_lens_3.5.jpg -t 1 --autofocus-mode manual --lens-position 3.5
libcamera-jpeg -o manual_lens_3.jpg -t 1 --autofocus-mode manual --lens-position 3
libcamera-jpeg -o manual_lens_2.75.jpg -t 1 --autofocus-mode manual --lens-position 2.75



# MacOS testing:
Need to download the picamera2 and add to python
https://github.com/raspberrypi/picamera2 (picamera2 folder)
/opt/homebrew/lib/python3.11/site-packages


sshfs steven@z2c3.local:/home/steven/letslapse/ ~/z2c3

pip3 install piexif
pip3 install pidng


libcamera
git clone https://git.libcamera.org/libcamera/libcamera.git

Also add pi Python libs from device to mac site-packages folder
/usr/lib/python3/dist-packages/libcamera 
  ( zip -r /home/steven/letslapse/libcamera.zip libcamera )
  zip -r /home/steven/letslapse/pidng.zip pidng



# mounting homenetwork USB NAS
 - Requires a NAS drive
sudo apt install samba-common samba-common-bin smbclient cifs-utils
sudo mkdir /mnt/nas
sudo nano ~/.smbcreds
 - username= /n password=
sudo chmod 600 ~/.smbcreds 
sudo pico /etc/fstab 
//192.168.1.1/kingston-datatraveler3.0-kingston /mnt/nas cifs credentials=/home/steven/.smbcreds 0 0