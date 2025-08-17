#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

GREEN='\033[0;32m'
NC='\033[0m'

DOMAIN=$(whiptail --inputbox "Enter your domain name (leave blank if none):" 8 60 3>&1 1>&2 2>&3)

whiptail --yesno "Do you want to enable SSL with Let's Encrypt?" 8 60
SSL_CHOICE=$?

DB_ROOT_PASS=$(whiptail --passwordbox "Enter MySQL root password:" 8 60 3>&1 1>&2 2>&3)

GITEA_DB_PASS=$(whiptail --passwordbox "Enter password for Gitea database user:" 8 60 3>&1 1>&2 2>&3)

echo -e "${GREEN}Updating system and installing dependencies...${NC}"
apt update && apt upgrade -y
apt install git curl wget mariadb-server nginx certbot python3-certbot-nginx -y

echo -e "${GREEN}Creating Gitea system user...${NC}"
adduser --system --shell /bin/bash --gecos 'Gitea' --group --disabled-password --home /home/git git

echo -e "${GREEN}Securing MariaDB...${NC}"
mysql_secure_installation

echo -e "${GREEN}Creating Gitea database...${NC}"
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE gitea CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_unicode_ci';
CREATE USER 'gitea'@'localhost' IDENTIFIED BY '$GITEA_DB_PASS';
GRANT ALL PRIVILEGES ON gitea.* TO 'gitea'@'localhost';
FLUSH PRIVILEGES;
EXIT;
MYSQL_SCRIPT

echo -e "${GREEN}Installing Gitea...${NC}"
wget -O /usr/local/bin/gitea https://dl.gitea.io/gitea/1.24.5/gitea-1.24.5-linux-amd64
chmod +x /usr/local/bin/gitea

echo -e "${GREEN}Setting up directories and permissions...${NC}"
mkdir -p /var/lib/gitea/{custom,data,log}
chown -R git:git /var/lib/gitea/
chmod -R 750 /var/lib/gitea
mkdir /etc/gitea
chown root:git /etc/gitea
chmod 770 /etc/gitea

echo -e "${GREEN}Creating systemd service for Gitea...${NC}"
cat <<EOF > /etc/systemd/system/gitea.service
[Unit]
Description=Gitea
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gitea
systemctl start gitea
systemctl status gitea

if [[ -n "$DOMAIN" ]]; then
    echo -e "${GREEN}Setting up Nginx for Gitea...${NC}"
    cat <<EOF > /etc/nginx/sites-available/gitea
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    ln -s /etc/nginx/sites-available/gitea /etc/nginx/sites-enabled/
    systemctl restart nginx

    if [[ $SSL_CHOICE -eq 0 ]]; then
        echo -e "${GREEN}Installing SSL with Certbot...${NC}"
        certbot --nginx -d "$DOMAIN"
    fi
fi

echo -e "${GREEN}Gitea installation completed!${NC}"
echo "Open your browser and finish web setup at: http://$DOMAIN:3000 (or your server IP if no domain)"
