#!/bin/bash
#
# Nextcloud installation script for Ubuntu
#
# This script will:
#   1. Prompt for install settings (directory, DB credentials, domain, etc.)
#   2. Install required packages
#   3. Secure MariaDB
#   4. Create/Reset a Nextcloud database
#   5. Download and configure Nextcloud
#   6. Obtain and configure an SSL certificate via certbot
#   7. Guide the user to finalize setup

# -------------------------------------------------------------------------------
# Safety settings
# -------------------------------------------------------------------------------
set -e  # Exit immediately on any command failure

# We’ll trap any uncaught errors to allow the user to retry if desired.
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

# -------------------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------------------

# Function to validate database names, usernames, etc.
validate_name() {
  local name="$1"
  # Only allow alphanumeric and underscore
  [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Prompt for a variable if not already set; re-prompt if invalid.
prompt_variable() {
  local var_name="$1"
  local prompt_message="$2"
  local default_value="$3"

  # If variable is empty, prompt until valid
  if [ -z "${!var_name}" ]; then
    while true; do
      echo -n "$prompt_message "
      echo "(default: $default_value):"
      read -r input
      # If user input is empty, use the default
      eval "$var_name=\"\${input:-$default_value}\""

      if validate_name "${!var_name}"; then
        break
      else
        echo "Invalid input. Please use only letters, numbers, or underscores."
      fi
    done
  else
    # If variable is already set, offer the chance to change it
    while true; do
      echo "$var_name is currently '${!var_name}'."
      echo "Press Enter to keep it or type a new value:"
      read -r input
      if [ -z "$input" ]; then
        break  # keep the existing value
      else
        eval "$var_name=\"$input\""
        if validate_name "${!var_name}"; then
          break
        else
          echo "Invalid input. Please use only letters, numbers, or underscores."
        fi
      fi
    done
  fi
}

# Check if a given database already exists; ask to use or reset if it does.
check_database() {
  local db_name="$1"
  # -e "USE $db_name" returns 0 if it exists, 1 otherwise
  if mysql -u root -p"$DB_PASS" -e "USE $db_name" 2>/dev/null; then
    echo "Database '$db_name' already exists. Do you want to use it, or reset it?"
    echo "Options: (yes/reset/no)"
    read -r choice
    case "$choice" in
      yes)
        echo "Using the existing database '$db_name'."
        ;;
      reset)
        echo "Resetting the database '$db_name'."
        mysql -u root -p"$DB_PASS" -e "DROP DATABASE $db_name; CREATE DATABASE $db_name;"
        ;;
      *)
        echo "Please choose a different database name."
        return 1
        ;;
    esac
  fi
  return 0
}

# -------------------------------------------------------------------------------
# Main script
# -------------------------------------------------------------------------------

# Optionally, check for sudo/root here:
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run with sudo or as root."
   echo "Please re-run: sudo $0"
   exit 1
fi

# Prompt for essential variables first
prompt_variable DB_PASS    "Enter the database root password (for MariaDB)" "secure_password"
prompt_variable NEXTCLOUD_DIR "Enter the directory where Nextcloud will be installed" "/var/www/nextcloud"
prompt_variable DB_NAME    "Enter the database name for Nextcloud"          "nextcloud_db"
# If check_database fails (return code 1), exit with error
check_database "$DB_NAME" || exit 1

prompt_variable DB_USER    "Enter the database user for Nextcloud"          "nextcloud_user"
# We re-use DB_PASS for the Nextcloud DB user password. 
# If you'd prefer a separate DB_USER_PASS, rename and prompt separately.
prompt_variable ADMIN_USER "Enter the admin username for Nextcloud"         "admin"
prompt_variable ADMIN_PASS "Enter the admin password for Nextcloud"         "admin_password"
prompt_variable DOMAIN     "Enter the domain for Nextcloud"                 "example.com"

echo
echo "======================="
echo "Summary of Parameters:"
echo "======================="
echo "Nextcloud directory:    $NEXTCLOUD_DIR"
echo "Database name:          $DB_NAME"
echo "Database user:          $DB_USER"
echo "Database password:      (hidden)"
echo "Nextcloud admin user:   $ADMIN_USER"
echo "Nextcloud admin pass:   (hidden)"
echo "Domain:                 $DOMAIN"
echo

# -------------------------------------------------------------------------------
# Check if Nextcloud directory exists
# -------------------------------------------------------------------------------
if [ -d "$NEXTCLOUD_DIR" ]; then
  echo "The directory '$NEXTCLOUD_DIR' already exists."
  echo "Do you want to remove it? (yes/no)"
  read -r remove_dir
  if [ "$remove_dir" = "yes" ]; then
    rm -rf "$NEXTCLOUD_DIR"
    echo "Removed existing Nextcloud directory."
  else
    echo "Please choose a different installation directory or remove it manually."
    exit 1
  fi
fi

# -------------------------------------------------------------------------------
# System update & package installation
# -------------------------------------------------------------------------------
echo
echo "Updating package list and upgrading the system..."
apt update && apt upgrade -y

echo
echo "Installing required packages..."
apt install -y apache2 mariadb-server libapache2-mod-php \
  php-gd php-mysql php-curl php-mbstring php-intl php-xml php-zip \
  php-bz2 php-imagick php-gmp wget unzip curl certbot python3-certbot-apache

# Enable required Apache modules
a2enmod rewrite headers env dir mime ssl
systemctl restart apache2

# -------------------------------------------------------------------------------
# Secure MariaDB installation
# -------------------------------------------------------------------------------
if ! mysqladmin ping -h localhost >/dev/null 2>&1; then
  echo "Starting MariaDB..."
  systemctl start mariadb
fi

echo
echo "Securing MariaDB..."
# The commands below simulate interactive answers to mysql_secure_installation.
# If your distribution handles this differently, you may need to tweak it.
mysql_secure_installation <<EOF

Y
$DB_PASS
$DB_PASS
Y
Y
Y
Y
EOF

# -------------------------------------------------------------------------------
# Create or update Nextcloud database & user
# -------------------------------------------------------------------------------
echo
echo "Setting up Nextcloud database and user..."
mysql -u root -p"$DB_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# -------------------------------------------------------------------------------
# Download and extract Nextcloud
# -------------------------------------------------------------------------------
echo
echo "Downloading Nextcloud (latest release)..."
wget -O /tmp/nextcloud.zip https://download.nextcloud.com/server/releases/latest.zip

echo "Extracting Nextcloud..."
unzip -qo /tmp/nextcloud.zip -d /tmp/
mv /tmp/nextcloud "$NEXTCLOUD_DIR"

# -------------------------------------------------------------------------------
# Set file permissions
# -------------------------------------------------------------------------------
echo
echo "Setting file permissions..."
chown -R www-data:www-data "$NEXTCLOUD_DIR"
chmod -R 750 "$NEXTCLOUD_DIR"

# -------------------------------------------------------------------------------
# Configure Apache for Nextcloud
# -------------------------------------------------------------------------------
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

# -------------------------------------------------------------------------------
# Obtain SSL certificate with Certbot
# -------------------------------------------------------------------------------
echo
echo "Obtaining SSL certificate via Certbot..."
certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"

# -------------------------------------------------------------------------------
# Finalizing Nextcloud installation (autoconfig)
# -------------------------------------------------------------------------------
echo
echo "Configuring Nextcloud autoconfig..."
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

