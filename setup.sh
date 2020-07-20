#!/bin/bash
# Looker setup script for Ubuntu 18.04 Bionic Beaver on AWS

# Install required packages
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install libssl-dev -y
sudo apt-get install cifs-utils -y
sudo apt-get install fonts-freefont-otf -y
sudo apt-get install chromium-browser -y
sudo ln -s /usr/bin/chromium-browser /usr/bin/chromium
sudo apt-get install openjdk-8-jdk -y
sudo apt-get install nfs-common -y
sudo apt-get install jq -y

# Install the Looker systemd startup script
curl https://raw.githubusercontent.com/JCPistell/customer-scripts/master/startup_scripts/systemd/looker.service -O
sudo mv looker.service /etc/systemd/system/looker.service
sudo chmod 664 /etc/systemd/system/looker.service

# Install the Prom JMX systemd startup script
curl https://raw.githubusercontent.com/JCPistell/customer-scripts/master/startup_scripts/systemd/prom-jmx.service -O
sudo mv prom-jmx.service /etc/systemd/system/prom-jmx.service
sudo chmod 664 /etc/systemd/system/prom-jmx.service


# Configure some important environment settings
cat <<EOT | sudo tee -a /etc/sysctl.conf
net.ipv4.tcp_keepalive_time=200
net.ipv4.tcp_keepalive_intvl=200
net.ipv4.tcp_keepalive_probes=5
EOT

cat <<EOT | sudo tee -a /etc/security/limits.conf
looker     soft     nofile     4096
looker     hard     nofile     4096
EOT

# Configure user and group permissions
sudo groupadd looker
sudo useradd -m -g looker looker
sudo mkdir /home/looker/looker
sudo chown looker:looker /home/looker/looker
cd /home/looker/looker

# Download and install Looker
sudo curl -s -i -X POST -H 'Content-Type:application/json' -d "{\"lic\": \"$LOOKER_LICENSE_KEY\", \"email\": \"$LOOKER_TECHNICAL_CONTACT_EMAIL\", \"latest\":\"latest\"}" https://apidownload.looker.com/download -o /home/looker/looker/response.txt
sudo sed -i 1,9d response.txt
sudo chmod 777 response.txt
eula=$(cat response.txt | jq -r '.eulaMessage')
if [[ "$eula" =~ .*EULA.* ]]; then echo "Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form."; fi;
url=$(cat response.txt | jq -r '.url')
sudo curl $url -o /home/looker/looker/looker.jar

url=$(cat response.txt | jq -r '.depUrl')
sudo curl $url -o /home/looker/looker/looker-dependencies.jar

cat <<EOT | sudo tee -a /home/looker/looker/provision.yml
license_key: "$LOOKER_LICENSE_KEY"
host_url: "https://$HOST_URL:9999"
user:
  first_name: "Colin"
  last_name: "Pistell"
  email: "$LOOKER_TECHNICAL_CONTACT_EMAIL"
  password: "$LOOKER_PASSWORD"
EOT

# download the prometheus jmx http server and config file
sudo curl https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_httpserver/0.13.0/jmx_prometheus_httpserver-0.13.0-jar-with-dependencies.jar -o jmx_prometheus_httpserver.jar
sudo curl https://raw.githubusercontent.com/JCPistell/customer-scripts/master/prometheus/looker_jmx.yml -O

# update config file with credentials
sudo sed -i -e "s/\[PASSWORD\]/$LOOKER_PASSWORD/g" looker_jmx.yml

# change permissions appropriately
sudo chown looker:looker /home/looker/looker/jmx_prometheus_httpserver.jar
sudo chown looker:looker /home/looker/looker/looker_jmx.yml

# setting up the JMX directory
sudo mkdir /home/looker/.lookerjmx

cat << EOT | sudo tee -a /home/looker/.lookerjmx/jmxremote.access
monitorRole    readonly
controlRole    readwrite \
               create javax.management.monitor.*,javax.management.timer.* \
               unregister
EOT

cat << EOT | sudo tee -a /home/looker/.lookerjmx/jmxremote.password
monitorRole    $LOOKER_PASSWORD
controlRole    $LOOKER_PASSWORD
EOT

sudo chown -R looker:looker /home/looker/.lookerjmx
sudo chmod 400 /home/looker/.lookerjmx/jmxremote.*

# Looker won't automatically create the deploy_keys directory
sudo mkdir /home/looker/looker/deploy_keys

echo "LOOKERARGS=\"\"" | sudo tee -a /home/looker/looker/lookerstart.cfg

sudo chown -R looker:looker lookerstart.cfg looker.jar looker-dependencies.jar provision.yml deploy_keys

# download the startup scripts
sudo curl https://raw.githubusercontent.com/JCPistell/customer-scripts/master/startup_scripts/looker -O
sudo curl https://raw.githubusercontent.com/JCPistell/customer-scripts/master/startup_scripts/prom-jmx -O
sudo chmod 0750 looker
sudo chmod 0750 prom-jmx

sudo chown looker:looker looker prom-jmx

# Start Looker
sudo systemctl daemon-reload
sudo systemctl enable looker.service
sudo systemctl enable prom-jmx.service
sudo systemctl start looker
sleep 10
sudo systemctl start prom-jmx
