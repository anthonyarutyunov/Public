#!/bin/bash
# filepath: install_invoiceninja.sh

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
echo "Invoice Ninja v5 Installation Script"
echo "=========================================="
echo ""

# Update system
echo "[1/14] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install basic dependencies
echo "[2/14] Installing basic dependencies..."
apt-get install -y software-properties-common curl wget git unzip expect

# Add PHP repository
echo "[3/14] Adding PHP 8.2 repository..."
add-apt-repository ppa:ondrej/php -y
apt-get update

# Install PHP 8.2 and extensions
echo "[4/14] Installing PHP 8.2 and required extensions..."
apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring \
    php8.2-xml php8.2-curl php8.2-zip php8.2-gd php8.2-bcmath php8.2-intl \
    php8.2-gmp php8.2-soap

# Install MySQL without password prompt
echo "[5/14] Installing MySQL..."
debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASSWORD}"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASSWORD}"
apt-get install -y mysql-server

# Start MySQL
systemctl start mysql
systemctl enable mysql
sleep 3

echo "[6/14] Configuring MySQL and creating database..."

# Use expect to handle mysql_secure_installation
expect <<EOF
spawn mysql_secure_installation
expect "Enter password for user root:"
send "${MYSQL_ROOT_PASSWORD}\r"
expect "Change the password for root ?"
send "n\r"
expect "Remove anonymous users?"
send "y\r"
expect "Disallow root login remotely?"
send "y\r"
expect "Remove test database and access to it?"
send "y\r"
expect "Reload privilege tables now?"
send "y\r"
expect eof
EOF

# Now create database and user
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<MYSQL_SCRIPT
DROP DATABASE IF EXISTS ${DB_DATABASE};
CREATE DATABASE ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USERNAME}'@'localhost';
CREATE USER '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "MySQL configured successfully!"

# Install Composer
echo "[7/14] Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Download Invoice Ninja
echo "[8/14] Downloading Invoice Ninja v5..."
mkdir -p /var/www
cd /var/www
rm -rf invoiceninja invoiceninja.tar

wget --quiet --show-progress https://github.com/invoiceninja/invoiceninja/releases/latest/download/invoiceninja.tar
tar -xf invoiceninja.tar
rm invoiceninja.tar

if [ ! -d "${INSTALL_DIR}" ]; then
    echo "ERROR: Installation directory was not created"
    exit 1
fi

# Configure Invoice Ninja
echo "[9/14] Configuring Invoice Ninja..."
cd ${INSTALL_DIR}

cat > .env <<ENV_FILE
APP_NAME="Invoice Ninja"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=https://${DOMAIN}

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD="${DB_PASSWORD}"

BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DISK=public
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

MAIL_MAILER=log

PDF_GENERATOR=${PDF_GENERATOR}

REQUIRE_HTTPS=true
ENV_FILE

# Generate key
php artisan key:generate --no-interaction --force

# Set permissions
echo "[10/14] Setting permissions..."
chown -R www-data:www-data ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache

# Run migrations
echo "[11/14] Running database migrations..."
php artisan migrate --force --seed

# Install Nginx
echo "[12/14] Installing Nginx..."
apt-get install -y nginx

cat > /etc/nginx/sites-available/invoiceninja.conf <<'NGINX_CONFIG'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    root /var/www/invoiceninja/public;
    index index.php index.html;
    client_max_body_size 20M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX_CONFIG

sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/invoiceninja.conf

ln -sf /etc/nginx/sites-available/invoiceninja.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx

# SSL
echo "[13/14] Setting up SSL..."
apt-get install -y certbot python3-certbot-nginx

certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect || echo "SSL failed - continue with http://${DOMAIN}"

# Cron
echo "[14/14] Setting up cron..."
(crontab -l 2>/dev/null | grep -v invoiceninja; echo "* * * * * cd /var/www/invoiceninja && php artisan schedule:run >> /dev/null 2>&1") | crontab -

# Optimize
cd ${INSTALL_DIR}
php artisan optimize

# Save info
cat > /root/invoiceninja_credentials.txt <<CREDS
Invoice Ninja Installation
==========================
Date: $(date)

URL: https://${DOMAIN}

MySQL Root Password: ${MYSQL_ROOT_PASSWORD}
Database: ${DB_DATABASE}
DB User: ${DB_USERNAME}
DB Password: ${DB_PASSWORD}

Next: Visit https://${DOMAIN}/setup
CREDS

chmod 600 /root/invoiceninja_credentials.txt

echo ""
echo "=========================================="
echo "INSTALLATION COMPLETE!"
echo "=========================================="
echo "URL: https://${DOMAIN}/setup"
echo "Credentials: /root/invoiceninja_credentials.txt"
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo "=========================================="
