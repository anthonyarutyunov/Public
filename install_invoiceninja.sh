#!/bin/sh
# filepath: install_invoiceninja.sh

set -e

echo "=== InvoiceNinja Installation Script for Alpine Linux 3.22.1 ==="

# Configuration
DOMAIN="invoicing.insmallusa.com"
DB_DATABASE="i9429759_fnn91"
DB_USERNAME="i9429759_fnn91"
DB_PASSWORD="F.mjndREY1MWNkbZvbo30"
PDF_GENERATOR="hosted_ninja"
INSTALL_DIR="/var/www/invoiceninja"
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)

echo "Step 1: Updating repositories..."
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
EOF

apk update
apk upgrade

echo "Step 2: Installing base packages..."
apk add --no-cache \
    nginx \
    mariadb \
    mariadb-client \
    git \
    curl \
    openssl \
    dcron \
    libcap \
    wget

echo "Step 3: Detecting and installing available PHP version..."
# Try to find available PHP versions
if apk search php83 | grep -q "php83$"; then
    PHP_VER="php83"
elif apk search php82 | grep -q "php82$"; then
    PHP_VER="php82"
elif apk search php81 | grep -q "php81$"; then
    PHP_VER="php81"
else
    echo "ERROR: No compatible PHP version found!"
    exit 1
fi

echo "Installing PHP ${PHP_VER}..."

apk add --no-cache \
    ${PHP_VER} \
    ${PHP_VER}-fpm \
    ${PHP_VER}-opcache \
    ${PHP_VER}-mysqli \
    ${PHP_VER}-pdo \
    ${PHP_VER}-pdo_mysql \
    ${PHP_VER}-mbstring \
    ${PHP_VER}-xml \
    ${PHP_VER}-simplexml \
    ${PHP_VER}-zip \
    ${PHP_VER}-gd \
    ${PHP_VER}-curl \
    ${PHP_VER}-tokenizer \
    ${PHP_VER}-bcmath \
    ${PHP_VER}-soap \
    ${PHP_VER}-gmp \
    ${PHP_VER}-intl \
    ${PHP_VER}-fileinfo \
    ${PHP_VER}-dom \
    ${PHP_VER}-session \
    ${PHP_VER}-ctype \
    ${PHP_VER}-iconv \
    ${PHP_VER}-phar \
    ${PHP_VER}-openssl

# Create PHP symlink
ln -sf /usr/bin/${PHP_VER} /usr/bin/php

echo "Step 4: Installing Composer..."
cd /tmp
wget https://getcomposer.org/installer -O composer-setup.php
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm composer-setup.php

echo "Step 5: Starting and configuring MariaDB..."
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
rc-update add mariadb default

if [ ! -d "/var/lib/mysql/mysql" ]; then
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
fi

/etc/init.d/mariadb start

# Wait for MariaDB to be ready
echo "Waiting for MariaDB to start..."
sleep 10

# Secure MariaDB installation
mysqladmin -u root password "${MYSQL_ROOT_PASSWORD}" 2>/dev/null || true
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

echo "Step 6: Creating database and user..."
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "Step 7: Configuring PHP..."
PHP_INI="/etc/${PHP_VER}/php.ini"
sed -i 's/memory_limit = .*/memory_limit = 512M/' ${PHP_INI}
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' ${PHP_INI}
sed -i 's/post_max_size = .*/post_max_size = 100M/' ${PHP_INI}
sed -i 's/max_execution_time = .*/max_execution_time = 300/' ${PHP_INI}
sed -i 's/;date.timezone =.*/date.timezone = UTC/' ${PHP_INI}
sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' ${PHP_INI}

echo "Step 8: Configuring PHP-FPM..."
FPM_CONF="/etc/${PHP_VER}/php-fpm.d/www.conf"
sed -i 's/user = nobody/user = nginx/' ${FPM_CONF}
sed -i 's/group = nobody/group = nginx/' ${FPM_CONF}
sed -i 's/listen = 127.0.0.1:9000/listen = \/run\/php-fpm.sock/' ${FPM_CONF}
sed -i 's/;listen.owner = nobody/listen.owner = nginx/' ${FPM_CONF}
sed -i 's/;listen.group = nobody/listen.group = nginx/' ${FPM_CONF}
sed -i 's/;listen.mode = 0660/listen.mode = 0660/' ${FPM_CONF}

echo "Step 9: Installing InvoiceNinja..."
mkdir -p /var/www
cd /var/www

if [ -d "invoiceninja" ]; then
    rm -rf invoiceninja
fi

git clone https://github.com/invoiceninja/invoiceninja.git
cd ${INSTALL_DIR}

