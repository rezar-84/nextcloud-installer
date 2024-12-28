#!/bin/bash

# Nextcloud installation script for Ubuntu

# Exit immediately if a command exits with a non-zero status
set -e

# Function to prompt for variable if not already set
prompt_variable() {
  local var_name=$1
  local prompt_message=$2
  local default_value=$3

  if [ -z "${!var_name}" ]; then
    echo "$prompt_message (default: $default_value):"
    read -r input
    eval "$var_name=\"${input:-$default_value}\""
  else
    echo "$var_name is already set to '${!var_name}'. Press Enter to keep it or type a new value:"
    read -r input
    if [ -n "$input" ]; then
      eval "$var_name=\"$input\""
    fi
  fi
}

# Retry mechanism
retry_installation() {
  echo "Installation failed. Would you like to retry with the same variables? (yes/no)"
  read -r retry
  if [ "$retry" = "yes" ]; then
    $0
    exit 0
  else
    echo "Exiting installation script."
    exit 1
  fi
}
trap retry_installation ERR

# Prompt for variables
prompt_variable NEXTCLOUD_DIR "Enter the directory where Nextcloud will be installed" "/var/www/nextcloud"
prompt_variable DB_NAME "Enter the database name for Nextcloud" "nextcloud_db"
prompt_variable DB_USER "Enter the database user for Nextcloud" "nextcloud_user"
prompt_variable DB_PASS "Enter the database password for Nextcloud" "secure_password"
prompt_variable ADMIN_USER "Enter the admin username for Nextcloud" "admin"
prompt_variable ADMIN_PASS "Enter the admin password for Nextcloud" "admin_password"
prompt_variable DOMAIN "Enter the domain for Nextcloud" "example.com"

# Update and install necessary packages
echo "Updating package list and upgrading system..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mariadb-server libapache2-mod-php \
php-gd php-mysql php-curl php-mbstring php-intl php-xml php-zip php-bz2 php-imagick php-gmp wget unzip curl certbot python3-certbot-apache

# Enable Apache modules
sudo a2enmod rewrite headers env dir mime ssl
sudo systemctl restart apache2

# Secure MariaDB installation
echo "Securing MariaDB..."
sudo mysql_secure_installation <<EOF

Y
$DB_PASS
$DB_PASS
Y
Y
Y
Y
EOF

# Create a database and user for Nextcloud
echo "Setting up Nextcloud database and user..."
sudo mysql -u root -p$DB_PASS <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Download and extract Nextcloud
echo "Downloading Nextcloud..."
sudo wget -O /tmp/nextcloud.zip https://download.nextcloud.com/server/releases/latest.zip
sudo unzip -qo /tmp/nextcloud.zip -d /tmp/
if [ "$NEXTCLOUD_DIR" != "/tmp/nextcloud" ]; then
  sudo mv /tmp/nextcloud $NEXTCLOUD_DIR
else
  echo "Skipping move as source and destination are the same."
fi

# Set permissions
echo "Setting permissions..."
sudo chown -R www-data:www-data $NEXTCLOUD_DIR
sudo chmod -R 750 $NEXTCLOUD_DIR

# Configure Apache
echo "Configuring Apache for Nextcloud..."
cat <<EOL | sudo tee /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $NEXTCLOUD_DIR

    <Directory $NEXTCLOUD_DIR>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOL

sudo a2ensite nextcloud.conf
sudo systemctl reload apache2

# Obtain and configure SSL certificate
echo "Obtaining SSL certificate..."
sudo certbot --apache -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# Finalize installation
echo "Finalizing installation..."
cat <<EOL > $NEXTCLOUD_DIR/config/autoconfig.php
<?php
$AUTOCONFIG = [
    'dbtype' => 'mysql',
    'dbname' => '$DB_NAME',
    'dbuser' => '$DB_USER',
    'dbpass' => '$DB_PASS',
    'dbhost' => 'localhost',
    'adminlogin' => '$ADMIN_USER',
    'adminpass' => '$ADMIN_PASS',
    'directory' => '$NEXTCLOUD_DIR/data',
];
EOL

# Restart Apache to apply changes
sudo systemctl restart apache2

# Success message
echo "Nextcloud installation completed! Visit http://$DOMAIN to finish the setup."
