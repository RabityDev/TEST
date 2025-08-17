#!/bin/bash

# Ensure root
if [[ $EUID -ne 0 ]]; then
   echo "Run as root!"
   exit 1
fi

GREEN='\033[0;32m'
NC='\033[0m'

# Functions
function input_password() {
    PASSWORD=$(whiptail --passwordbox "$1" 8 60 3>&1 1>&2 2>&3)
    echo "$PASSWORD"
}

function input_text() {
    TEXT=$(whiptail --inputbox "$1" 8 60 3>&1 1>&2 2>&3)
    echo "$TEXT"
}

function confirm_menu() {
    OPTION=$(whiptail --title "$1" --menu "$2" 15 60 4 \
    "1" "$3" \
    "2" "$4" 3>&1 1>&2 2>&3)
    echo "$OPTION"
}

# Main installer

# Step 1: Domain choice
DOMAIN=$(input_text "Enter your domain name (leave blank for no domain):")

# Step 2: SSL choice
SSL_OPTION=$(whiptail --title "SSL Option" --menu "Do you want SSL with Let's Encrypt?" 10 60 2 \
1 "Yes, enable SSL" \
2 "No, skip SSL" 3>&1 1>&2 2>&3)

# Step 3: Database passwords
DB_ROOT_PASS=$(input_password "Enter MySQL root password:")
GITEA_DB_PASS=$(input_password "Enter password for Gitea database user:")

# Step 4: Confirm installation
INSTALL_CONFIRM=$(whiptail --title "Confirmation" --yesno "Ready to install Gitea with the above settings?\nDomain: $DOMAIN\nSSL: $SSL_OPTION" 12 60 3>&1 1>&2 2>&3)
if [[ $? -ne 0 ]]; then
    echo "Installation canceled."
    exit 0
fi

# Step 5: System update & dependencies
echo -e "${GREEN}Updating system and installing dependencies...${NC}"
apt update && apt upgrade -y
apt install git curl wget mariadb-server nginx certbot python3-certbot-nginx whiptail -y

# Step 6: Create Gitea user
echo -e "${GREEN}Creating Gitea user...${NC}"
adduser --system --shell /bin/bash --gecos 'Gitea' --group --disabled-password --home /home/git git

# Step 7: Secure MariaDB
echo -e "${GREEN}Securing MariaDB...${NC}"
mysql_secure_installation

# Step 8: Create Gitea database
echo -e "${GREEN}Creating Gitea database...${NC}"
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE gitea CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_unicode_ci';
CREATE USER 'gitea'@'localhost' IDENTIFIED BY '$GITEA_DB_PASS';
GRANT ALL PRIVILEGES ON gitea.* TO 'gitea'@'localhost';
FLUSH PRIVILEGES;
EXIT;
MYSQL_SCRIPT

# Step 9: Install Gitea binary
echo -e "${GREEN}Installing Gitea...${NC}"
wget -O /usr/local/bin/gitea https://dl.gitea.io/gitea/1.24.5/gitea-1.24.5-linux-amd64
chmod +x /usr/local/bin/gitea

# Step 10: Directories & permissions
echo -e "${GREEN}Setting directories & permissions...${NC}"
mkdir -p /var/lib/gitea/{custom,data,log}
chown -R git:git /var/lib/gitea/
chmod -R 750 /var/lib/gitea
mkdir /etc/gitea
chown root:git /etc/gitea
chmod 770 /etc/gitea

# Step 11: Create systemd service
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

# Step 12: Nginx config if domain provided
if [[ -n "$DOMAIN" ]]; then
    echo -e "${GREEN}Configuring Nginx...${NC}"
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

    if [[ "$SSL_OPTION" == "1" ]]; then
        echo -e "${GREEN}Installing SSL with Certbot...${NC}"
        certbot --nginx -d "$DOMAIN"
    fi
fi

echo -e "${GREEN}Gitea installation completed!${NC}"
echo "Visit http://$DOMAIN:3000 or your server IP to complete web setup."
