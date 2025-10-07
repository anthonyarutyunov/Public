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
echo "[1/15] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install basic dependencies
echo "[2/15] Installing basic dependencies..."
apt-get install -y software-properties-common curl wget git unzip

# Add PHP repository
echo "[3/15] Adding PHP 8.2 repository..."
add-apt-repository ppa:ondrej/php -y
apt-get update

# Install PHP 8.2 and extensions
echo "[4/15] Installing PHP 8.2 and required extensions..."
apt-get install -y php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-mbstring \
    php8.2-xml php8.2-curl php8.2-zip php8.2-gd php8.2-bcmath php8.2-intl \
    php8.2-gmp php8.2-soap

# Install MySQL
echo "[5/15] Installing MySQL..."
apt-get install -y mysql-server

# Start and enable MySQL
systemctl start mysql
systemctl enable mysql

# Wait for MySQL to be ready
sleep 5

# Secure MySQL and create database
echo "[6/15] Configuring MySQL..."

# Check if MySQL is using auth_socket or has no password
MYSQL_AUTH=$(mysql -u root -e "SELECT plugin FROM mysql.user WHERE User='root' AND Host='localhost';" 2>/dev/null | grep -v plugin || echo "auth_socket")

if [[ "$MYSQL_AUTH" == *"auth_socket"* ]] || mysql -u root -e "SELECT 1" &>/dev/null; then
    # MySQL root has no password or uses auth_socket, we can connect directly
    echo "Setting MySQL root password..."
    
    mysql -u root <<MYSQL_ROOT_SETUP
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
MYSQL_ROOT_SETUP

else
    # Root already has a password, try to connect with it
    echo "MySQL root already has a password set."
    read -sp "Enter current MySQL root password: " EXISTING_ROOT_PASS
    echo ""
    
    mysql -u root -p"${EXISTING_ROOT_PASS}" <<MYSQL_ROOT_SETUP
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
MYSQL_ROOT_SETUP
fi

# Create database and user
echo "[7/15] Creating database and user..."
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<MYSQL_SCRIPT
DROP DATABASE IF EXISTS ${DB_DATABASE};
CREATE DATABASE ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USERNAME}'@'localhost';
CREATE USER '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "Database and user created successfully!"

# Install Composer
echo "[8/15] Installing Composer..."
cd /tmp
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Create /var/www directory if it doesn't exist
echo "[9/15] Creating directories and downloading Invoice Ninja v5..."
mkdir -p /var/www
cd /var/www

# Remove old installation if exists
rm -rf invoiceninja invoiceninja.tar

# Download Invoice Ninja v5
echo "Downloading Invoice Ninja..."
curl -L -o invoiceninja.tar https://github.com/invoiceninja/invoiceninja/releases/latest/download/invoiceninja.tar

# Extract
echo "Extracting files..."
tar -xf invoiceninja.tar
rm invoiceninja.tar

# Verify installation directory exists
if [ ! -d "${INSTALL_DIR}" ]; then
    echo "ERROR: Installation directory not created properly"
    exit 1
fi

echo "Invoice Ninja downloaded successfully!"

# Set up Invoice Ninja
echo "[10/15] Configuring Invoice Ninja..."
cd ${INSTALL_DIR}

# Check if .env.example exists
if [ ! -f .env.example ]; then
    echo "ERROR: .env.example not found!"
    exit 1
fi

# Copy environment file
cp .env.example .env

# Update .env file with configuration
echo "Updating configuration..."
sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|g" .env
sed -i "s|^APP_ENV=.*|APP_ENV=production|g" .env
sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_DATABASE}|g" .env
sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USERNAME}|g" .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=\"${DB_PASSWORD}\"|g" .env
sed -i "s|^PDF_GENERATOR=.*|PDF_GENERATOR=${PDF_GENERATOR}|g" .env
sed -i "s|^REQUIRE_HTTPS=.*|REQUIRE_HTTPS=true|g" .env

# Add PDF_GENERATOR if not exists
if ! grep -q "PDF_GENERATOR" .env; then
    echo "PDF_GENERATOR=${PDF_GENERATOR}" >> .env
