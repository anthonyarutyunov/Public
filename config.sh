#!/bin/sh
# setup-invoiceninja-alpine.sh
# Full Invoice Ninja automated installer for Alpine Linux 3.22.1
# Run as root on a fresh system

set -euo pipefail

# --------- VARIABLES ----------
DB_DATABASE="i9429759_fnn91"
DB_USERNAME="i9429759_fnn91"
DB_PASSWORD="F.mjndREY1MWNkbZvbo30"
DB_HOST="127.0.0.1"
APP_URL="https://invoicing.insmallusa.com"
PDF_GENERATOR="hosted_ninja"
INVOICE_NINJA_DIR="/var/www/invoiceninja"
GIT_BRANCH="v5-stable"
# -----------------------------

echo "1/ Enable all Alpine repositories and update packages"
sed -i 's/^#//g' /etc/apk/repositories
apk update && apk upgrade --no-cache

echo "2/ Install core services and PHP 8.x"
apk add --no-cache \
  nginx \
  mariadb \
  mariadb-client \
  php8 \
  php8-fpm \
  php8-cli \
  php8-opcache \
  php8-bcmath \
  php8-curl \
  php8-dom \
  php8-gd \
  php8-mbstring \
  php8-json \
  php8-zip \
  php8-xml \
  php8-intl \
  php8-gmp \
  php8-pdo \
  php8-pdo_mysql \
  php8-mysqli \
  php8-openssl \
  php8-fileinfo \
  php8-pecl-imagick \
  composer \
  git \
  unzip \
  bash \
  ca-certificates \
  tzdata

adduser -D -H -S -s /sbin/nologin nginx || true

echo "3/ Initialize and start MariaDB"
if [ ! -d /var/lib/mysql/mysql ]; then
  /etc/init.d/mariadb setup
fi
rc-service mariadb start
rc-update add mariadb default

mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_DATABASE}\`.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "4/ Configure PHP-FPM socket"
PHP_FPM_POOL="/etc/php8/php-fpm.d/www.conf"
sed -i 's/^user = .*/user = nginx/' "$PHP_FPM_POOL"
sed -i 's/^group = .*/group = nginx/' "$PHP_FPM_POOL"
sed -i 's/^listen = .*/listen = \/run\/php-fpm.sock/' "$PHP_FPM_POOL"

mkdir -p /run
rc-service php8-fpm start
rc-update add php8-fpm default

echo "5/ Configure Nginx for Invoice Ninja"
mkdir -p "${INVOICE_NINJA_DIR}"
cat > /etc/nginx/conf.d/invoiceninja.conf <<'NGINXCONF'
server {
    listen 80;
    server_name invoicing.insmallusa.com;
    root /var/www/invoiceninja/public;
    index index.php index.html;

    access_log /var/log/nginx/invoiceninja.access.log;
    error_log /var/log/nginx/invoiceninja.error.log;

    client_max_body_size 100M;
    sendfile off;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }

    location ~ /\. {
        deny all;
    }
}
NGINXCONF

chown -R nginx:nginx /var/www/invoiceninja
rc-service nginx start
rc-update add nginx default

echo "6/ Clone Invoice Ninja and install dependencies"
cd /var/www
if [ -d "${INVOICE_NINJA_DIR}/.git" ]; then
  cd "${INVOICE_NINJA_DIR}"
  git fetch --all
  git checkout ${GIT_BRANCH}
  git pull --ff-only
else
  git clone --branch ${GIT_BRANCH} https://github.com/invoiceninja/invoiceninja.git "${INVOICE_NINJA_DIR}"
fi

cd "${INVOICE_NINJA_DIR}"
composer install --no-dev -o --prefer-dist

echo "7/ Configure environment"
cp .env.example .env || true
sed -i "s/^DB_HOST=.*/DB_HOST=${DB_HOST}/" .env
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_DATABASE}/" .env
sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USERNAME}/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" .env
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env

if grep -q "^PDF_GENERATOR=" .env; then
  sed -i "s/^PDF_GENERATOR=.*/PDF_GENERATOR=${PDF_GENERATOR}/" .env
else
  echo "PDF_GENERATOR=${PDF_GENERATOR}" >> .env
fi

mkdir -p storage bootstrap/cache public/logo
chown -R nginx:nginx storage bootstrap public
chmod -R 775 storage bootstrap

echo "8/ Run Artisan setup"
php artisan key:generate --force
php artisan migrate --force
php artisan db:seed --force || true

echo "9/ Finalize permissions and restart services"
chown -R nginx:nginx "${INVOICE_NINJA_DIR}"
rc-service php8-fpm restart
rc-service nginx restart
rc-service mariadb restart

echo "Installation complete."
echo "Visit ${APP_URL} to complete setup in browser."
echo "Logs: /var/log/nginx/invoiceninja.error.log"
echo "App logs: ${INVOICE_NINJA_DIR}/storage/logs/laravel.log"
