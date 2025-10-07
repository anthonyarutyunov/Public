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

# Install MySQL with proper configuration
echo "[5/15] Installing MySQL..."
apt-get install -y mysql-server

# Start MySQL
systemctl start mysql
systemctl enable mysql

# Wait for MySQL to start
sleep 3

# Configure MySQL - Ubuntu 22.04 MySQL uses auth_socket by default
echo "[6/15] Configuring MySQL..."

# Create a temporary SQL file for MySQL configuration
cat > /tmp/mysql_setup.sql <<MYSQL_SETUP
-- Remove any existing root password authentication
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;

-- Drop database if exists
DROP DATABASE IF EXISTS ${DB_DATABASE};

-- Create database
CREATE DATABASE ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Drop user if exists
DROP USER IF EXISTS '${DB_USERNAME}'@'localhost';

-- Create user
CREATE USER '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';

-- Grant privileges
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';

-- Flush privileges
FLUSH PRIVILEGES;
MYSQL_SETUP

# Execute MySQL setup using sudo (bypasses password with auth_socket)
echo "[7/15] Creating database and user..."
sudo mysql < /tmp/mysql_setup.sql

# Remove temporary SQL file
rm /tmp/mysql_setup.sql

echo "MySQL configured successfully!"

# Verify database was created
sudo mysql -e "SHOW DATABASES LIKE '${DB_DATABASE}';" | grep -q "${DB_DATABASE}" && echo "Database verified!" || echo "WARNING: Database not found!"

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
echo "Downloading Invoice Ninja (this may take a moment)..."
wget -q --show-progress https://github.com/invoiceninja/invoiceninja/releases/latest/download/invoiceninja.tar

# Extract
echo "Extracting files..."
tar -xf invoiceninja.tar
rm invoiceninja.tar

# Verify installation directory exists
if [ ! -d "${INSTALL_DIR}" ]; then
    echo "ERROR: Installation directory not created properly"
    ls -la /var/www/
    exit 1
fi

echo "Invoice Ninja downloaded successfully!"

# Set up Invoice Ninja
echo "[10/15] Configuring Invoice Ninja..."
cd ${INSTALL_DIR}

# Check if .env.example exists
if [ ! -f .env.example ]; then
    echo "ERROR: .env.example not found!"
    ls -la ${INSTALL_DIR}/
    exit 1
fi

# Copy environment file
cp .env.example .env

# Create a proper .env file
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
FILESYSTEM_DRIVER=public
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_HOST=smtp.mailtrap.io
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS=null
MAIL_FROM_NAME="\${APP_NAME}"

PDF_GENERATOR=${PDF_GENERATOR}

PHANTOMJS_KEY='a-demo-key-with-low-quota-per-ip-address'
PHANTOMJS_SECRET=secret

REQUIRE_HTTPS=true

TRUSTED_PROXIES=*
ENV_FILE

# Generate application key
echo "Generating application key..."
php artisan key:generate --no-interaction --force

# Set permissions before migration
echo "[11/15] Setting correct permissions..."
chown -R www-data:www-data ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache
chmod -R 775 ${INSTALL_DIR}/public
chmod 644 ${INSTALL_DIR}/.env

# Test database connection
echo "[12/15] Testing database connection..."
php artisan tinker --execute="echo 'Database connection: '; try { DB::connection()->getPdo(); echo 'Success!'; } catch (\Exception \$e) { echo 'Failed: ' . \$e->getMessage(); }"

# Run database migrations
echo "Running database migrations..."
php artisan migrate --force --seed

# Install Nginx
echo "[13/15] Installing and configuring Nginx..."
apt-get install -y nginx

# Create Nginx configuration
cat > /etc/nginx/sites-available/invoiceninja.conf <<'NGINX_CONFIG'
server {
    listen 80;
    server_name SERVER_NAME_PLACEHOLDER;
    root /var/www/invoiceninja/public;

    index index.php index.html index.htm;
    client_max_body_size 20M;

    gzip on;
    gzip_types      application/javascript application/x-javascript text/javascript text/plain application/xml application/json;
    gzip_proxied    no-cache no-store private expired auth;
    gzip_min_length 1000;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX_CONFIG

# Replace placeholder
sed -i "s/SERVER_NAME_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/invoiceninja.conf

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
echo "Attempting SSL certificate installation..."
echo "Domain: ${DOMAIN}"
echo "Server IP: $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""

# Attempt to get SSL certificate
if certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>&1 | tee /tmp/certbot.log; then
    echo "SSL certificate installed successfully!"
else
    echo ""
    echo "WARNING: SSL certificate installation failed."
    echo "You can access Invoice Ninja at: http://${DOMAIN}"
    echo ""
    echo "To install SSL later, run:"
    echo "  sudo certbot --nginx -d ${DOMAIN}"
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

Access URL: https://${DOMAIN}
Fallback URL: http://${DOMAIN}

MySQL Root Password: ${MYSQL_ROOT_PASSWORD}

Database Information:
  Host: 127.0.0.1
  Database Name: ${DB_DATABASE}
  Database User: ${DB_USERNAME}
  Database Pass: ${DB_PASSWORD}

Installation Path: ${INSTALL_DIR}

PHP Version: 8.2
PDF Generator: ${PDF_GENERATOR}

========================================
SETUP INSTRUCTIONS:

1. Visit https://${DOMAIN}/setup
   (or http://${DOMAIN}/setup if SSL failed)

2. The setup wizard will guide you through:
   - Creating your admin account
   - Configuring basic settings
   - Email configuration (optional)

3. Database connection is already configured!

========================================
TROUBLESHOOTING:

View credentials:
  cat /root/invoiceninja_install.txt

Check Nginx status:
  sudo systemctl status nginx

Check PHP-FPM status:
  sudo systemctl status php8.2-fpm

View Nginx logs:
  sudo tail -f /var/log/nginx/error.log

Install SSL certificate:
  sudo certbot --nginx -d ${DOMAIN}

========================================
CREDS

chmod 600 /root/invoiceninja_install.txt

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Invoice Ninja URL: https://${DOMAIN}"
echo "           Fallback: http://${DOMAIN}"
echo ""
echo "Credentials saved to: /root/invoiceninja_install.txt"
echo ""
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo "(Saved in /root/invoiceninja_install.txt)"
echo ""
echo "=========================================="
echo "NEXT STEPS:"
echo "=========================================="
echo "1. Visit https://${DOMAIN}/setup"
echo "2. Complete the setup wizard"
echo "3. Create your admin account"
echo ""
echo "The database is already configured!"
echo "=========================================="