fi

# Generate application key
echo "Generating application key..."
php artisan key:generate --no-interaction --force

# Set permissions
echo "[11/15] Setting correct permissions..."
chown -R www-data:www-data ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache
chmod -R 775 ${INSTALL_DIR}/public

# Run database migrations
echo "[12/15] Running database migrations..."
php artisan migrate --force --seed

# Install Nginx
echo "[13/15] Installing and configuring Nginx..."
apt-get install -y nginx

# Create Nginx configuration
cat > /etc/nginx/sites-available/invoiceninja.conf <<NGINX_CONFIG
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/invoiceninja/public;

    index index.php index.html index.htm;
    client_max_body_size 20M;

    gzip on;
    gzip_types      application/javascript application/x-javascript text/javascript text/plain application/xml application/json;
    gzip_proxied    no-cache no-store private expired auth;
    gzip_min_length 1000;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX_CONFIG

# Enable site
ln -sf /etc/nginx/sites-available/invoiceninja.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
nginx -t

# Restart services
echo "Starting services..."
systemctl restart php8.2-fpm
systemctl restart nginx
systemctl enable nginx
systemctl enable php8.2-fpm

# Install SSL certificate
echo "[14/15] Installing SSL certificate with Let's Encrypt..."
apt-get install -y certbot python3-certbot-nginx

echo ""
echo "NOTE: SSL certificate requires your domain to point to this server."
echo "Domain: ${DOMAIN}"
echo "Server IP: $(curl -s ifconfig.me || echo 'Unable to detect')"
echo ""

# Attempt to get SSL certificate
if certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
    echo "SSL certificate installed successfully!"
else
    echo ""
    echo "WARNING: SSL certificate installation failed."
    echo "This is usually because:"
    echo "  1. Your domain doesn't point to this server yet"
    echo "  2. Port 80/443 is blocked by a firewall"
    echo ""
    echo "You can install SSL later with:"
    echo "  sudo certbot --nginx -d ${DOMAIN}"
    echo ""
    echo "For now, you can access Invoice Ninja at: http://${DOMAIN}"
fi

# Set up cron job for Invoice Ninja scheduler
echo "[15/15] Setting up cron job..."
(crontab -l 2>/dev/null | grep -v "invoiceninja"; echo "* * * * * cd /var/www/invoiceninja && php artisan schedule:run >> /dev/null 2>&1") | crontab -

# Optimize application
echo "Optimizing application..."
cd ${INSTALL_DIR}
php artisan optimize
php artisan view:cache
php artisan route:cache

# Save credentials
cat > /root/invoiceninja_install.txt <<CREDS
========================================
Invoice Ninja v5 Installation Details
========================================
Installation Date: $(date)

URL: https://${DOMAIN}

MySQL Root Password: ${MYSQL_ROOT_PASSWORD}

Database Information:
  Database Name: ${DB_DATABASE}
  Database User: ${DB_USERNAME}
  Database Pass: ${DB_PASSWORD}

Installation Path: ${INSTALL_DIR}

PHP Version: 8.2
PDF Generator: ${PDF_GENERATOR}

========================================
Next Steps:
1. Visit https://${DOMAIN}/setup (or http:// if SSL failed)
2. Complete the setup wizard
3. Create your admin account
4. Configure email settings in Settings > Email Settings

If SSL failed, run:
  sudo certbot --nginx -d ${DOMAIN}

To view this file again:
  cat /root/invoiceninja_install.txt
========================================
CREDS

chmod 600 /root/invoiceninja_install.txt

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Invoice Ninja URL: https://${DOMAIN}"
echo "           (or http://${DOMAIN} if SSL failed)"
echo ""
echo "Credentials saved to: /root/invoiceninja_install.txt"
echo ""
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo ""
echo "NEXT STEPS:"
echo "1. Visit https://${DOMAIN}/setup"
echo "2. Complete the setup wizard"
echo "3. Create your admin account"
echo ""
echo "=========================================="
