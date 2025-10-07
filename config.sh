#!/bin/sh
# setup-invoiceninja-alpine.sh
# Automated installer for Invoice Ninja on Alpine Linux 3.22.1
# Run as root.

set -euo pipefail

# --------- Edit / verify these variables ----------
DB_DATABASE="i9429759_fnn91"
DB_USERNAME="i9429759_fnn91"
DB_PASSWORD="F.mjndREY1MWNkbZvbo30"
DB_HOST="127.0.0.1"
APP_URL="https://invoicing.insmallusa.com"
PDF_GENERATOR="hosted_ninja"
INVOICE_NINJA_DIR="/var/www/invoiceninja"
GIT_BRANCH="v5-stable"   # change if you prefer a specific release
# -------------------------------------------------

echo "1/ Starting package install and system update"
apk update
apk upgrade --no-cache

echo "2/ Installing system packages (nginx, mariadb, php8.2, composer, git, unzip, openssl)"
apk add --no-cache \
  nginx \
  mariadb \
  mariadb-client \
  php82-fpm \
  php82-cli \
  php82-opcache \
  php82-bcmath \
  php82-curl \
  php82-dom \
  php82-gd \
  php82-mbstring \
  php82-json \
  php82-zip \
  php82-xml \
  php82-intl \
  php82-gmp \
  php82-pdo \
  php82-pdo_mysql \
  php82-mysqli \
  php82-openssl \
  php82-fileinfo \
  php82-pecl-imagick-dev \
  composer \
  git \
  unzip \
  bash \
  ca-certificates \
  tzdata

# Ensure nginx user exists (Alpine nginx typically uses 'nginx')
adduser -D -H -S -s /sbin/nologin nginx || true

echo "3/ Initialize and start MariaDB"
# initialize DB if needed
if [ ! -d /var/lib/mysql/mysql ]; then
  /etc/init.d/mariadb setup
fi

rc-service mariadb start
rc-update add mariadb default

# secure DB and create database/user
MYSQL_ROOT_CMD="mysql -u root"
# create DB and user
${MYSQL_ROOT_CMD} <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_DATABASE}\`.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "4/ Configure PHP-FPM to run as nginx and use a socket"
PHP_FPM_POOL="/etc/php82/php-fpm.d/www.conf"
if [ -f "$PHP_FPM_POOL" ]; then
  sed -i 's/^user = .*$/user = nginx/' "$PHP_FPM_POOL" || true
  sed -i 's/^group = .*$/group = nginx/' "$PHP_FPM_POOL" || true
  sed -i 's/^listen = .*$/listen = \/run\/php-fpm.sock/' "$PHP_FPM_POOL" || true
fi

# Ensure socket dir exists and php-fpm will create it
mkdir -p /run
rc-service php82-fpm start
rc-update add php82-fpm default

echo "5/ Configure nginx site for Invoice Ninja"
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

# ensure nginx user ownership exists and correct docroot
mkdir -p /var/www/invoiceninja
chown -R nginx:nginx /var/www/invoiceninja
rc-service nginx start
rc-update add nginx default

echo "6/ Download Invoice Ninja (git) and install composer dependencies"
# choose a safe install path
cd /var/www || exit 1
if [ -d "${INVOICE_NINJA_DIR}/.git" ]; then
  echo "Existing repo detected. Updating."
  cd "${INVOICE_NINJA_DIR}"
  git fetch --all
  git checkout ${GIT_BRANCH} || true
  git pull --ff-only || true
else
  git clone --branch ${GIT_BRANCH} https://github.com/invoiceninja/invoiceninja.git "${INVOICE_NINJA_DIR}"
fi

cd "${INVOICE_NINJA_DIR}"

# composer install as nginx user to set proper file ownership
# If composer in Alpine requires root, run then chown. Try to run as nginx when possible.
if command -v su >/dev/null 2>&1; then
  su -s /bin/sh -c "composer install --no-dev -o --prefer-dist" nginx || composer install --no-dev -o --prefer-dist
else
  composer install --no-dev -o --prefer-dist
fi

echo "7/ Environment configuration"
cp .env.example .env || true
# set DB and APP variables in .env
sed -i "s/^DB_HOST=.*/DB_HOST=${DB_HOST}/" .env
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_DATABASE}/" .env
sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USERNAME}/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" .env
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" .env
# set PDF generator
if grep -q "^PDF_GENERATOR=" .env; then
  sed -i "s/^PDF_GENERATOR=.*/PDF_GENERATOR=${PDF_GENERATOR}/" .env
else
  echo "PDF_GENERATOR=${PDF_GENERATOR}" >> .env
fi

# storage and cache permissions
mkdir -p storage bootstrap/cache public/logo
chown -R nginx:nginx storage bootstrap public
chmod -R 775 storage bootstrap

echo "8/ Generate app key and run migrations (may take a few minutes)"
# run artisan commands as nginx user
ARTISAN="php artisan"
if id nginx >/dev/null 2>&1; then
  su -s /bin/sh -c "${ARTISAN} key:generate --force" nginx
  su -s /bin/sh -c "${ARTISAN} migrate --force" nginx
  su -s /bin/sh -c "${ARTISAN} db:seed --force" nginx || true
else
  php artisan key:generate --force
  php artisan migrate --force
  php artisan db:seed --force || true
fi

echo "9/ Final permissions and restart services"
chown -R nginx:nginx "${INVOICE_NINJA_DIR}"
rc-service php82-fpm restart
rc-service nginx restart
rc-service mariadb restart

echo "Installation complete."
echo "Open ${APP_URL} in your browser to finish web setup (create admin user)."
echo "If you need HTTPS, obtain certificates (e.g. certbot) and adapt nginx to listen 443."

# quick reminder of important logs
echo "Nginx logs: /var/log/nginx/invoiceninja.error.log"
echo "PHP-FPM logs: /var/log/php82-fpm.log (or /var/log/php-fpm/* depending on config)"
echo "Invoice Ninja logs: ${INVOICE_NINJA_DIR}/storage/logs/laravel.log"
