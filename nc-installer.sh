#!/bin/bash
#
# Nextcloud installation script for Ubuntu
#

###############################################################################
# Safety settings
###############################################################################
set -e  # Exit immediately on any command failure

# If an unhandled error occurs, allow the user to retry without re-entering data.
retry_installation() {
  echo
  echo "Installation encountered an error."
  echo "Would you like to retry with the same values? (yes/no)"
  read -r retry
  if [[ "$retry" == "yes" ]]; then
    exec "$0"  # Re-run the script with the same environment
  else
    echo "Exiting installation script."
    exit 1
  fi
}
trap retry_installation ERR

###############################################################################
# Validation functions
###############################################################################
# MySQL database names/users typically allow alphanumeric plus underscores.
validate_mysql_identifier() {
  local input="$1"
  [[ "$input" =~ ^[A-Za-z0-9_]+$ ]]
}

# Password can contain any character, only check for non-empty.
validate_password() {
  local input="$1"
  [[ -n "$input" ]]  # not empty
}

# Domain can contain letters, numbers, dots, dashes.
validate_domain() {
  local input="$1"
  [[ "$input" =~ ^[A-Za-z0-9.-]+$ ]]
}

###############################################################################
# Generic prompt function
###############################################################################
# Usage:
#   prompt_variable VAR_NAME "Prompt message" "default_value" validation_function
# If validation_function is empty or omitted, no validation is performed.
prompt_variable() {
  local var_name="$1"
  local prompt_message="$2"
  local default_value="$3"
  local validator_function="${4:-}"

  # If variable is empty, prompt until valid or user hits Enter for default
  if [ -z "${!var_name}" ]; then
    while true; do
      echo -n "$prompt_message"
      echo " (default: $default_value):"
      read -r input

      # Use default if user just hits Enter
      eval "$var_name=\"\${input:-$default_value}\""
      local current_val="${!var_name}"

      # If no validator, or if validation passes, we're done.
      if [[ -z "$validator_function" ]] || "$validator_function" "$current_val"; then
        break
      else
        echo "Invalid input. Please try again."
      fi
    done
  else
    # If variable is already set, let user keep or change
    while true; do
      local current_val="${!var_name}"
      echo "$var_name is currently set to '$current_val'."
      echo "Press Enter to keep it, or type a new value:"
      read -r input

      # If user just presses Enter, keep existing
      if [ -z "$input" ]; then
        break
      else
        eval "$var_name=\"$input\""
        current_val="${!var_name}"
        if [[ -z "$validator_function" ]] || "$validator_function" "$current_val"; then
          break
        else
          echo "Invalid input. Please try again."
        fi
      fi
    done
  fi
}

###############################################################################
# Main script
###############################################################################

# 1. Ensure we have sudo/root privileges
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run with sudo or as root."
  echo "Please re-run: sudo $0"
  exit 1
fi

# 2. Prompt the user for all required variables
#    - Order is important. We need the DB root password before checking databases.
prompt_variable DB_PASS        "Enter the **MariaDB root password**"    "root_password"  validate_password
prompt_variable NEXTCLOUD_DIR  "Enter the directory to install Nextcloud" "/var/www/nextcloud" validate_mysql_identifier
prompt_variable DB_NAME        "Enter the database name for Nextcloud"    "nextcloud_db"   validate_mysql_identifier
prompt_variable DB_USER        "Enter the database user for Nextcloud"    "nextcloud_user" validate_mysql_identifier
prompt_variable ADMIN_USER     "Enter the Nextcloud admin username"       "admin"          validate_mysql_identifier
prompt_variable ADMIN_PASS     "Enter the Nextcloud admin password"       "admin_password" validate_password
prompt_variable DOMAIN         "Enter the domain for Nextcloud"           "example.com"    validate_domain

echo
echo "======================="
echo " Summary of Parameters "
echo "======================="
echo "Nextcloud directory:  $NEXTCLOUD_DIR"
echo "Database name:        $DB_NAME"
echo "Database user:        $DB_USER"
echo "DB root password:     [hidden]"
echo "Nextcloud admin user: $ADMIN_USER"
echo "Admin password:       [hidden]"
echo "Domain:               $DOMAIN"
echo

