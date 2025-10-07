#!/bin/bash
# filepath: ninja.sh

set -e

# Configuration
DOMAIN="invoicing.insmallusa.com"
DB_DATABASE="i9429759_fnn91"
DB_USERNAME="i9429759_fnn91"
DB_PASSWORD="F.mjndREY1MWNkbZvbo30"
PDF_GENERATOR="hosted_ninja"
INSTALL_DIR="/var/www/invoiceninja"
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)

echo "=========================================="
echo "Invoice Ninja Installation Script"
echo "=========================================="
echo ""

# Update system
echo "[1/12] Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "[2/12] Installing required packages..."
apt install -y software-properties-common curl wget git unzip nginx mysql-server \
    php8.1-fpm php8.1-cli php8.1-mysql php8.1-gd php8.1-mbstring php8.1-curl \
    php8.1-xml php8.1-zip php8.1-bcmath php8.1-intl php8.1-gmp php8.1-imagick \
    certbot python3-certbot-nginx

# Secure MySQL installation
echo "[3/12] Configuring MySQL..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

# Create database and user
echo "[4/12] Creating database and user..."
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Install Composer
echo "[5/12] Installing Composer..."
cd /tmp
curl -sS https://getcomposer.org/installer -o composer-setup.php
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

# Clone Invoice Ninja
echo "[6/12] Downloading Invoice Ninja..."
rm -rf ${INSTALL_DIR}
git clone --depth 1 https://github.com/invoiceninja/invoiceninja.git ${INSTALL_DIR}
cd ${INSTALL_DIR}

# Install dependencies
echo "[7/12] Installing Invoice Ninja dependencies..."
composer install --no-dev --optimize-autoloader

# Configure environment
echo "[8/12] Configuring Invoice Ninja..."
cp .env.example .env

# Generate application key
APP_KEY=$(php artisan key:generate --show)

# Update .env file
cat > .env <<ENV_FILE
APP_NAME="Invoice Ninja"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=https://${DOMAIN}

LOG_CHANNEL=stack

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

BROADCAST_DRIVER=log
CACHE_DRIVER=file
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_HOST=localhost
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS=noreply@${DOMAIN}
MAIL_FROM_NAME="\${APP_NAME}"

PDF_GENERATOR=${PDF_GENERATOR}

REQUIRE_HTTPS=true
ENV_FILE

# Set permissions
echo "[9/12] Setting permissions..."
chown -R www-data:www-data ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache

# Run migrations
echo "[10/12] Running database migrations..."
cd ${INSTALL_DIR}
sudo -u www-data php artisan migrate --force --seed

# Configure Nginx
echo "[11/12] Configuring Nginx..."
cat > /etc/nginx/sites-available/invoiceninja <<NGINX_CONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${INSTALL_DIR}/public;

    index index.php index.html index.htm;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    client_max_body_size 100M;
}
NGINX_CONF

# Enable site
ln -sf /etc/nginx/sites-available/invoiceninja /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test and restart Nginx
nginx -t
systemctl restart nginx

# Setup SSL with Let's Encrypt
echo "[12/12] Setting up SSL certificate..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect

# Final optimization
cd ${INSTALL_DIR}
sudo -u www-data php artisan optimize
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache

# Setup cron for scheduled tasks
(crontab -l 2>/dev/null; echo "* * * * * cd ${INSTALL_DIR} && php artisan schedule:run >> /dev/null 2>&1") | crontab -

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Invoice Ninja URL: https://${DOMAIN}"
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo ""
echo "Database Details:"
echo "  Database: ${DB_DATABASE}"
echo "  Username: ${DB_USERNAME}"
echo "  Password: ${DB_PASSWORD}"
echo ""
echo "IMPORTANT: Save the MySQL root password above!"
echo "Please visit https://${DOMAIN} to complete the setup."
echo ""
echo "Default admin credentials will be created during first setup."
echo "=========================================="