# Install dependencies with composer
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --optimize-autoloader

echo "Step 10: Configuring InvoiceNinja..."
cp .env.example .env

# Generate application key
APP_KEY=$(php artisan key:generate --show)

# Configure .env file
cat > .env <<EOF
APP_NAME=InvoiceNinja
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=https://${DOMAIN}

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DRIVER=local
QUEUE_CONNECTION=database
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_HOST=
MAIL_PORT=
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_ENCRYPTION=
MAIL_FROM_ADDRESS=
MAIL_FROM_NAME=

PDF_GENERATOR=${PDF_GENERATOR}

REQUIRE_HTTPS=true
EOF

# Run migrations
php artisan migrate --force
php artisan db:seed --force
php artisan optimize

echo "Step 11: Setting permissions..."
chown -R nginx:nginx ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache
chmod -R 775 ${INSTALL_DIR}/public

echo "Step 12: Configuring Nginx..."
cat > /etc/nginx/http.d/${DOMAIN}.conf <<'NGINXCONF'
server {
    listen 80;
    server_name invoicing.insmallusa.com;
    root /var/www/invoiceninja/public;

    index index.php index.html;

    client_max_body_size 100M;
    
    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_busy_buffers_size 16k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
    }
}
NGINXCONF

# Test nginx configuration
nginx -t

# Remove default nginx config if exists
rm -f /etc/nginx/http.d/default.conf

echo "Step 13: Setting up cron job..."
mkdir -p /var/spool/cron/crontabs
cat > /var/spool/cron/crontabs/nginx <<EOF
* * * * * cd ${INSTALL_DIR} && php artisan schedule:run >> /dev/null 2>&1
EOF
chmod 600 /var/spool/cron/crontabs/nginx
chown nginx:nginx /var/spool/cron/crontabs/nginx

echo "Step 14: Creating queue worker service..."
cat > /etc/init.d/invoiceninja-worker <<WORKERSCRIPT
#!/sbin/openrc-run

name="InvoiceNinja Queue Worker"
command="/usr/bin/php"
command_args="${INSTALL_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600"
command_user="nginx:nginx"
command_background="yes"
pidfile="/run/invoiceninja-worker.pid"
output_log="/var/log/invoiceninja-worker.log"
error_log="/var/log/invoiceninja-worker-error.log"

depend() {
    need mariadb nginx ${PHP_VER}-fpm
}
WORKERSCRIPT

chmod +x /etc/init.d/invoiceninja-worker

echo "Step 15: Starting services..."
rc-update add nginx default
rc-update add ${PHP_VER}-fpm default
rc-update add dcron default
rc-update add invoiceninja-worker default

/etc/init.d/${PHP_VER}-fpm restart
/etc/init.d/nginx restart
/etc/init.d/dcron restart
/etc/init.d/invoiceninja-worker start

echo ""
echo "==================================================================="
echo "InvoiceNinja Installation Complete!"
echo "==================================================================="
echo ""
echo "PHP Version Installed: ${PHP_VER}"
echo ""
echo "Access your installation at: http://${DOMAIN}"
echo "Or via IP: http://$(hostname -i)"
echo ""
echo "IMPORTANT - Save these credentials:"
echo "-----------------------------------"
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo "Database Name: ${DB_DATABASE}"
echo "Database User: ${DB_USERNAME}"
echo "Database Password: ${DB_PASSWORD}"
echo ""
echo "Next steps:"
echo "1. Point your domain ${DOMAIN} to this server's IP address"
echo "2. Complete the InvoiceNinja setup wizard in your browser"
echo "3. Install SSL certificate (recommended)"
echo ""
echo "To install SSL certificate:"
echo "apk add certbot certbot-nginx"
echo "certbot --nginx -d ${DOMAIN}"
echo ""
echo "Service commands:"
echo "rc-service nginx status|restart|stop"
echo "rc-service ${PHP_VER}-fpm status|restart|stop"
echo "rc-service mariadb status|restart|stop"
echo "rc-service invoiceninja-worker status|restart|stop"
echo ""
echo "==================================================================="

# Save credentials to file
cat > /root/invoiceninja-credentials.txt <<EOF
InvoiceNinja Installation Credentials
======================================
Date: $(date)
Domain: ${DOMAIN}
Installation Directory: ${INSTALL_DIR}

MySQL Root Password: ${MYSQL_ROOT_PASSWORD}
Database Name: ${DB_DATABASE}
Database User: ${DB_USERNAME}
Database Password: ${DB_PASSWORD}

PHP Version: ${PHP_VER}
EOF

echo "Credentials saved to: /root/invoiceninja-credentials.txt"
