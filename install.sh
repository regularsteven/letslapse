#copy wpa_supplication.conf to /boot & touch ssh
#1 git clone https://github.com/regularsteven/letslapse.git
#2 sudo sh install.sh 

echo "1 Running updates"
sudo apt-get update
echo "2 Running upgrades"
sudo apt-get upgrade
echo "-------------------------------------"
echo "3 Install hostapd"
sudo apt-get install hostapd
echo "4 Install hostapd"
sudo apt-get install dnsmasq
echo "5 Unmask and disable services"
sudo systemctl unmask hostapd

sudo systemctl disable hostapd
sudo systemctl disable dnsmasq
echo "6 Copy hostapd.conf"
sudo cp install/hostapd.conf /etc/hostapd/
echo "7 Updating /etc/default/hostapd"
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd
echo "8 Updating /etc/dnsmasq.conf"
echo '#AutoHotspot Config' | sudo tee -a /etc/dnsmasq.conf
echo '#stop DNSmasq from using resolv.conf' | sudo tee -a /etc/dnsmasq.conf
echo 'no-resolv' | sudo tee -a /etc/dnsmasq.conf
echo '#Interface to use' | sudo tee -a /etc/dnsmasq.conf
echo 'interface=wlan0' | sudo tee -a /etc/dnsmasq.conf
echo 'bind-interfaces' | sudo tee -a /etc/dnsmasq.conf
echo 'dhcp-range=10.0.0.50,10.0.0.150,12h' | sudo tee -a /etc/dnsmasq.conf
echo "-------------------------------------"
echo "9 Updating /etc/dnsmasq.conf"

echo 'nohook wpa_supplicant' | sudo tee -a /etc/dhcpcd.conf
echo "10 Copy autohotspot.service"
sudo cp install/autohotspot.service /etc/systemd/system/
echo "11 Starting autohotspot.service"
sudo systemctl enable autohotspot.service
echo "12 Copy autohotspot script"
sudo cp install/autohotspot /usr/bin/
echo "13 Make autohotspot script executable"
sudo chmod +x /usr/bin/autohotspot
echo "-------------------------------------"
echo "14 installing python dependencies"
sudo apt install python3-pip
python3 -m pip install --upgrade pip
python3 -m pip install --upgrade Pillow
echo "15 System Stuff - Enable Camera / Disable Bluetooth - Updating /etc/default/hostapd"
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
echo "See /var/log/syslog for error messages"

#echo "16 Start server on boot - Updating /etc/default/hostapd"
#echo 'sudo python3 /home/pi/letslapse/letslapse_server.py' | sudo tee -a /etc/profile
#initially considered loading the streamer on start-up, but this adds overhead and should only be called when required
#echo 'sudo python3 /home/pi/letslapse/streamer.py' | sudo tee -a /etc/profile


echo "Finished. On reboot, if no network is found, a hotspot will be created."

echo "In some instances, crashes will take place. Try "
echo "sudo rpi-update"



