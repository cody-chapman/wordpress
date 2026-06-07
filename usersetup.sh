#!/bin/bash
set -e
SQLPASSWORD=$(cat /run/secrets/sqlpassword)
# ==========================================
# CONFIGURATION - CHANGE THESE VALUES
# ==========================================


# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or using sudo."
  exit 1
fi

echo "Setting root password and running security configurations..."
# 2. Check if root can log in WITHOUT a password
if mariadb -u root --execute="QUIT" 2>/dev/null; then
  echo "MariaDB is currently using a blank root password. Proceeding with initial security setup..."
  
  mariadb -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$SQLPASSWORD');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
  echo "Initial security setup complete!"

# 3. Check if root can log in WITH the password we want to set
elif mariadb -u root -p"$SQLPASSWORD" --execute="QUIT" 2>/dev/null; then
  echo "MariaDB is already secured with the correct password. Skipping setup."

# 4. The password is set, but it doesn't match our script's password
else
  echo "CRITICAL: MariaDB root password is already set, but it does NOT match DB_ROOT_PASSWORD."
  echo "Skipping setup to prevent overwriting or breaking access."
fi

echo "=================================================="
echo " MariaDB setup complete on Rocky Linux!"
echo "=================================================="
cat << 'EOF' > /etc/httpd/conf.d/wordpress.conf
<IfModule mod_env.c>
    SetEnvIf X-Forwarded-Proto https HTTPS=on
</IfModule>

EOF
