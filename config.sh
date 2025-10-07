#!/bin/sh
set -e

# --- CONFIG ---
DB_NAME="i9429759_fnn91"
DB_USER="i9429759_fnn91"
DB_PASS="F.mjndREY1MWNkbZvbo30"
APP_DOMAIN="invoices.insmallusa.com"
APP_DIR="/var/www/invoiceninja"
ALPINE_VER="v3.20"
# --------------

echo "[1/9] Enable repositories and update system..."
echo "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/community" >> /etc/apk/repositories
apk update && apk upgrade

echo "[2/9] Installing required packages..."
apk add nginx mariadb mariadb-client php82 php82-fpm php82-pdo php82-pdo_mysql php82-tokenizer php82-fileinfo php82-xml php82-ctype php82-mbstring php82-json php82-openssl php82-curl php82-session php82-simplexml php82-dom php82-gd php82-zip php82-bcmath php82-redis composer git curl unzip

echo "[3/9] Enable and start core services..."
rc-update add mariadb
rc-update add nginx
rc-update add php-fpm82
rc-service mariadb setup
rc-service mariadb start

echo "[4/9] Configure MariaDB database and user..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "[5/9] Clean any previous Invoice Ninja install..."
rm -rf $APP_DIR
mkdir -p $APP_DIR

echo "[6/9] Download latest Invoice Ninja..."
git clone --depth=1 https://github.com/invoiceninja/invoiceninja.git $APP_DIR
cd $APP_DIR

echo "[7/9] Install PHP dependencies..."
composer install --no-dev -o

echo "[8/9] Configure environment..."
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

echo "[9/9] Configure Nginx..."
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

echo ""
echo "✅ Invoice Ninja installation complete."
echo "Access it at: http://${APP_DOMAIN}"
echo ""
echo "Next steps:"
echo "1. Set up DNS A record: invoices.insmallusa.com -> <your public IP>"
echo "2. Forward TCP port 80 (and optionally 443) to this VM."
