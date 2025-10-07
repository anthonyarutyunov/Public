#!/bin/sh
set -e

# Variables
DB_NAME="i9429759_fnn91"
DB_USER="i9429759_fnn91"
DB_PASS="F.mjndREY1MWNkbZvbo30"
APP_DOMAIN="invoices.insmallusa.com"
APP_DIR="/var/www/invoiceninja"

echo "[1/7] Updating system and enabling repos..."
echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories
apk update && apk upgrade

echo "[2/7] Installing dependencies..."
apk add nginx mariadb mariadb-client php82 php82-fpm php82-pdo php82-pdo_mysql php82-tokenizer php82-fileinfo php82-xml php82-ctype php82-mbstring php82-json php82-openssl php82-curl php82-session php82-simplexml php82-dom php82-gd php82-zip php82-bcmath php82-redis composer git curl unzip

echo "[3/7] Starting and enabling services..."
rc-update add mariadb
rc-update add nginx
rc-update add php-fpm82
rc-service mariadb setup
rc-service mariadb start

echo "[4/7] Configuring MariaDB and creating database..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "[5/7] Downloading Invoice Ninja..."
mkdir -p $APP_DIR
cd /var/www
if [ ! -d "$APP_DIR" ]; then
  git clone https://github.com/invoiceninja/invoiceninja.git $APP_DIR
fi
cd $APP_DIR
composer install --no-dev -o

echo "[6/7] Configuring Invoice Ninja..."
cp .env.example .env
sed -i "s|APP_URL=.*|APP_URL=http://${APP_DOMAIN}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env

php artisan key:generate
php artisan migrate --seed

chown -R nginx:nginx $APP_DIR
chmod -R 755 $APP_DIR/storage

echo "[7/7] Configuring Nginx..."
cat > /etc/nginx/conf.d/invoiceninja.conf <<EOF
server {
    listen 80;
    server_name ${APP_DOMAIN};

    root ${APP_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }
}
EOF

rc-service php-fpm82 restart
rc-service nginx restart

echo "Invoice Ninja installation complete."
echo "Visit: http://${APP_DOMAIN}"
