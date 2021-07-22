#copy wpa_supplication.conf to /boot & touch ssh

#prep work requires git, bc, a few other tools if not found
# sudo apt install bc
# sudo apt install git

#1 git clone https://github.com/regularsteven/letslapse.git
#2 sudo sh install.sh 

echo "----------Pi System Stuff-----------------"
echo "1 Getting system UPDATE and UPGRADE"
sudo apt-get update -y && sudo apt-get upgrade -y

echo "----------Dependencies for Python-----------------"
echo "2 Setting up Python and PIP"
#python related dependencies
sudo apt install python3-pip

echo "3 Camera Stuff"
#camera stuff
sudo apt-get install python-picamera python3-picamera -y

echo "4 Numpy"
#numpy and dependencies
sudo apt-get install libatlas-base-dev
python3 -m pip install numpy
echo "5 Pillow"
python3 -m pip install Pillow

echo "6 OpenCV and dependencies"
#OpenCV and dependencies
sudo apt install libtiff5
sudo apt install libwebp-dev
sudo apt install libopenjp2-7
sudo apt install libIlmImf-2_2-23
sudo apt install libgstreamer1.0-dev
sudo apt-get install libopenexr-dev
sudo apt-get install python-opencv
python3 -m pip install opencv-python

#exif and ffmpeg tools
sudo apt install -y ffmpeg
sudo apt install -y libimage-exiftool-perl

echo "7 piexif"
pip3 install piexif

echo "----------Settingh up WiFi Hosting-----------------"
echo "8 Install hostapd"
sudo apt-get install hostapd
echo "9 Install hostapd"
sudo apt-get install dnsmasq
echo "10 Unmask and disable services"
sudo systemctl unmask hostapd
sudo systemctl disable hostapd
sudo systemctl disable dnsmasq

echo "11 Copy hostapd.conf"
sudo cp install/hostapd.conf /etc/hostapd/
echo "12 Updating /etc/default/hostapd"
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd
echo "13 Updating /etc/dnsmasq.conf"
echo '#AutoHotspot Config' | sudo tee -a /etc/dnsmasq.conf
echo '#stop DNSmasq from using resolv.conf' | sudo tee -a /etc/dnsmasq.conf
echo 'no-resolv' | sudo tee -a /etc/dnsmasq.conf
echo '#Interface to use' | sudo tee -a /etc/dnsmasq.conf
echo 'interface=wlan0' | sudo tee -a /etc/dnsmasq.conf
echo 'bind-interfaces' | sudo tee -a /etc/dnsmasq.conf
echo 'dhcp-range=10.0.0.50,10.0.0.150,12h' | sudo tee -a /etc/dnsmasq.conf
echo "-------------------------------------"
echo "14 Updating /etc/dnsmasq.conf"

echo 'nohook wpa_supplicant' | sudo tee -a /etc/dhcpcd.conf
echo "15 Copy autohotspot.service"
sudo cp install/autohotspot.service /etc/systemd/system/
echo "16 Starting autohotspot.service"
sudo systemctl enable autohotspot.service
echo "17 Copy autohotspot script"
sudo cp install/autohotspot /usr/bin/
echo "18 Make autohotspot script executable"
sudo chmod +x /usr/bin/autohotspot
echo "-------------------------------------"

echo "19 System Stuff - Enable Camera / Disable Bluetooth - Updating /etc/default/hostapd"
echo 'start_x=1' | sudo tee -a /boot/config.txt
echo 'gpu_mem=128' | sudo tee -a /boot/config.txt
echo 'dtoverlay=disable-bt' | sudo tee -a /boot/config.txt
echo 'disable_camera_led=1' | sudo tee -a /boot/config.txt

#ideally disable HDMI - need to add this before exit 0 though, not at the end
#echo '/usr/bin/tvservice -o' | sudo tee -a /etc/rc.local

echo "16 Copy letslapse.service"
sudo cp install/letslapse.service /etc/systemd/system/
sudo chmod u+rw /etc/systemd/system/letslapse.service
echo "11 Starting and enable letslapse.service"
sudo systemctl enable letslapse.service
sudo systemctl start letslapse.service
echo "See the following logs for further detail:"
echo "tail -f /var/log/syslog for error messages"
echo ""

#echo "16 Start server on boot - Updating /etc/default/hostapd"
#echo 'sudo python3 /home/pi/letslapse/letslapse_server.py' | sudo tee -a /etc/profile
#initially considered loading the streamer on start-up, but this adds overhead and should only be called when required
#echo 'sudo python3 /home/pi/letslapse/streamer.py' | sudo tee -a /etc/profile

python3 install/verify.py

echo "Finished. On reboot, if no network is found, a hotspot will be created."

echo "In some instances, crashes will take place. Try "
echo "sudo rpi-update"