# 3. Check if the Nextcloud directory already exists
if [ -d "$NEXTCLOUD_DIR" ]; then
  echo "Directory '$NEXTCLOUD_DIR' already exists. Do you want to remove it? (yes/no)"
  read -r remove_dir
  if [ "$remove_dir" = "yes" ]; then
    rm -rf "$NEXTCLOUD_DIR"
    echo "Removed existing Nextcloud directory."
  else
    echo "Please choose a different installation directory or remove it manually."
    exit 1
  fi
fi

# 4. Update system and install required packages
echo
echo "[1/7] Updating system packages..."
apt update && apt upgrade -y

echo
echo "[2/7] Installing dependencies..."
apt install -y apache2 mariadb-server libapache2-mod-php \
  php-gd php-mysql php-curl php-mbstring php-intl php-xml php-zip \
  php-bz2 php-imagick php-gmp wget unzip curl certbot python3-certbot-apache

# Enable required Apache modules
a2enmod rewrite headers env dir mime ssl
systemctl restart apache2

# 5. Secure MariaDB installation (only if not yet secure)
echo
echo "[3/7] Checking MariaDB status..."
if ! mysqladmin ping -h localhost >/dev/null 2>&1; then
  echo "Starting MariaDB..."
  systemctl start mariadb
fi

echo
echo "[4/7] Securing MariaDB..."
mysql_secure_installation <<EOF

Y
$DB_PASS
$DB_PASS
Y
Y
Y
Y
EOF

# 6. Create or verify Nextcloud database and user
echo
echo "[5/7] Setting up Nextcloud database..."
# Check if DB exists
if mysql -u root -p"$DB_PASS" -e "USE $DB_NAME" 2>/dev/null; then
  echo "Database '$DB_NAME' already exists."
  echo "Would you like to (yes) use it, (reset) drop and re-create it, or (no) pick another name?"
  read -r choice
  case "$choice" in
    yes)
      echo "Using the existing database '$DB_NAME'."
      ;;
    reset)
      echo "Dropping and re-creating the database '$DB_NAME'..."
      mysql -u root -p"$DB_PASS" -e "DROP DATABASE $DB_NAME; CREATE DATABASE $DB_NAME;"
      ;;
    *)
      echo "Please edit your DB_NAME variable or re-run the script with a different database name."
      exit 1
      ;;
  esac
else
  echo "Creating database '$DB_NAME'..."
  mysql -u root -p"$DB_PASS" -e "CREATE DATABASE $DB_NAME;"
fi

echo "Configuring user '$DB_USER'..."
mysql -u root -p"$DB_PASS" <<EOF
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# 7. Download and install Nextcloud
echo
echo "[6/7] Downloading and installing Nextcloud..."
wget -O /tmp/nextcloud.zip https://download.nextcloud.com/server/releases/latest.zip
unzip -qo /tmp/nextcloud.zip -d /tmp/
mv /tmp/nextcloud "$NEXTCLOUD_DIR"

# Set permissions
chown -R www-data:www-data "$NEXTCLOUD_DIR"
chmod -R 750 "$NEXTCLOUD_DIR"

# 8. Configure Apache
echo
echo "Configuring Apache for Nextcloud..."
cat <<EOL > /etc/apache2/sites-available/nextcloud.conf
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

a2ensite nextcloud.conf
systemctl reload apache2

# Obtain SSL certificate
echo
echo "[7/7] Obtaining SSL certificate via Certbot..."
certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"

# 9. Autoconfig
echo
echo "Configuring Nextcloud autoconfig..."
mkdir -p "$NEXTCLOUD_DIR/config"
cat <<EOL > "$NEXTCLOUD_DIR/config/autoconfig.php"
<?php
\$AUTOCONFIG = [
    'dbtype'     => 'mysql',
    'dbname'     => '$DB_NAME',
    'dbuser'     => '$DB_USER',
    'dbpass'     => '$DB_PASS',
    'dbhost'     => 'localhost',
    'adminlogin' => '$ADMIN_USER',
    'adminpass'  => '$ADMIN_PASS',
    'directory'  => '$NEXTCLOUD_DIR/data',
];
EOL

systemctl restart apache2

echo
echo "==========================================="
echo " Nextcloud installation completed!"
echo "==========================================="
echo "Visit https://$DOMAIN (or http://$DOMAIN) to finalize your Nextcloud setup."
echo

