#!/bin/bash

# Ensure root
if [[ $EUID -ne 0 ]]; then
   echo "Run as root!"
   exit 1
fi

GREEN='\033[0;32m'
NC='\033[0m'

# Install dialog if missing
apt update
apt install dialog git curl wget mariadb-server nginx certbot python3-certbot-nginx -y

# Functions for dialog input
function input_text() {
    exec 3>&1
    TEXT=$(dialog --inputbox "$1" 8 50 2>&1 1>&3)
    exec 3>&-
    echo "$TEXT"
}

function input_pass() {
    exec 3>&1
    PASS=$(dialog --insecure --passwordbox "$1" 8 50 2>&1 1>&3)
    exec 3>&-
    echo "$PASS"
}

function select_menu() {
    exec 3>&1
    CHOICE=$(dialog --menu "$1" 15 50 4 "${@:2}" 2>&1 1>&3)
    exec 3>&-
    echo "$CHOICE"
}

# Clear screen before starting
clear

# Step 1: Domain
DOMAIN=$(input_text "Enter your domain name (leave blank for no domain):")

# Step 2: SSL
SSL_OPTION=$(select_menu "Enable SSL?" 1 "Yes" 2 "No")

# Step 3: Database passwords
DB_ROOT_PASS=$(input_pass "Enter MySQL root password:")
GITEA_DB_PASS=$(input_pass "Enter Gitea DB password:")

# Step 4: Confirm
dialog --yesno "Ready to install Gitea with the following settings?\n\nDomain: $DOMAIN\nSSL: $SSL_OPTION" 12 60
if [[ $? -ne 0 ]]; then
    clear
    echo "Installation cancelled."
    exit 0
fi

clear
echo -e "${GREEN}Starting Gitea installation...${NC}"

# Step 5: Create Gitea user
echo -e "${GREEN}Creating Gitea system user...${NC}"
adduser --system --shell /bin/bash --gecos 'Gitea' --group --disabled-password --home /home/git git

# Step 6: Secure MariaDB
echo -e "${GREEN}Securing MariaDB...${NC}"
mysql_secure_installation

# Step 7: Create Gitea database
echo -e "${GREEN}Creating Gitea database...${NC}"
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE gitea CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_unicode_ci';
CREATE USER 'gitea'@'localhost' IDENTIFIED BY '$GITEA_DB_PASS';
GRANT ALL PRIVILEGES ON gitea.* TO 'gitea'@'localhost';
FLUSH PRIVILEGES;
EXIT;
MYSQL_SCRIPT

# Step 8: Install Gitea binary
echo -e "${GREEN}Installing Gitea binary...${NC}"
wget -O /usr/local/bin/gitea https://dl.gitea.io/gitea/1.24.5/gitea-1.24.5-linux-amd64
chmod +x /usr/local/bin/gitea

# Step 9: Directories & permissions
echo -e "${GREEN}Setting directories & permissions...${NC}"
mkdir -p /var/lib/gitea/{custom,data,log}
chown -R git:git /var/lib/gitea/
chmod -R 750 /var/lib/gitea
mkdir /etc/gitea
chown root:git /etc/gitea
chmod 770 /etc/gitea

# Step 10: Create systemd service
echo -e "${GREEN}Creating systemd service...${NC}"
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

# Step 11: Nginx setup if domain provided
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
echo "Visit http://$DOMAIN:3000 or your server IP to finish web setup."
