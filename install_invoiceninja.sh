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

echo "Step 1: Updating system and installing dependencies..."
apk update
apk upgrade
apk add --no-cache \
    nginx \
    php83 \
    php83-fpm \
    php83-opcache \
    php83-mysqli \
    php83-pdo \
    php83-pdo_mysql \
    php83-mbstring \
    php83-xml \
    php83-simplexml \
    php83-zip \
    php83-gd \
    php83-curl \
    php83-tokenizer \
    php83-bcmath \
    php83-soap \
    php83-gmp \
    php83-intl \
    php83-fileinfo \
    php83-dom \
    php83-session \
    php83-ctype \
    php83-iconv \
    php83-phar \
    php83-openssl \
    mariadb \
    mariadb-client \
    composer \
    git \
    curl \
    openssl \
    dcron \
    libcap

echo "Step 2: Starting and configuring MariaDB..."
rc-update add mariadb default
/etc/init.d/mariadb setup
/etc/init.d/mariadb start

# Wait for MariaDB to be ready
sleep 10

# Secure MariaDB installation
mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';" 2>/dev/null || \
mysql_secure_installation <<EOSQL
${MYSQL_ROOT_PASSWORD}
${MYSQL_ROOT_PASSWORD}
y
y
y
y
EOSQL

sleep 2

echo "Step 3: Creating database and user..."
mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_DATABASE}.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "Step 4: Configuring PHP-FPM..."
sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php83/php.ini
sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' /etc/php83/php.ini
sed -i 's/post_max_size = .*/post_max_size = 100M/' /etc/php83/php.ini
sed -i 's/max_execution_time = .*/max_execution_time = 300/' /etc/php83/php.ini
sed -i 's/;date.timezone =.*/date.timezone = UTC/' /etc/php83/php.ini

# Configure PHP-FPM pool
sed -i 's/user = nobody/user = nginx/' /etc/php83/php-fpm.d/www.conf
sed -i 's/group = nobody/group = nginx/' /etc/php83/php-fpm.d/www.conf
sed -i 's/listen = 127.0.0.1:9000/listen = \/run\/php-fpm83\/php-fpm83.sock/' /etc/php83/php-fpm.d/www.conf
sed -i 's/;listen.owner = nobody/listen.owner = nginx/' /etc/php83/php-fpm.d/www.conf
sed -i 's/;listen.group = nobody/listen.group = nginx/' /etc/php83/php-fpm.d/www.conf
sed -i 's/;listen.mode = 0660/listen.mode = 0660/' /etc/php83/php-fpm.d/www.conf

# Create PHP-FPM socket directory
mkdir -p /run/php-fpm83
chown nginx:nginx /run/php-fpm83

echo "Step 5: Installing InvoiceNinja..."
mkdir -p /var/www
cd /var/www
git clone --depth 1 https://github.com/invoiceninja/invoiceninja.git invoiceninja
cd ${INSTALL_DIR}

# Install dependencies
composer install --no-dev --no-interaction --optimize-autoloader

echo "Step 6: Configuring InvoiceNinja..."
cp .env.example .env

# Generate application key
APP_KEY=$(php83 artisan key:generate --show)

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
php83 artisan migrate --force --seed
php83 artisan db:seed --force
php83 artisan optimize

echo "Step 7: Setting permissions..."
chown -R nginx:nginx ${INSTALL_DIR}
chmod -R 755 ${INSTALL_DIR}
chmod -R 775 ${INSTALL_DIR}/storage
chmod -R 775 ${INSTALL_DIR}/bootstrap/cache
chmod -R 775 ${INSTALL_DIR}/public

echo "Step 8: Configuring Nginx..."
cat > /etc/nginx/http.d/${DOMAIN}.conf <<'NGINXCONF'
server {
    listen 80;
    server_name invoicing.insmallusa.com;
    root /var/www/invoiceninja/public;

    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm83/php-fpm83.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
    }
}
NGINXCONF

# Remove default nginx config
rm -f /etc/nginx/http.d/default.conf

echo "Step 9: Setting up cron job..."
# Create cron job for nginx user
mkdir -p /var/spool/cron/crontabs
cat > /var/spool/cron/crontabs/nginx <<EOF
* * * * * cd ${INSTALL_DIR} && php83 artisan schedule:run >> /dev/null 2>&1
EOF
chmod 600 /var/spool/cron/crontabs/nginx
chown nginx:nginx /var/spool/cron/crontabs/nginx

# Create queue worker service script
cat > /etc/init.d/invoiceninja-worker <<'WORKERSCRIPT'
#!/sbin/openrc-run

name="InvoiceNinja Queue Worker"
command="/usr/bin/php83"
command_args="/var/www/invoiceninja/artisan queue:work --sleep=3 --tries=3 --max-time=3600"
command_user="nginx:nginx"
command_background="yes"
pidfile="/run/invoiceninja-worker.pid"

depend() {
    need mariadb nginx php-fpm83
}
WORKERSCRIPT

chmod +x /etc/init.d/invoiceninja-worker

echo "Step 10: Starting services..."
rc-update add nginx default
rc-update add php-fpm83 default
rc-update add dcron default
rc-update add invoiceninja-worker default

/etc/init.d/php-fpm83 restart
/etc/init.d/nginx restart
/etc/init.d/dcron restart
/etc/init.d/invoiceninja-worker start

echo ""
echo "==================================================================="
echo "InvoiceNinja Installation Complete!"
echo "==================================================================="
echo ""
echo "Access your installation at: http://${DOMAIN}"
echo ""
echo "IMPORTANT - Save these credentials:"
echo "-----------------------------------"
echo "MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
echo "Database Name: ${DB_DATABASE}"
echo "Database User: ${DB_USERNAME}"
echo "Database Password: ${DB_PASSWORD}"
echo ""
echo "Next steps:"
echo "1. Configure SSL/TLS certificate (recommended: certbot with Let's Encrypt)"
echo "2. Point your domain ${DOMAIN} to this server's IP address"
echo "3. Complete the InvoiceNinja setup wizard in your browser"
echo ""
echo "To install SSL certificate, run:"
echo "apk add certbot certbot-nginx"
echo "certbot --nginx -d ${DOMAIN}"
echo ""
echo "To check service status:"
echo "rc-service nginx status"
echo "rc-service php-fpm83 status"
echo "rc-service mariadb status"
echo "rc-service invoiceninja-worker status"
echo ""
echo "==================================================================="
