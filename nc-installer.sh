#!/bin/bash
#
# Nextcloud and LAMP stack installation script for Ubuntu
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

# Validation function for directory paths
validate_directory_path() {
  local input="$1"
  # Ensure the input is a valid absolute path
  [[ "$input" =~ ^/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]*$ ]]
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
# Prerequisites Installation
###############################################################################
install_prerequisites() {
  echo "Updating system packages..."
  apt update && apt upgrade -y

  echo "Installing LAMP stack and required PHP modules..."
  apt install -y apache2 mariadb-server wget unzip curl

  # Allow user to choose PHP version
  echo "Available PHP versions:"
  apt-cache search php | grep -Eo '^php[0-9]+\.[0-9]+'
  read -p "Enter PHP version to install (e.g., php8.1): " php_version

  apt install -y $php_version libapache2-mod-$php_version \
    ${php_version}-gd ${php_version}-mysql ${php_version}-curl ${php_version}-mbstring \
    ${php_version}-intl ${php_version}-xml ${php_version}-zip ${php_version}-bz2 \
    ${php_version}-imagick ${php_version}-gmp php-redis

  echo "Enabling Apache modules..."
  a2enmod rewrite headers env dir mime ssl
  systemctl restart apache2

  echo "LAMP stack and prerequisites installed."
}

###############################################################################
# Main script
###############################################################################
install_nextcloud() {
  # Prompt the user for all required variables
  prompt_variable DB_PASS        "Enter the **MariaDB root password**"    "root_password"  validate_password
  prompt_variable NEXTCLOUD_DIR  "Enter the directory to install Nextcloud" "/var/www/nextcloud" validate_directory_path
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

  # Check if the Nextcloud directory already exists
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

  # Secure MariaDB installation (only if not yet secure)
  echo "Checking MariaDB status..."
  if ! mysqladmin ping -h localhost >/dev/null 2>&1; then
    echo "Starting MariaDB..."
    systemctl start mariadb
  fi

  echo "Securing MariaDB..."
  mysql_secure_installation <<EOF

Y
$DB_PASS
$DB_PASS
Y
Y
Y
Y
EOF

  # Create or verify Nextcloud database and user
  echo "Setting up Nextcloud database..."
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

  # Download and install Nextcloud
  echo "Downloading and installing Nextcloud..."
  wget -O /tmp/nextcloud.zip https://download.nextcloud.com/server/releases/latest.zip
  unzip -qo /tmp/nextcloud.zip -d /tmp/
  mv /tmp/nextcloud "$NEXTCLOUD_DIR"

  # Set permissions
  chown -R www-data:www-data "$NEXTCLOUD_DIR"
  chmod -R 750 "$NEXTCLOUD_DIR"

  # Configure Apache
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

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOL

  a2ensite nextcloud.conf
  systemctl reload apache2

  # Obtain SSL certificate
  echo "Obtaining SSL certificate via Certbot..."
  certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"

  echo "Nextcloud installation completed!"
}

###############################################################################
# Main Menu
###############################################################################
echo "Choose an option:"
echo "1) Install LAMP stack and prerequisites"
echo "2) Install Nextcloud"
echo "3) Exit"
read -p "Enter your choice: " choice

case "$choice" in
  1)
    install_prerequisites
    ;;
  2)
    install_nextcloud
    ;;
  3)
    echo "Exiting..."
    exit 0
    ;;
  *)
    echo "Invalid choice. Exiting..."
    exit 1
    ;;
esac

